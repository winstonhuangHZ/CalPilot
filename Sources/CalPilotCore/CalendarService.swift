import EventKit
import Foundation

/// Thin, opinionated wrapper around EventKit.
///
/// Reads are allowed across every calendar the user has; writes are restricted to a
/// single calendar (default `CalPilot`) so the language model can never rewrite the
/// user's existing commitments by accident.
public final class CalendarService {
    public enum ServiceError: Error, CustomStringConvertible {
        case accessDenied(String)
        case calendarNotFound(String)
        case calendarNotWritable(String)
        case eventNotFound(String)
        case operationFailed(String)

        public var description: String {
            switch self {
            case let .accessDenied(message):
                return """
                Calendar access is not available: \(message)
                Grant access in System Settings > Privacy & Security > Calendars, then re-run.
                """
            case let .calendarNotFound(name):
                return "No calendar named \"\(name)\" exists. List them with `calpilot calendars`."
            case let .calendarNotWritable(name):
                return "Calendar \"\(name)\" is read-only. Pick another one with --calendar."
            case let .eventNotFound(id):
                return "No event found for identifier \"\(id)\"."
            case let .operationFailed(message):
                return message
            }
        }
    }

    public let store: EKEventStore
    /// Event IDs created by CalPilot, used to flag its own events in listings.
    private let createdIDs: Set<String>

    public init() {
        self.store = EKEventStore()
        self.createdIDs = Journal.liveCreatedEventIDs()
    }

    // MARK: - Access

    public var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    public var authorizationDescription: String {
        switch authorizationStatus {
        case .notDetermined: return "notDetermined (the permission prompt has not been answered yet)"
        case .restricted: return "restricted (blocked by parental controls or MDM)"
        case .denied: return "denied (refused in System Settings)"
        case .fullAccess: return "fullAccess (read + write)"
        case .writeOnly: return "writeOnly (can create events, cannot read)"
        @unknown default: return "unknown"
        }
    }

    /// Requests full calendar access. Returns true when read+write is available.
    public func requestFullAccess() async throws -> Bool {
        switch authorizationStatus {
        case .fullAccess:
            return true
        case .writeOnly:
            throw ServiceError.accessDenied(
                "Only write-only access was granted. CalPilot needs full access to read existing events. "
                + "Change it in System Settings > Privacy & Security > Calendars."
            )
        case .denied, .restricted:
            throw ServiceError.accessDenied(authorizationDescription)
        default:
            break
        }
        do {
            let granted = try await store.requestFullAccessToEvents()
            return granted
        } catch {
            throw ServiceError.accessDenied(error.localizedDescription)
        }
    }

    // MARK: - Calendars

    public func calendars() -> [EKCalendar] {
        store.calendars(for: .event).sorted { lhs, rhs in
            if lhs.source.title != rhs.source.title { return lhs.source.title < rhs.source.title }
            return lhs.title < rhs.title
        }
    }

    public func calendarDTOs() -> [CalendarDTO] {
        calendars().map { cal in
            CalendarDTO(
                id: cal.calendarIdentifier,
                title: cal.title,
                source: cal.source.title,
                allowsModification: cal.allowsContentModifications,
                isImmutable: cal.isImmutable
            )
        }
    }

    public func findCalendar(named name: String) -> EKCalendar? {
        let target = name.lowercased()
        if let exact = calendars().first(where: { $0.title.lowercased() == target }) { return exact }
        return calendars().first { $0.title.lowercased().contains(target) }
    }

    /// Resolves the write target, optionally creating it on first use.
    public func resolveWriteCalendar(name: String, createIfMissing: Bool) throws -> EKCalendar {
        if let existing = findCalendar(named: name) {
            guard existing.allowsContentModifications else {
                throw ServiceError.calendarNotWritable(existing.title)
            }
            return existing
        }
        guard createIfMissing else {
            throw ServiceError.calendarNotFound(name)
        }
        return try createCalendar(title: name)
    }

    public func createCalendar(title: String) throws -> EKCalendar {
        let sources = store.sources
        let preferred = sources.first { $0.sourceType == .local }
            ?? store.defaultCalendarForNewEvents?.source
            ?? sources.first
        guard let source = preferred else {
            throw ServiceError.operationFailed("No calendar source is available to create \"\(title)\" in.")
        }

        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = title
        calendar.source = source
        do {
            try store.saveCalendar(calendar, commit: true)
        } catch {
            throw ServiceError.operationFailed("Could not create calendar \"\(title)\": \(error.localizedDescription)")
        }
        return calendar
    }

    // MARK: - Reading

    public func events(from start: Date, to end: Date, calendarIDs: [String]? = nil) -> [EventDTO] {
        let targets: [EKCalendar]?
        if let calendarIDs, !calendarIDs.isEmpty {
            let wanted = Set(calendarIDs)
            targets = calendars().filter { wanted.contains($0.calendarIdentifier) }
        } else {
            targets = nil
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: targets)
        let events = store.events(matching: predicate)
        return events
            .map { dto(from: $0) }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.title < rhs.title
            }
    }

    public func dto(from event: EKEvent) -> EventDTO {
        let identifier = event.eventIdentifier ?? UUID().uuidString
        return EventDTO(
            id: identifier,
            title: event.title ?? "(untitled)",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            calendarID: event.calendar?.calendarIdentifier ?? "",
            calendarName: event.calendar?.title ?? "",
            location: event.location?.isEmpty == false ? event.location : nil,
            notes: event.notes?.isEmpty == false ? event.notes : nil,
            url: event.url?.absoluteString,
            isRecurring: event.hasRecurrenceRules,
            hasAttendees: (event.attendees?.isEmpty == false),
            createdByCalPilot: createdIDs.contains(identifier)
        )
    }

    public func busyBlocks(from start: Date, to end: Date) -> [BusyBlock] {
        events(from: start, to: end)
            .filter { !$0.isAllDay }
            .map { BusyBlock(start: $0.start, end: $0.end, title: $0.title, calendarName: $0.calendarName) }
    }

    public func event(withID id: String) -> EKEvent? {
        store.event(withIdentifier: id)
    }

    // MARK: - Writing

    @discardableResult
    public func createEvent(
        title: String,
        start: Date,
        end: Date,
        calendar: EKCalendar,
        notes: String? = nil,
        location: String? = nil,
        url: URL? = nil,
        isAllDay: Bool = false,
        alarms: [TimeInterval] = []
    ) throws -> EKEvent {
        guard calendar.allowsContentModifications else {
            throw ServiceError.calendarNotWritable(calendar.title)
        }
        guard end > start else {
            throw ServiceError.operationFailed("Event \"\(title)\" ends before it starts.")
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = isAllDay
        event.notes = notes
        event.location = location
        event.url = url
        if !alarms.isEmpty {
            event.alarms = alarms.map { EKAlarm(relativeOffset: $0) }
        }
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw ServiceError.operationFailed("Could not save \"\(title)\": \(error.localizedDescription)")
        }
        return event
    }

    /// Deletes by identifier; falls back to a title + start-time match for events
    /// whose identifier changed after a sync.
    public func deleteEvent(id: String, fallback: (title: String, start: Date)? = nil) throws {
        if let event = store.event(withIdentifier: id) {
            do {
                try store.remove(event, span: .thisEvent, commit: true)
            } catch {
                throw ServiceError.operationFailed("Could not delete event: \(error.localizedDescription)")
            }
            return
        }
        guard let fallback else {
            throw ServiceError.eventNotFound(id)
        }
        let window = DateInterval(start: fallback.start.addingTimeInterval(-120),
                                  end: fallback.start.addingTimeInterval(120))
        let candidates = events(from: window.start, to: window.end)
            .filter { $0.title == fallback.title }
            .filter { abs($0.start.timeIntervalSince(fallback.start)) < 120 }
        guard let match = candidates.first, let event = store.event(withIdentifier: match.id) else {
            throw ServiceError.eventNotFound(id)
        }
        do {
            try store.remove(event, span: .thisEvent, commit: true)
        } catch {
            throw ServiceError.operationFailed("Could not delete event: \(error.localizedDescription)")
        }
    }

    public func deleteEvents(matching dto: EventDTO) throws {
        try deleteEvent(id: dto.id, fallback: (dto.title, dto.start))
    }
}
