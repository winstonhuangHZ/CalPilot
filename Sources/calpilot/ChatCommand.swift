import ArgumentParser
import CalPilotCore
import Foundation

/// Collects the visible turns and the model transcript of a conversation and writes them
/// to disk after every turn, so an interrupted session is never lost.
final class SessionRecorder {
    private(set) var session: ChatSession

    init(_ session: ChatSession) {
        self.session = session
    }

    var id: UUID { session.id }
    var isNew: Bool { session.turns.isEmpty }

    func record(_ event: Agent.Event, at date: Date = Date()) {
        switch event {
        case let .assistantText(text):
            append(.assistant, text, at: date)
        case let .toolCall(_, summary):
            append(.tool, summary, at: date)
        case let .toolResult(_, detail):
            append(.toolResult, detail, at: date)
        case let .planProposed(plan):
            let titles = plan.items.map { $0.title }.joined(separator: "、")
            append(.notice, "提案 \(plan.items.count) 个事件：\(titles)", at: date)
        case let .planApplied(events):
            append(.notice, "已写入 \(events.count) 个事件", at: date)
        case let .memoriesChanged(text):
            append(.notice, text, at: date)
        case let .notice(text):
            append(.notice, text, at: date)
        }
    }

    func append(_ kind: ChatTurn.Kind, _ text: String, at date: Date = Date()) {
        session.turns.append(ChatTurn(kind: kind, text: text, at: date))
        if !session.titleIsManual {
            session.title = ChatSession.suggestedTitle(from: session.turns)
        }
    }

    func rename(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.title = trimmed
        session.titleIsManual = true
    }

    /// Snapshot the agent and flush. Best effort: a failed write must not kill the session.
    func persist(agent: Agent) {
        session.agent = agent.exportState()
        session.updatedAt = Date()
        do {
            try SessionStore.save(session)
        } catch {
            Console.warn("could not save the conversation: \(error)")
        }
    }
}

/// The turn-based interface: one line in, one agent turn out.
struct ChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chat",
        abstract: "Talk to the scheduling agent, turn by turn.",
        discussion: """
        Every reply is one turn. The agent inspects your real calendar, proposes plans, and
        only writes them after you confirm. Conversations are saved as you go, so
        `--resume` picks one up. Type /help inside the session for commands.
        """
    )

    @Option(name: .long, help: "Send this as the first turn instead of typing it.")
    var goal: String?

    @Flag(name: .long, help: "Run only the first turn (with --goal) and exit.")
    var once = false

    @Option(name: .long, help: "Continue a saved conversation, by id or unique id prefix.")
    var resume: String?

    @Option(name: .long, help: "Language model override.")
    var model: String?

    @Option(name: .long, help: "API key override.")
    var apiKey: String?

    @Flag(name: .long, help: "Ignore the saved memory for this session.")
    var noMemory = false

    func run() async throws {
        let config = try Runtime.loadConfig()
        let service = try await Runtime.connectedService(config: config)
        guard let resolved = Credentials.resolveAPIKey(
            config: config,
            explicit: apiKey,
            keychainHint: { KeychainHint.announce() }
        ) else {
            throw CLIError("""
            No API key found. Store one with `calpilot config set-key <key>` or export \
            CALPILOT_API_KEY (or \(config.apiKeyEnv)).
            """)
        }
        let client = LLMClient(config: config, apiKey: resolved.key, model: model)
        let memory = noMemory ? MemoryStore() : MemoryStore.loadRecovering()

        let restored: ChatSession?
        if let resume {
            guard let id = SessionStore.resolve(prefix: resume), let loaded = SessionStore.load(id: id) else {
                throw CLIError("No saved conversation matches \"\(resume)\". Run `calpilot sessions list`.")
            }
            restored = loaded
        } else {
            restored = nil
        }
        let recorder = SessionRecorder(restored ?? ChatSession())

        let session = Agent(
            config: config,
            service: service,
            client: client,
            memory: memory,
            confirm: { Console.confirm($0, default: true) },
            emit: { event in
                recorder.record(event)
                ChatRenderer.render(event, config: config)
            }
        )
        if let restored {
            session.restore(restored.agent)
        }

        banner(config: config, service: service, client: client, memory: session.memory, recorder: recorder)

        if let goal {
            Console.note("\n  › \(goal)")
            recorder.append(.user, goal)
            do {
                try await session.send(goal)
            } catch {
                recorder.append(.error, "\(error)")
                Console.error("\(error)")
            }
            recorder.persist(agent: session)
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
                if try await handleSlashCommand(
                    input,
                    session: session,
                    recorder: recorder,
                    config: config,
                    service: service
                ) {
                    break
                }
                recorder.persist(agent: session)
                continue
            }

            recorder.append(.user, input)
            do {
                try await session.send(input)
            } catch {
                recorder.append(.error, "\(error)")
                Console.error("\(error)")
            }
            recorder.persist(agent: session)
        }

        recorder.persist(agent: session)
        Console.note("\nsession over · \(session.cacheSummary)")
        Console.note("saved as \"\(recorder.session.title)\" · resume with `calpilot chat --resume \(String(recorder.id.uuidString.prefix(8)).lowercased())`")
    }

    private func banner(
        config: AppConfig,
        service: CalendarService,
        client: LLMClient,
        memory: MemoryStore,
        recorder: SessionRecorder
    ) {
        Console.heading(recorder.isNew ? "CalPilot chat" : "CalPilot chat · \(recorder.session.title)")
        Console.note("  model      \(client.modelName)  ·  \(config.baseURL)")
        Console.note("  calendars  \(service.calendarDTOs().count) visible, writing to \"\(config.writeCalendar)\"")
        Console.note("  memory     \(memory.entries.count) entr\(memory.entries.count == 1 ? "y" : "ies")\(memory.entries.isEmpty ? "" : " (\(memory.promptEntries().count) in every prompt)")")
        Console.note("  hours      \(config.availabilitySummary), \(Format.duration(minutes: config.bufferMinutes)) buffer")
        if !recorder.isNew {
            Console.note("  resumed    \(recorder.session.turns.count) turns from \(Format.human(recorder.session.updatedAt, calendar: config.calendar))")
        }
        Console.note("\n  Type what you want scheduled. /help for commands, /exit to leave.")
        Console.note("  Any write is shown as a proposal first and asks for confirmation.\n")
    }

    /// Returns true when the session should end.
    private func handleSlashCommand(
        _ input: String,
        session: Agent,
        recorder: SessionRecorder,
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

              /events [days]      list existing events from today
              /free [days]        list free slots (default 7 days)
              /history [days]     summarise the last N days (default 30)
              /plan <goal>        ask the agent to draft a plan
              /apply              write the current proposal (asks first)
              /undo               remove the last batch CalPilot wrote
              /memories           list the personal memory block
              /memory <text>      remember a preference
              /pin <text>         remember a preference and pin it
              /forget <id>        delete a memory
              /sessions           list saved conversations
              /title <text>       rename this conversation
              /usage              token and prompt-cache statistics
              /reset              clear the model context (calendar untouched)
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
                        Format.weekdayLabel(Format.weekday(event.start, calendar: config.calendar)),
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
                        Format.weekdayLabel(Format.weekday(slot.start, calendar: config.calendar)),
                        "\(Format.clock(slot.start, calendar: config.calendar))-\(Format.clock(slot.end, calendar: config.calendar))",
                        Format.duration(minutes: slot.minutes),
                    ]
                }
            )

        case "history", "analyze":
            let days = Int(argument) ?? 30
            let end = Date()
            let start = config.calendar.date(byAdding: .day, value: -days, to: end) ?? end.addingTimeInterval(-Double(days) * 86_400)
            let events = service.events(from: start, to: end)
            let analysis = CalendarAnalyzer.analyze(events: events, config: config, rangeStart: start, rangeEnd: end)
            AnalyzeCommand.ReportRenderer.render(analysis, config: config)

        case "plan":
            guard !argument.isEmpty else {
                Console.note("  usage: /plan <what you want scheduled>")
                break
            }
            recorder.append(.user, argument)
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
            recorder.append(.notice, "已写入 \(created.count) 个事件")
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

        case "sessions":
            let saved = SessionStore.list()
            guard !saved.isEmpty else {
                Console.note("  no saved conversations")
                break
            }
            Console.table(
                headers: ["ID", "Updated", "Msgs", "Title", ""],
                rows: saved.map { item in
                    [
                        String(item.id.uuidString.prefix(8)).lowercased(),
                        Format.human(item.updatedAt, calendar: config.calendar),
                        "\(item.messageCount)",
                        item.title,
                        item.id == recorder.id ? "current" : "",
                    ]
                }
            )

        case "title":
            guard !argument.isEmpty else {
                Console.note("  usage: /title <text>")
                break
            }
            recorder.rename(argument)
            Console.success("renamed to \"\(recorder.session.title)\"")

        case "usage":
            let usage = session.usageTotals
            Console.note("  input       \(usage.promptTokens.map(String.init) ?? "n/a")")
            Console.note("  output      \(usage.completionTokens.map(String.init) ?? "n/a")")
            Console.note("  cache       \(session.cacheSummary)")
            Console.note("  turns       \(session.transcript.filter { $0.role == "user" }.count)")

        case "reset":
            session.reset()
            Console.note("  model context cleared (the calendar and the saved transcript were not touched)")

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
