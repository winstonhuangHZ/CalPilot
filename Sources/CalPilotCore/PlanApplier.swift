import EventKit
import Foundation

/// The only place in CalPilot that writes to the calendar. Both the CLI and the
/// agent go through here, so every write is journaled and therefore undoable.
public enum PlanApplier {
    @discardableResult
    public static func apply(
        plan: Plan,
        config: AppConfig,
        service: CalendarService,
        calendarName: String? = nil,
        source: String
    ) throws -> [EventDTO] {
        let target = calendarName ?? config.writeCalendar
        let calendar = try service.resolveWriteCalendar(name: target, createIfMissing: config.autoCreateCalendar)
        let batchID = Journal.newBatchID()
        var created: [EventDTO] = []

        for item in plan.items {
            let notes = [item.notes, item.reason.map { "CalPilot: \($0)" }]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            let event = try service.createEvent(
                title: item.title,
                start: item.start,
                end: item.end,
                calendar: calendar,
                notes: notes.isEmpty ? nil : notes,
                location: item.location
            )
            try Journal.append(JournalEntry(
                action: .create,
                batchID: batchID,
                eventID: event.eventIdentifier ?? UUID().uuidString,
                calendarID: calendar.calendarIdentifier,
                title: item.title,
                start: item.start,
                end: item.end,
                source: source
            ))
            created.append(service.dto(from: event))
        }
        return created
    }

    public struct UndoResult {
        public var batchID: String
        public var removed: Int
        public var attempted: Int
        public var failures: [String]
    }

    /// Removes the events created by the most recent (or a specific) batch.
    public static func undo(
        config: AppConfig,
        service: CalendarService,
        batchID: String? = nil
    ) throws -> UndoResult? {
        let selected: (batchID: String, entries: [JournalEntry])
        if let batchID {
            let entries = Journal.all().filter { $0.batchID == batchID && $0.action == .create }
            guard !entries.isEmpty else { return nil }
            selected = (batchID, entries)
        } else {
            guard let last = Journal.lastCreateBatch() else { return nil }
            selected = last
        }

        let undoBatch = Journal.newBatchID()
        var removed = 0
        var failures: [String] = []
        for entry in selected.entries {
            do {
                try service.deleteEvent(id: entry.eventID, fallback: (entry.title, entry.start))
            } catch {
                failures.append("\(entry.title): \(error)")
                continue
            }
            try Journal.append(JournalEntry(
                action: .delete,
                batchID: undoBatch,
                eventID: entry.eventID,
                calendarID: entry.calendarID,
                title: entry.title,
                start: entry.start,
                end: entry.end,
                source: "undo:\(selected.batchID)"
            ))
            removed += 1
        }
        return UndoResult(
            batchID: selected.batchID,
            removed: removed,
            attempted: selected.entries.count,
            failures: failures
        )
    }
}
