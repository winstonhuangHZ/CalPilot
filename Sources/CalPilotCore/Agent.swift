import Foundation

/// A turn-based scheduling agent.
///
/// One `send(_:)` call is one conversational turn: the model may inspect the calendar,
/// propose a validated plan, remember a preference, or answer. It never writes anything
/// by itself — the write tools go through a confirmation closure supplied by the caller.
///
/// CACHE CONTRACT
/// The transcript is append-only and the system message is byte-stable for as long as the
/// memory block and the mode stay the same. Anything volatile (the current time, how long
/// the user took to reply) rides at the *end* of the transcript inside the newest user
/// message, so the provider's prefix cache keeps hitting across turns.
public final class Agent {
    public enum Event {
        case assistantText(String)
        case toolCall(name: String, summary: String)
        case toolResult(name: String, detail: String)
        case planProposed(Plan)
        case planApplied([EventDTO])
        case memoriesChanged(String)
        case notice(String)
    }

    public enum Mode {
        case tools
        /// Fallback for endpoints without tool calling: the model emits
        /// `{"tool": ..., "arguments": ...}` as JSON instead.
        case jsonProtocol
    }

    /// Everything needed to write a conversation to disk and pick it up later.
    ///
    /// The model transcript is stored rather than replayed from the visible turns: tool
    /// calls and their results are part of the context, and rebuilding them from the
    /// rendered lines would lose both the fidelity and the cacheable prefix.
    public struct State: Codable {
        public var messages: [LLMClient.Message]
        public var pendingPlan: Plan?
        public var lastUserTurnAt: Date?
        public var usage: LLMClient.TokenUsage

        public init(
            messages: [LLMClient.Message] = [],
            pendingPlan: Plan? = nil,
            lastUserTurnAt: Date? = nil,
            usage: LLMClient.TokenUsage = LLMClient.TokenUsage()
        ) {
            self.messages = messages
            self.pendingPlan = pendingPlan
            self.lastUserTurnAt = lastUserTurnAt
            self.usage = usage
        }

        public var isEmpty: Bool { messages.isEmpty }
    }

    public let config: AppConfig
    public let service: CalendarService
    public let client: any LLMChatClient
    public private(set) var memory: MemoryStore
    public private(set) var mode: Mode
    public private(set) var pendingPlan: Plan?
    /// Token accounting for the whole session, including the prefix-cache split.
    public private(set) var usageTotals = LLMClient.TokenUsage()

    private let confirm: (String) -> Bool
    private let emit: (Event) -> Void
    private let now: () -> Date
    private var messages: [LLMClient.Message] = []
    private var installedSystemSignature: String?
    private var lastUserTurnAt: Date?
    private let maxSteps = 8
    private let maxToolResultCharacters = 6_000
    private let transcriptLimit = 320
    /// Computed once per turn so every tool call inside a turn agrees on "now".
    private var turnNow: Date = Date()

    public init(
        config: AppConfig,
        service: CalendarService,
        client: any LLMChatClient,
        memory: MemoryStore,
        mode: Mode = .tools,
        confirm: @escaping (String) -> Bool,
        now: @escaping () -> Date = { Date() },
        emit: @escaping (Event) -> Void
    ) {
        self.config = config
        self.service = service
        self.client = client
        self.memory = memory
        self.mode = mode
        self.confirm = confirm
        self.now = now
        self.emit = emit
    }

    // MARK: - Conversation

    public func reset() {
        messages.removeAll()
        installedSystemSignature = nil
        lastUserTurnAt = nil
        pendingPlan = nil
    }

    public var transcript: [LLMClient.Message] { messages }

    // MARK: - Persistence

    public func exportState() -> State {
        State(
            messages: messages,
            pendingPlan: pendingPlan,
            lastUserTurnAt: lastUserTurnAt,
            usage: usageTotals
        )
    }

    /// Restores a stored conversation. The system message is deliberately *not* restored
    /// verbatim — `installedSystemSignature` is cleared so the next turn rebuilds it from
    /// the current config and memory, which may have changed since the session was saved.
    public func restore(_ state: State) {
        messages = state.messages
        pendingPlan = state.pendingPlan
        lastUserTurnAt = state.lastUserTurnAt
        usageTotals = state.usage
        installedSystemSignature = nil
        if messages.first?.role != "system" {
            installSystemPromptIfNeeded(force: true)
        }
    }

    public var cacheSummary: String {
        guard let ratio = usageTotals.cacheHitRatio else {
            return usageTotals.promptTokens.map { "\($0) input tokens, no cache split reported" } ?? "no token usage reported yet"
        }
        let percent = Int((ratio * 100).rounded())
        let hit = usageTotals.cacheHitTokens ?? 0
        let miss = usageTotals.cacheMissTokens ?? 0
        return "\(percent)% of input tokens were served from the prompt cache (\(hit) hit / \(miss) miss)"
    }

    public func send(_ userText: String) async throws {
        turnNow = now()
        installSystemPromptIfNeeded()
        messages.append(.user(formattedUserTurn(userText, at: turnNow)))
        defer { lastUserTurnAt = turnNow }
        prune()

        var step = 0
        while step < maxSteps {
            step += 1
            let completion = try await nextCompletion()
            if let usage = completion.usage {
                usageTotals.add(usage)
            }

            if let content = completion.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emit(.assistantText(content))
            }

            guard completion.wantsTools else {
                messages.append(.assistant(completion.content ?? ""))
                return
            }

            messages.append(LLMClient.Message(role: "assistant", content: completion.content, toolCalls: completion.toolCalls))

            for call in completion.toolCalls {
                let outcome = execute(call)
                let trimmed = outcome.content.count > maxToolResultCharacters
                    ? String(outcome.content.prefix(maxToolResultCharacters)) + "…(truncated)"
                    : outcome.content
                switch mode {
                case .tools:
                    messages.append(.tool(callID: call.id, name: call.function.name, content: trimmed))
                case .jsonProtocol:
                    let result = JSONValue.obj([
                        "tool_result": .obj([
                            "tool": .string(call.function.name),
                            "result": .string(trimmed),
                        ]),
                    ])
                    messages.append(.user(result.jsonString))
                }
                if outcome.halt {
                    if let spoken = outcome.spokenSummary, !spoken.isEmpty {
                        emit(.assistantText(spoken))
                    }
                    messages.append(.assistant(outcome.spokenSummary ?? ""))
                    return
                }
            }
            if step == maxSteps {
                emit(.notice("stopped after \(maxSteps) tool steps to avoid a loop; ask again to continue"))
            }
        }
    }

    /// Wraps the user's text with the wall-clock facts the model needs in order to reason
    /// about "today" and "tomorrow", and to notice when a conversation has gone stale.
    public func formattedUserTurn(_ text: String, at date: Date) -> String {
        formattedUserTurn(text, at: date, previousTurnAt: lastUserTurnAt)
    }

    /// Explicit-previous variant, so the formatting can be checked without a live turn.
    public func formattedUserTurn(_ text: String, at date: Date, previousTurnAt: Date?) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = config.timeZoneObject
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss xxx"

        var parts = [
            "time: \(stamp.string(from: date))",
            "timezone: \(config.timeZone)",
            "weekday: \(Format.weekday(date, calendar: config.calendar))",
        ]
        if let previous = previousTurnAt {
            parts.append("\(Format.elapsed(since: previous, now: date)) since your previous message")
        }
        return "[\(parts.joined(separator: " | "))]\n\(text)"
    }

    private func nextCompletion() async throws -> LLMClient.Completion {
        switch mode {
        case .tools:
            do {
                return try await client.complete(
                    messages: messages,
                    tools: ToolCatalog.definitions,
                    options: .init(temperature: 0.2)
                )
            } catch let LLMClient.LLMError.toolsUnsupported(detail) {
                mode = .jsonProtocol
                emit(.notice("this endpoint rejected tool calling, switching to the JSON protocol\n  (\(detail))"))
                installSystemPromptIfNeeded(force: true)
                return try await jsonProtocolCompletion()
            }
        case .jsonProtocol:
            return try await jsonProtocolCompletion()
        }
    }

    private func jsonProtocolCompletion() async throws -> LLMClient.Completion {
        let raw = try await client.chat(messages: messages, options: .init(temperature: 0.2, jsonMode: true))
        guard let objectJSON = JSONExtraction.firstObject(in: raw),
              let data = objectJSON.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.objectValue,
              let tool = object["tool"]?.stringValue
        else {
            return LLMClient.Completion(content: raw, toolCalls: [], finishReason: "stop")
        }
        let arguments = object["arguments"] ?? .object([:])
        let call = LLMClient.ToolCall(
            id: "json-\(UUID().uuidString.prefix(6))",
            function: .init(name: tool, arguments: arguments.jsonString)
        )
        return LLMClient.Completion(content: nil, toolCalls: [call], finishReason: "tool_calls")
    }

    /// Trimming is the one operation that cannot preserve the cache prefix, so it only
    /// happens once the transcript is far larger than a normal session.
    private func prune() {
        guard messages.count > transcriptLimit else { return }
        let system = messages.first
        let tail = Array(messages.suffix(transcriptLimit / 2))
        messages = ([system].compactMap { $0 }) + tail
        emit(.notice("the conversation grew very long, so its oldest turns were dropped to stay inside the model's context window"))
    }

    // MARK: - Prompts

    private func systemPromptSignature() -> String {
        "\(memory.promptBlock())||\(mode == .tools ? "tools" : "json")"
    }

    private func installSystemPromptIfNeeded(force: Bool = false) {
        let signature = systemPromptSignature()
        if !force, signature == installedSystemSignature, messages.first?.role == "system" { return }
        let prompt = LLMClient.Message.system(systemPrompt())
        if messages.isEmpty {
            messages.append(prompt)
        } else {
            messages[0] = prompt
        }
        installedSystemSignature = signature
    }

    /// Deliberately free of volatile data so the cached prefix stays valid: the clock
    /// lives at the front of each user turn instead.
    public func systemPrompt() -> String {
        var lines: [String] = []
        lines.append("""
        You are CalPilot, a turn-based calendar agent running on the user's Mac.

        Each turn you may call tools to inspect the real calendar and to propose a concrete
        plan. Work in small steps: always look at the calendar before proposing anything.

        Reading the user's messages:
        - Every user message begins with a bracketed line: [time: … | timezone: … | weekday: …].
          Treat that timestamp as the current moment for that turn. If an older message
          contradicts it, the newest timestamp wins.
        - The same line reports how long the user took to reply. Use it to notice when the
          conversation has gone stale, and re-check the calendar when it has.

        Rules:
        1. Never invent calendar contents. Call `list_events` or `find_free_slots` first.
        2. Every event you propose must come from the free slots the tools reported.
        3. When the user asks how their time was spent, how busy a period was, or where the
           hours went, call `calendar_analysis` and quote its numbers. Never estimate from
           the conversation.
        4. Only `propose_plan` creates a proposal, and only `apply_plan` writes it. The user
           always confirms a write, so never claim an event was created until `apply_plan`
           returns successfully.
        5. When the user changes their mind, call `propose_plan` again with the full,
           corrected plan — a new proposal replaces the previous one.
        6. Call `remember` whenever the user states a durable preference or constraint,
           then confirm it in one short sentence.
        7. Ask a clarifying question with `answer` only when the request is truly ambiguous;
           otherwise make a sensible choice and say so.
        8. Keep replies short. Use the user's language.
        9. After a successful `apply_plan`, state the count and mention that `calpilot undo`
           can take it back.
        """)
        lines.append("")
        lines.append("## Defaults (stable for the whole session)")
        lines.append("Time zone: \(config.timeZone)")
        lines.append("Available hours: \(config.availabilitySummary)")
        lines.append("Buffer between events: \(config.bufferMinutes) minutes (already applied to every free slot the tools report)")
        lines.append("Maximum new events per day: \(config.maxEventsPerDay)")
        lines.append("Default task length: \(config.defaultEventMinutes) minutes")
        lines.append("Write target calendar: \(config.writeCalendar)")
        if !config.extraInstructions.isEmpty {
            lines.append("Standing instructions: \(config.extraInstructions)")
        }
        let block = memory.promptBlock()
        if !block.isEmpty {
            lines.append("")
            lines.append(block)
        }
        if mode == .jsonProtocol {
            lines.append("")
            lines.append(ToolCatalog.jsonProtocolInstructions)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Tool execution

    struct Outcome {
        var content: String
        var halt: Bool = false
        var spokenSummary: String?
    }

    private func execute(_ call: LLMClient.ToolCall) -> Outcome {
        let name = call.function.name
        let args = call.arguments
        emit(.toolCall(name: name, summary: ToolCatalog.summary(for: name, arguments: args)))

        do {
            let outcome = try ToolCatalog.run(
                name: name,
                arguments: args,
                context: ToolCatalog.Context(
                    config: config,
                    service: service,
                    planner: Planner(config: config, service: service),
                    agent: self,
                    confirm: confirm,
                    now: turnNow
                )
            )
            emit(.toolResult(name: name, detail: ToolCatalog.resultSummary(for: name, content: outcome.content)))
            return outcome
        } catch {
            let message = "tool \(name) failed: \(error)"
            emit(.toolResult(name: name, detail: message))
            let escaped = message
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "'")
            return Outcome(content: #"{"error": "\#(escaped)"}"#)
        }
    }

    // MARK: - Called by the tools

    func storePlan(_ plan: Plan) {
        pendingPlan = plan
        emit(.planProposed(plan))
    }

    /// Drops the current proposal, e.g. after it was written out.
    public func clearPendingPlan() {
        pendingPlan = nil
    }

    @discardableResult
    public func remember(text: String, kind: MemoryEntry.Kind = .preference, pinned: Bool = false) -> MemoryEntry? {
        guard let entry = memory.add(text: text, kind: kind, pinned: pinned) else { return nil }
        try? memory.save()
        emit(.memoriesChanged("remembered: \(entry.text)"))
        return entry
    }

    @discardableResult
    public func forget(idOrPrefix: String) -> MemoryEntry? {
        guard let removed = memory.remove(idOrPrefix: idOrPrefix) else { return nil }
        try? memory.save()
        emit(.memoriesChanged("forgot: \(removed.text)"))
        return removed
    }

    /// Pins or unpins a memory so it is always part of the prompt.
    @discardableResult
    public func setPinned(idOrPrefix: String, pinned: Bool) -> MemoryEntry? {
        let needle = idOrPrefix.lowercased()
        guard let index = memory.entries.firstIndex(where: {
            $0.id.lowercased() == needle || $0.id.lowercased().hasPrefix(needle)
        }) else { return nil }
        memory.entries[index].pinned = pinned
        try? memory.save()
        let entry = memory.entries[index]
        emit(.memoriesChanged("\(pinned ? "pinned" : "unpinned"): \(entry.text)"))
        return entry
    }

    func emitPlanApplied(_ events: [EventDTO]) {
        pendingPlan = nil
        emit(.planApplied(events))
    }
}
