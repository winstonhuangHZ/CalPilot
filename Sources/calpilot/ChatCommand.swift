import ArgumentParser
import CalPilotCore
import Foundation

/// The turn-based interface: one line in, one agent turn out.
struct ChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chat",
        abstract: "Talk to the scheduling agent, turn by turn.",
        discussion: """
        Every reply is one turn. The agent inspects your real calendar, proposes plans, and
        only writes them after you confirm. Type /help inside the session for commands.
        """
    )

    @Option(name: .long, help: "Send this as the first turn instead of typing it.")
    var goal: String?

    @Flag(name: .long, help: "Run only the first turn (with --goal) and exit.")
    var once = false

    @Option(name: .long, help: "Language model override.")
    var model: String?

    @Option(name: .long, help: "API key override.")
    var apiKey: String?

    @Flag(name: .long, help: "Ignore the saved memory for this session.")
    var noMemory = false

    func run() async throws {
        let config = try Runtime.loadConfig()
        let service = try await Runtime.connectedService(config: config)
        guard let resolved = Credentials.resolveAPIKey(config: config, explicit: apiKey) else {
            throw CLIError("""
            No API key found. Store one with `calpilot config set-key <key>` or export \
            CALPILOT_API_KEY (or \(config.apiKeyEnv)).
            """)
        }
        let client = LLMClient(config: config, apiKey: resolved.key, model: model)
        let memory = noMemory ? MemoryStore() : MemoryStore.loadRecovering()

        let session = Agent(
            config: config,
            service: service,
            client: client,
            memory: memory,
            confirm: { Console.confirm($0, default: true) },
            emit: { event in ChatRenderer.render(event, config: config) }
        )

        banner(config: config, service: service, client: client, memory: session.memory)

        if let goal {
            Console.note("\n  › \(goal)")
            do {
                try await session.send(goal)
            } catch {
                Console.error("\(error)")
            }
            if once { return }
        }

        while true {
            print(Console.cyan("› "), terminator: "")
            guard let line = readLine() else {
                print("")
                break
            }
            let input = line.trimmingCharacters(in: .whitespaces)
            guard !input.isEmpty else { continue }

            if input.hasPrefix("/") {
                if try await handleSlashCommand(input, session: session, config: config, service: service) {
                    break
                }
                continue
            }

            do {
                try await session.send(input)
            } catch {
                Console.error("\(error)")
            }
        }

        Console.note("\nsession over · \(session.cacheSummary)")
    }

    private func banner(config: AppConfig, service: CalendarService, client: LLMClient, memory: MemoryStore) {
        Console.heading("CalPilot chat")
        Console.note("  model      \(client.modelName)  ·  \(config.baseURL)")
        Console.note("  calendars  \(service.calendarDTOs().count) visible, writing to \"\(config.writeCalendar)\"")
        Console.note("  memory     \(memory.entries.count) entr\(memory.entries.count == 1 ? "y" : "ies")\(memory.entries.isEmpty ? "" : " (\(memory.promptEntries().count) in every prompt)")")
        Console.note("  hours      \(config.workDayStart)-\(config.workDayEnd), \(Format.duration(minutes: config.bufferMinutes)) buffer")
        Console.note("\n  Type what you want scheduled. /help for commands, /exit to leave.")
        Console.note("  Any write is shown as a proposal first and asks for confirmation.\n")
    }

    /// Returns true when the session should end.
    private func handleSlashCommand(
        _ input: String,
        session: Agent,
        config: AppConfig,
        service: CalendarService
    ) async throws -> Bool {
        let parts = input.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts.first?.lowercased() ?? ""
        let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

        switch command {
        case "exit", "quit", "q":
            return true

        case "help":
            print("""

              /events [days]      list existing events (default 7 days)
              /free [days]        list free slots (default 7 days)
              /plan <goal>        ask the agent to draft a plan
              /apply              write the current proposal (asks first)
              /undo               remove the last batch CalPilot wrote
              /memories           list the personal memory block
              /memory <text>      remember a preference
              /pin <text>         remember a preference and pin it
              /forget <id>        delete a memory
              /usage              token and prompt-cache statistics
              /reset              start the conversation over (calendar untouched)
              /exit               leave

            """)

        case "events", "list":
            let days = Int(argument) ?? 7
            let range = try DateRangeResolver.resolve(from: nil, to: nil, days: days, defaultFromNow: false, config: config)
            let events = service.events(from: range.start, to: range.end)
            Console.table(
                headers: ["Day", "Wk", "Time", "Title", "Calendar"],
                rows: events.map { event in
                    [
                        Format.day(event.start, calendar: config.calendar),
                        Format.weekday(event.start, calendar: config.calendar),
                        event.isAllDay ? "all-day" : "\(Format.clock(event.start, calendar: config.calendar))-\(Format.clock(event.end, calendar: config.calendar))",
                        event.title,
                        event.calendarName,
                    ]
                }
            )

        case "free":
            let days = Int(argument) ?? 7
            let range = try DateRangeResolver.resolve(from: nil, to: nil, days: days, defaultFromNow: true, config: config)
            let events = service.events(from: range.start, to: range.end).filter { !$0.isAllDay }
            let slots = SlotFinder(config: config).freeSlots(
                busy: events.map { $0.interval },
                from: range.start,
                to: range.end,
                minMinutes: 30
            )
            Console.table(
                headers: ["Day", "Wk", "Time", "Length"],
                rows: slots.map { slot in
                    [
                        Format.day(slot.start, calendar: config.calendar),
                        Format.weekday(slot.start, calendar: config.calendar),
                        "\(Format.clock(slot.start, calendar: config.calendar))-\(Format.clock(slot.end, calendar: config.calendar))",
                        Format.duration(minutes: slot.minutes),
                    ]
                }
            )

        case "plan":
            guard !argument.isEmpty else {
                Console.note("  usage: /plan <what you want scheduled>")
                break
            }
            try await session.send(argument)

        case "apply":
            guard let plan = session.pendingPlan else {
                Console.note("  there is no proposal yet — ask for a plan first")
                break
            }
            guard Console.confirm("Write \(plan.items.count) event(s) into \"\(config.writeCalendar)\"?", default: true) else {
                Console.note("  cancelled")
                break
            }
            let created = try PlanApplier.apply(
                plan: plan,
                config: config,
                service: service,
                source: "chat:/apply"
            )
            session.clearPendingPlan()
            Console.success("\(created.count) event(s) written. `calpilot undo` takes them back.")

        case "undo":
            guard Console.confirm("Remove the events from CalPilot's most recent batch?", default: true) else {
                Console.note("  cancelled")
                break
            }
            if let result = try PlanApplier.undo(config: config, service: service) {
                Console.success("removed \(result.removed) of \(result.attempted) event(s)")
                for failure in result.failures { Console.warn(failure) }
            } else {
                Console.note("  nothing to undo")
            }

        case "memories":
            let entries = session.memory.entries
            if entries.isEmpty {
                Console.note("  the memory block is empty")
            } else {
                Console.table(
                    headers: ["ID", "Kind", "Pinned", "Memory"],
                    rows: entries.map { entry in
                        [entry.id, entry.kind.rawValue, entry.pinned ? "yes" : "", entry.text]
                    }
                )
            }

        case "memory", "pin":
            guard !argument.isEmpty else {
                Console.note("  usage: /memory <text>")
                break
            }
            let (kind, text) = Self.parseMemoryPrefix(argument)
            if session.remember(text: text, kind: kind, pinned: command == "pin") == nil {
                Console.note("  nothing to remember")
            }

        case "forget":
            guard !argument.isEmpty else {
                Console.note("  usage: /forget <id>")
                break
            }
            if session.forget(idOrPrefix: argument) == nil {
                Console.note("  no memory matches \"\(argument)\"")
            }

        case "usage":
            let usage = session.usageTotals
            Console.note("  input       \(usage.promptTokens.map(String.init) ?? "n/a")")
            Console.note("  output      \(usage.completionTokens.map(String.init) ?? "n/a")")
            Console.note("  cache       \(session.cacheSummary)")
            Console.note("  turns       \(session.transcript.filter { $0.role == "user" }.count)")

        case "reset":
            session.reset()
            Console.note("  conversation cleared (the calendar was not touched)")

        default:
            Console.note("  unknown command /\(command) — try /help")
        }
        return false
    }

    /// `constraint: 周三晚上不要排事` selects a different memory kind.
    static func parseMemoryPrefix(_ argument: String) -> (MemoryEntry.Kind, String) {
        for kind in MemoryEntry.Kind.allCases {
            let prefix = "\(kind.rawValue):"
            if argument.lowercased().hasPrefix(prefix) {
                return (kind, String(argument.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
            }
        }
        return (.preference, argument)
    }
}

enum ChatRenderer {
    static func render(_ event: Agent.Event, config: AppConfig) {
        switch event {
        case let .assistantText(text):
            print("\n\(text)\n")
        case let .toolCall(_, summary):
            print(Console.dim("  · ") + Console.cyan(summary))
        case let .toolResult(_, detail):
            print(Console.dim("    → \(detail)"))
        case let .planProposed(plan):
            PlanRenderer.printPlan(plan, config: config)
            print("")
            Console.note("  say \"写入\" to save it, or tell me what to change. /apply also works.")
        case let .planApplied(events):
            Console.success("wrote \(events.count) event(s) to \(events.first?.calendarName ?? config.writeCalendar)")
        case let .memoriesChanged(text):
            print(Console.dim("  🧠 \(text)"))
        case let .notice(text):
            Console.note("  " + text)
        }
    }
}
