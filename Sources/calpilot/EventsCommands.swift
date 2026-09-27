import ArgumentParser
import CalPilotCore
import Foundation

// MARK: - events

struct EventsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "Read and write events.",
        subcommands: [EventsListCommand.self, EventsAddCommand.self, EventsDeleteCommand.self],
        defaultSubcommand: EventsListCommand.self
    )
}

struct EventsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List events in a date range."
    )

    @Option(name: .long, help: "Range start, e.g. 2026-09-28, today, 明天 09:00, +2d.")
    var from: String?

    @Option(name: .long, help: "Range end (exclusive).")
    var to: String?

    @Option(name: .long, help: "Number of days to look ahead when --to is omitted.")
    var days: Int = 7

    @Option(name: .long, help: "Only show this calendar (substring match).")
    var calendar: String?

    @Flag(name: .long, help: "Emit JSON.")
    var json = false

    @Flag(name: .long, help: "Include all-day events.")
    var all = false

    func run() async throws {
        let config = try Runtime.loadConfig()
        let service = try await Runtime.connectedService(config: config)
        let range = try Runtime.resolveRange(
            from: from, to: to, days: days, defaultStartFromNow: false, config: config
        )
        var ids: [String]? = nil
        if let calendar {
            guard let match = service.findCalendar(named: calendar) else {
                throw CLIError("No calendar matches \"\(calendar)\". Run `calpilot calendars`.")
            }
            ids = [match.calendarIdentifier]
        }
        var events = service.events(from: range.start, to: range.end, calendarIDs: ids)
        if !all {
            events = events.filter { !$0.isAllDay }
        }
        if json {
            try Runtime.printJSON(events)
            return
        }
        Console.note("  \(Runtime.formatRange(range.start, range.end, calendar: config.calendar))")
        print("")
        let rows = events.map { event -> [String] in
            [
                Format.day(event.start, calendar: config.calendar),
                Format.weekday(event.start, calendar: config.calendar),
                event.isAllDay ? "all-day" : "\(Format.clock(event.start, calendar: config.calendar))-\(Format.clock(event.end, calendar: config.calendar))",
                event.title,
                event.calendarName,
                event.createdByCalPilot ? "CalPilot" : (event.isRecurring ? "recurring" : ""),
            ]
        }
        Console.table(headers: ["Day", "Wk", "Time", "Title", "Calendar", "Note"], rows: rows)
    }
}

struct EventsAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Create a single event."
    )

    @Argument(help: "Event title.")
    var title: String

    @Option(name: .long, help: "Start time, e.g. \"2026-09-28 09:30\", \"tomorrow 14:00\", \"明天 09:00\".")
    var start: String

    @Option(name: .long, help: "End time. Alternative to --minutes.")
    var end: String?

    @Option(name: .long, help: "Length in minutes. Defaults to the configured default length.")
    var minutes: Int?

    @Option(name: .long, help: "Target calendar. Defaults to the configured write calendar.")
    var calendar: String?

    @Option(name: .long) var notes: String?
    @Option(name: .long) var location: String?
    @Flag(name: .long) var allDay = false

    @Flag(name: .long, help: "Emit the created event as JSON.")
    var json = false

    func run() async throws {
        let config = try Runtime.loadConfig()
        let service = try await Runtime.connectedService(config: config)
        let zone = config.calendar

        let startDate = try FlexibleDate.parse(start, calendar: zone)
        let endDate: Date
        if let end {
            endDate = try FlexibleDate.parse(end, calendar: zone)
        } else {
            let length = minutes ?? config.defaultEventMinutes
            endDate = startDate.addingTimeInterval(Double(max(5, length) * 60))
        }
        guard endDate > startDate else {
            throw CLIError("The end time must be after the start time.")
        }

        let target = try service.resolveWriteCalendar(
            name: calendar ?? config.writeCalendar,
            createIfMissing: config.autoCreateCalendar
        )
        let event = try service.createEvent(
            title: title,
            start: startDate,
            end: endDate,
            calendar: target,
            notes: notes,
            location: location,
            isAllDay: allDay
        )
        try Journal.append(JournalEntry(
            action: .create,
            batchID: Journal.newBatchID(),
            eventID: event.eventIdentifier ?? UUID().uuidString,
            calendarID: target.calendarIdentifier,
            title: title,
            start: startDate,
            end: endDate,
            source: "cli:add"
        ))
        let dto = service.dto(from: event)
        if json {
            try Runtime.printJSON(dto)
        } else {
            Console.success("created \"\(dto.title)\" in \(dto.calendarName) · \(Runtime.formatRange(dto.start, dto.end, calendar: zone))")
            Console.note("  id \(dto.id)")
        }
    }
}

struct EventsDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete an event by identifier or by title search.",
        discussion: """
        Deleting records a journal entry, so `calpilot undo` will not try to remove the
        same event twice.
        """
    )

    @Option(name: .long, help: "Event identifier, as printed by `events list --json`.")
    var id: String?

    @Option(name: .long, help: "Delete events whose title contains this text.")
    var search: String?

    @Option(name: .long) var from: String?
    @Option(name: .long) var to: String?
    @Option(name: .long) var days: Int = 30

    @Flag(name: .long, help: "Skip the confirmation prompt.")
    var yes = false

    func run() async throws {
        let config = try Runtime.loadConfig()
        let service = try await Runtime.connectedService(config: config)

        guard id != nil || search != nil else {
            throw CLIError("Pass either --id or --search.")
        }

        var targets: [EventDTO] = []
        if let id {
            if let event = service.event(withID: id) {
                targets = [service.dto(from: event)]
            } else {
                throw CLIError("No event found for identifier \"\(id)\".")
            }
        } else if let search {
            let range = try Runtime.resolveRange(from: from, to: to, days: days, defaultStartFromNow: true, config: config)
            targets = service.events(from: range.start, to: range.end)
                .filter { $0.title.localizedCaseInsensitiveContains(search) }
        }

        guard !targets.isEmpty else {
            Console.note("nothing matched")
            return
        }

        for event in targets {
            print("  \(Format.human(event.start, calendar: config.calendar))  \(event.title)  [\(event.calendarName)]")
        }
        if !yes {
            guard Console.confirm("Delete \(targets.count) event(s)?", default: false) else {
                Console.note("cancelled")
                throw ExitCode(ExitCodes.cancelled)
            }
        }
        for event in targets {
            try service.deleteEvents(matching: event)
            try Journal.append(JournalEntry(
                action: .delete,
                batchID: Journal.newBatchID(),
                eventID: event.id,
                calendarID: event.calendarID,
                title: event.title,
                start: event.start,
                end: event.end,
                source: "cli:delete"
            ))
            Console.success("deleted \"\(event.title)\"")
        }
    }
}

// MARK: - free

struct FreeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "free",
        abstract: "Show the free slots inside working hours."
    )

    @Option(name: .long, help: "Range start.")
    var from: String?

    @Option(name: .long, help: "Range end.")
    var to: String?

    @Option(name: .long, help: "Days to look ahead when --to is omitted.")
    var days: Int = 7

    @Option(name: .long, help: "Only report slots at least this long.")
    var min: Int = 30

    @Option(name: .customLong("busy-calendars"), help: "Comma-separated calendar names that count as busy. Defaults to all.")
    var busyCalendars: String?

    @Flag(name: .long, help: "Emit JSON.")
    var json = false

    func run() async throws {
        let config = try Runtime.loadConfig()
        let service = try await Runtime.connectedService(config: config)
        let range = try Runtime.resolveRange(from: from, to: to, days: days, defaultStartFromNow: true, config: config)

        var ids: [String]? = nil
        if let busyCalendars {
            let names = busyCalendars.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            ids = names.compactMap { service.findCalendar(named: $0)?.calendarIdentifier }
            if ids?.isEmpty ?? true {
                throw CLIError("None of the calendars in --busy-calendars exist. Run `calpilot calendars`.")
            }
        }

        let events = service.events(from: range.start, to: range.end, calendarIDs: ids).filter { !$0.isAllDay }
        let finder = SlotFinder(config: config)
        let slots = finder.freeSlots(
            busy: events.map { $0.interval },
            from: range.start,
            to: range.end,
            minMinutes: max(5, min)
        )

        if json {
            struct FreeReport: Encodable {
                var rangeStart: Date
                var rangeEnd: Date
                var freeSlots: [FreeSlot]
            }
            try Runtime.printJSON(FreeReport(rangeStart: range.start, rangeEnd: range.end, freeSlots: slots))
            return
        }

        Console.note("  \(Runtime.formatRange(range.start, range.end, calendar: config.calendar))  ·  \(config.timeZone)")
        print("")
        let rows = slots.map { slot in
            [
                Format.day(slot.start, calendar: config.calendar),
                Format.weekday(slot.start, calendar: config.calendar),
                "\(Format.clock(slot.start, calendar: config.calendar))-\(Format.clock(slot.end, calendar: config.calendar))",
                Format.duration(minutes: slot.minutes),
            ]
        }
        Console.table(headers: ["Day", "Wk", "Time", "Length"], rows: rows)
        let total = slots.reduce(0) { $0 + $1.minutes }
        Console.note("  \(slots.count) slot(s), \(Format.duration(minutes: total)) free in total")
    }
}
