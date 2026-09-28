import ArgumentParser
import CalPilotCore
import EventKit
import Foundation

enum ExitCodes {
    static let failure: Int32 = 1
    static let cancelled: Int32 = 2
}

struct CLIError: Error, CustomStringConvertible {
    var description: String
    init(_ message: String) { self.description = message }
}

/// Shared helpers for the commands: config loading, date range resolution,
/// calendar access, and plan rendering.
enum Runtime {
    static func loadConfig() throws -> AppConfig {
        do {
            return try ConfigStore.loadOrCreate()
        } catch {
            throw CLIError("Could not read \(ConfigStore.configURL.path): \(error.localizedDescription)")
        }
    }

    /// Opens the calendar store and makes sure full access has been granted.
    static func connectedService(config: AppConfig) async throws -> CalendarService {
        let service = CalendarService()
        do {
            let granted = try await service.requestFullAccess()
            guard granted else {
                throw CalendarService.ServiceError.accessDenied(service.authorizationDescription)
            }
        } catch let error as CalendarService.ServiceError {
            throw CLIError(error.description)
        }
        return service
    }

    static func jsonFlag(_ enabled: Bool, value: some Encodable) throws -> String {
        try CalPilotJSON.encodeToString(value, pretty: true)
    }

    /// Resolves a `--from`/`--to` pair, falling back to a window starting today.
    static func resolveRange(
        from fromRaw: String?,
        to toRaw: String?,
        days: Int,
        defaultStartFromNow: Bool,
        config: AppConfig,
        now: Date = Date()
    ) throws -> (start: Date, end: Date) {
        do {
            return try DateRangeResolver.resolve(
                from: fromRaw,
                to: toRaw,
                days: days,
                defaultFromNow: defaultStartFromNow,
                config: config,
                now: now
            )
        } catch {
            throw CLIError("\(error)")
        }
    }

    static func printJSON<T: Encodable>(_ value: T) throws {
        print(try CalPilotJSON.encodeToString(value, pretty: true))
    }

    static func formatRange(_ start: Date, _ end: Date, calendar: Calendar) -> String {
        "\(Format.human(start, calendar: calendar)) → \(Format.human(end, calendar: calendar))"
    }
}

enum PlanRenderer {
    static func printContext(_ context: Planner.Context, config: AppConfig, verbose: Bool) {
        let calendar = config.calendar
        Console.heading("Window")
        Console.note("  \(Runtime.formatRange(context.rangeStart, context.rangeEnd, calendar: calendar))  ·  \(config.timeZone)")

        Console.heading("Existing events")
        if context.busy.isEmpty {
            Console.note("  none in this window")
        } else {
            let rows = context.busy.map { block -> [String] in
                let owned = context.ownEvents.contains { $0.start == block.start && $0.title == block.title }
                return [
                    Format.day(block.start, calendar: calendar),
                    Format.weekday(block.start, calendar: calendar),
                    "\(Format.clock(block.start, calendar: calendar))-\(Format.clock(block.end, calendar: calendar))",
                    block.title,
                    block.calendarName + (owned ? " (CalPilot)" : ""),
                ]
            }
            Console.table(headers: ["Day", "Wk", "Time", "Title", "Calendar"], rows: rows)
        }

        Console.heading("Free slots")
        if context.freeSlots.isEmpty {
            Console.warn("no free slot inside the available hours in this window")
        } else if verbose {
            let rows = context.freeSlots.map { slot in
                [
                    Format.day(slot.start, calendar: calendar),
                    Format.weekday(slot.start, calendar: calendar),
                    "\(Format.clock(slot.start, calendar: calendar))-\(Format.clock(slot.end, calendar: calendar))",
                    Format.duration(minutes: slot.minutes),
                ]
            }
            Console.table(headers: ["Day", "Wk", "Time", "Length"], rows: rows)
        } else {
            let total = context.freeSlots.reduce(0) { $0 + $1.minutes }
            Console.note("  \(context.freeSlots.count) slot(s), \(Format.duration(minutes: total)) free in total")
        }
    }

    static func printPlan(_ plan: Plan, config: AppConfig) {
        let calendar = config.calendar
        Console.heading("Proposed plan  ·  \(plan.model)")
        if !plan.summary.isEmpty {
            print("  " + plan.summary)
        }
        if plan.items.isEmpty {
            Console.note("  no events proposed")
        } else {
            let rows = plan.items.map { item -> [String] in
                var title = item.title
                if item.adjustedFrom != nil { title += " *" }
                return [
                    Format.day(item.start, calendar: calendar),
                    Format.weekday(item.start, calendar: calendar),
                    "\(Format.clock(item.start, calendar: calendar))-\(Format.clock(item.end, calendar: calendar))",
                    Format.duration(minutes: item.minutes),
                    title,
                    item.reason ?? "",
                ]
            }
            Console.table(headers: ["Day", "Wk", "Time", "Len", "Title", "Why"], rows: rows)
            if plan.items.contains(where: { $0.adjustedFrom != nil }) {
                print()
                Console.note("  * moved to avoid a conflict:")
                for item in plan.items where item.adjustedFrom != nil {
                    let from = item.adjustedFrom.map { Format.human($0, calendar: calendar) } ?? "?"
                    Console.note("    · \(item.title): \(from) → \(Format.human(item.start, calendar: calendar)) (\(item.adjustmentNote ?? "adjusted"))")
                }
            }
        }
        if !plan.unscheduled.isEmpty {
            Console.heading("Not scheduled")
            for item in plan.unscheduled {
                Console.note("  · \(item.title) — \(item.reason)")
            }
        }
        if !plan.warnings.isEmpty {
            Console.heading("Warnings")
            for warning in plan.warnings {
                Console.warn(warning)
            }
        }
    }

    /// Writes every plan item into the target calendar and journals each event.
    static func apply(
        plan: Plan,
        config: AppConfig,
        service: CalendarService,
        calendarName: String?,
        source: String
    ) throws -> [EventDTO] {
        try PlanApplier.apply(
            plan: plan,
            config: config,
            service: service,
            calendarName: calendarName,
            source: source
        )
    }
}
