import ArgumentParser
import CalPilotCore
import Foundation

// MARK: - plan

struct PlanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Let the language model arrange your time, then optionally write it to the calendar.",
        discussion: """
        `plan` never writes anything unless you pass --apply, and every proposed event is
        re-validated locally against your real calendar before it is saved.
        """
    )

    @Option(name: .long, help: "What you want your time to look like, e.g. \"这周把论文写完，每天留出健身时间\".")
    var goal: String

    @Option(name: .long, help: "A concrete task, repeatable. Forms: \"写周报:90\", \"gym 60\", \"体检:60:high\".")
    var task: [String] = []

    @Option(name: .long, help: "Extra preferences for this run only.")
    var prefs: String?

    @Option(name: .long, help: "Range start (defaults to now).")
    var from: String?

    @Option(name: .long, help: "Range end.")
    var to: String?

    @Option(name: .long, help: "Days to plan when --to is omitted.")
    var days: Int = 7

    @Flag(name: .long, help: "Skip the language model and place tasks with earliest-fit.")
    var offline = false

    @Flag(name: .long, help: "Write the validated plan into the calendar.")
    var apply = false

    @Flag(name: .long, help: "Skip the confirmation prompt when applying.")
    var yes = false

    @Option(name: .long, help: "Calendar to write into (defaults to the configured one).")
    var calendar: String?

    @Option(name: .customLong("busy-calendars"), help: "Comma-separated calendars that count as busy. Defaults to all.")
    var busyCalendars: String?

    @Option(name: .long, help: "Write the plan to a JSON file.")
    var out: String?

    @Option(name: .long, help: "Language model override.")
    var model: String?

    @Option(name: .long, help: "API key override.")
    var apiKey: String?

    @Flag(name: .long, help: "Print every free slot.")
    var verbose = false

    @Flag(name: .long, help: "Emit the plan as JSON.")
    var json = false

    func run() async throws {
        let config = try Runtime.loadConfig()
        let service = try await Runtime.connectedService(config: config)
        let planner = Planner(config: config, service: service, memory: MemoryStore.loadRecovering())
        if !json {
            for warning in config.schedulingWarnings {
                Console.warn(warning)
            }
        }

        let range = try Runtime.resolveRange(
            from: from, to: to, days: days, defaultStartFromNow: true, config: config
        )
        let tasks = task.compactMap { PlannedTask.parse($0, defaultMinutes: config.defaultEventMinutes) }
        let busyIDs = try resolveBusyCalendarIDs(service: service)

        let request = PlanningRequest(
            goal: goal,
            rangeStart: range.start,
            rangeEnd: range.end,
            preferences: prefs,
            tasks: tasks,
            busyCalendarIDs: busyIDs
        )

        let context = planner.buildContext(request: request)
        if !json {
            PlanRenderer.printContext(context, config: config, verbose: verbose)
        }

        let plan: Plan
        if offline {
            guard !tasks.isEmpty else {
                throw CLIError("--offline needs at least one --task, for example --task \"写周报:90\".")
            }
            plan = planner.planHeuristically(request: request)
        } else {
            guard let resolved = Credentials.resolveAPIKey(
                config: config,
                explicit: apiKey,
                keychainHint: { KeychainHint.announce() }
            ) else {
                throw CLIError("""
                No API key found. Store one with `calpilot config set-key <key>`, export \
                CALPILOT_API_KEY (or \(config.apiKeyEnv)), or use `--offline` to schedule \
                without a language model.
                """)
            }
            let client = LLMClient(config: config, apiKey: resolved.key, model: model)
            if !json {
                Console.heading("Asking \(client.model)")
                Console.note("  \(config.baseURL)\(config.chatPath)")
            }
            plan = try await planner.planWithLLM(request: request, client: client)
        }

        if !json {
            PlanRenderer.printPlan(plan, config: config)
        }

        if let out {
            let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            let data = try CalPilotJSON.encoder(pretty: true).encode(plan)
            try data.write(to: url, options: .atomic)
            Console.note("  plan written to \(url.path)")
        }

        if json {
            try Runtime.printJSON(plan)
        }

        guard apply else {
            if !json {
                Console.heading("Dry run")
                Console.note("  nothing was written. Re-run with --apply to save these \(plan.items.count) event(s).")
            }
            return
        }

        guard !plan.items.isEmpty else {
            Console.warn("the plan is empty, nothing to apply")
            return
        }

        let targetName = calendar ?? config.writeCalendar
        if !yes {
            guard Console.confirm("Write \(plan.items.count) event(s) into \"\(targetName)\"?", default: true) else {
                Console.note("cancelled")
                throw ExitCode(ExitCodes.cancelled)
            }
        }
        let created = try PlanRenderer.apply(
            plan: plan,
            config: config,
            service: service,
            calendarName: calendar,
            source: "plan:\(plan.model)"
        )
        Console.heading("Written")
        Console.success("\(created.count) event(s) added to \(created.first?.calendarName ?? targetName)")
        Console.note("  undo with `calpilot undo`")
    }

    private func resolveBusyCalendarIDs(service: CalendarService) throws -> [String]? {
        guard let busyCalendars else { return nil }
        let names = busyCalendars.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let ids = names.compactMap { service.findCalendar(named: $0)?.calendarIdentifier }
        if ids.isEmpty {
            throw CLIError("None of the calendars in --busy-calendars exist. Run `calpilot calendars`.")
        }
        return ids
    }
}

// MARK: - apply

struct ApplyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Write a previously saved plan file into the calendar."
    )

    @Argument(help: "Path to a plan JSON file produced by `calpilot plan --out`.")
    var planPath: String

    @Option(name: .long, help: "Calendar to write into (defaults to the configured one).")
    var calendar: String?

    @Flag(name: .long, help: "Skip the confirmation prompt.")
    var yes = false

    @Flag(name: .long, help: "Only apply events that are already marked as applied.")
    var dryRun = false

    func run() async throws {
        let config = try Runtime.loadConfig()
        let url = URL(fileURLWithPath: (planPath as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url) else {
            throw CLIError("Could not read \(url.path)")
        }
        let plan = try CalPilotJSON.decoder().decode(Plan.self, from: data)
        PlanRenderer.printPlan(plan, config: config)

        guard !dryRun else {
            Console.note("dry run: nothing written")
            return
        }
        guard !plan.items.isEmpty else {
            Console.warn("the plan contains no events")
            return
        }
        let service = try await Runtime.connectedService(config: config)
        let targetName = calendar ?? config.writeCalendar
        if !yes {
            guard Console.confirm("Write \(plan.items.count) event(s) into \"\(targetName)\"?", default: true) else {
                Console.note("cancelled")
                throw ExitCode(ExitCodes.cancelled)
            }
        }
        let created = try PlanRenderer.apply(
            plan: plan,
            config: config,
            service: service,
            calendarName: calendar,
            source: "apply:\(url.lastPathComponent)"
        )
        Console.success("\(created.count) event(s) added to \(created.first?.calendarName ?? targetName)")
    }
}

// MARK: - undo

struct UndoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "undo",
        abstract: "Remove the events CalPilot created in its most recent batch.",
        discussion: "Undo only ever touches events CalPilot itself created and journaled."
    )

    @Option(name: .long, help: "Undo a specific batch identifier instead of the latest one.")
    var batch: String?

    @Flag(name: .long, help: "Show what would be removed without changing anything.")
    var dryRun = false

    @Flag(name: .long, help: "Skip the confirmation prompt.")
    var yes = false

    @Flag(name: .long, help: "List every batch CalPilot has recorded.")
    var list = false

    func run() async throws {
        let config = try Runtime.loadConfig()
        let all = Journal.all()
        guard !all.isEmpty else {
            Console.note("the journal is empty — CalPilot has not written anything yet")
            return
        }

        if list {
            let grouped = Dictionary(grouping: all.filter { $0.action == .create }, by: { $0.batchID })
            let rows = grouped.keys.sorted().map { key -> [String] in
                let entries = grouped[key] ?? []
                let stamp = entries.first.map { Format.human($0.timestamp, calendar: config.calendar) } ?? ""
                let source = entries.first?.source ?? ""
                return [key, stamp, "\(entries.count)", source]
            }
            Console.table(headers: ["Batch", "When", "Events", "Source"], rows: rows)
            return
        }

        let selected: (batchID: String, entries: [JournalEntry])
        if let batch {
            let entries = all.filter { $0.batchID == batch && $0.action == .create }
            guard !entries.isEmpty else { throw CLIError("No created events recorded for batch \(batch).") }
            selected = (batch, entries)
        } else {
            guard let last = Journal.lastCreateBatch() else {
                Console.note("nothing to undo")
                return
            }
            selected = last
        }

        print("  batch \(selected.batchID)")
        for entry in selected.entries {
            print("  \(Format.human(entry.start, calendar: config.calendar))  \(entry.title)")
        }
        if dryRun {
            Console.note("dry run: nothing removed")
            return
        }
        if !yes {
            guard Console.confirm("Remove \(selected.entries.count) event(s)?", default: true) else {
                Console.note("cancelled")
                throw ExitCode(ExitCodes.cancelled)
            }
        }

        let service = try await Runtime.connectedService(config: config)
        let batchID = Journal.newBatchID()
        var removed = 0
        for entry in selected.entries {
            do {
                try service.deleteEvent(id: entry.eventID, fallback: (entry.title, entry.start))
            } catch {
                Console.warn("could not remove \"\(entry.title)\": \(error)")
                continue
            }
            try Journal.append(JournalEntry(
                action: .delete,
                batchID: batchID,
                eventID: entry.eventID,
                calendarID: entry.calendarID,
                title: entry.title,
                start: entry.start,
                end: entry.end,
                source: "undo:\(selected.batchID)"
            ))
            removed += 1
        }
        Console.success("removed \(removed) of \(selected.entries.count) event(s)")
    }
}
