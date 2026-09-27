import Foundation

// MARK: - Calendar / Event DTOs

/// A calendar (list) as exposed to the CLI and the language model.
public struct CalendarDTO: Codable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var source: String
    public var allowsModification: Bool
    public var isImmutable: Bool

    public init(id: String, title: String, source: String, allowsModification: Bool, isImmutable: Bool) {
        self.id = id
        self.title = title
        self.source = source
        self.allowsModification = allowsModification
        self.isImmutable = isImmutable
    }
}

/// An event as exposed to the CLI and the language model.
public struct EventDTO: Codable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var calendarID: String
    public var calendarName: String
    public var location: String?
    public var notes: String?
    public var url: String?
    public var isRecurring: Bool
    public var hasAttendees: Bool
    /// True when CalPilot itself created the event (found in the journal).
    public var createdByCalPilot: Bool

    public var minutes: Int { Int(end.timeIntervalSince(start) / 60) }

    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        calendarID: String,
        calendarName: String,
        location: String? = nil,
        notes: String? = nil,
        url: String? = nil,
        isRecurring: Bool = false,
        hasAttendees: Bool = false,
        createdByCalPilot: Bool = false
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarID = calendarID
        self.calendarName = calendarName
        self.location = location
        self.notes = notes
        self.url = url
        self.isRecurring = isRecurring
        self.hasAttendees = hasAttendees
        self.createdByCalPilot = createdByCalPilot
    }
}

// MARK: - Free / busy

public struct BusyBlock: Codable, Hashable {
    public var start: Date
    public var end: Date
    public var title: String
    public var calendarName: String

    public init(start: Date, end: Date, title: String, calendarName: String) {
        self.start = start
        self.end = end
        self.title = title
        self.calendarName = calendarName
    }
}

public struct FreeSlot: Codable, Hashable {
    public var start: Date
    public var end: Date
    public var minutes: Int

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
        self.minutes = Int(end.timeIntervalSince(start) / 60)
    }
}

// MARK: - Plan

/// One event the language model wants to place on the calendar.
public struct PlanItem: Codable, Hashable {
    public var title: String
    public var start: Date
    public var end: Date
    public var location: String?
    public var notes: String?
    public var reason: String?
    /// Set when validation had to move the item to a different slot.
    public var adjustedFrom: Date?
    public var adjustmentNote: String?

    public init(
        title: String,
        start: Date,
        end: Date,
        location: String? = nil,
        notes: String? = nil,
        reason: String? = nil,
        adjustedFrom: Date? = nil,
        adjustmentNote: String? = nil
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.notes = notes
        self.reason = reason
        self.adjustedFrom = adjustedFrom
        self.adjustmentNote = adjustmentNote
    }

    public var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
}

public struct UnscheduledItem: Codable, Hashable {
    public var title: String
    public var reason: String
    public var suggestedMinutes: Int?

    public init(title: String, reason: String, suggestedMinutes: Int? = nil) {
        self.title = title
        self.reason = reason
        self.suggestedMinutes = suggestedMinutes
    }
}

public struct Plan: Codable {
    public var generatedAt: Date
    public var timeZone: String
    public var model: String
    public var goal: String
    public var rangeStart: Date
    public var rangeEnd: Date
    public var summary: String
    public var items: [PlanItem]
    public var unscheduled: [UnscheduledItem]
    public var warnings: [String]

    public init(
        generatedAt: Date = Date(),
        timeZone: String,
        model: String,
        goal: String,
        rangeStart: Date,
        rangeEnd: Date,
        summary: String,
        items: [PlanItem],
        unscheduled: [UnscheduledItem],
        warnings: [String]
    ) {
        self.generatedAt = generatedAt
        self.timeZone = timeZone
        self.model = model
        self.goal = goal
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.summary = summary
        self.items = items
        self.unscheduled = unscheduled
        self.warnings = warnings
    }
}

// MARK: - JSON coding

public enum CalPilotJSON {
    /// NOTE: `.sortedKeys` is mandatory, not cosmetic. Cloud prompt caches hash the
    /// exact request bytes, and Foundation's `JSONEncoder` otherwise walks its keyed
    /// containers in per-process hash order — so every relaunch would emit a different
    /// byte sequence for the same payload and the prompt cache would never hit again.
    public static func encoder(pretty: Bool = true) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func encodeToString<T: Encodable>(_ value: T, pretty: Bool = true) throws -> String {
        let data = try encoder(pretty: pretty).encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    /// Tolerant ISO8601 parsing: accepts `Z`, offsets, and fractional seconds.
    public static func parseISODate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: s) { return d }
        let f3 = DateFormatter()
        f3.locale = Locale(identifier: "en_US_POSIX")
        f3.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f3.timeZone = TimeZone.current
        if let d = f3.date(from: s) { return d }
        f3.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let d = f3.date(from: s) { return d }
        f3.dateFormat = "yyyy-MM-dd HH:mm"
        if let d = f3.date(from: s) { return d }
        f3.dateFormat = "yyyy-MM-dd"
        if let d = f3.date(from: s) { return d }
        return nil
    }
}
