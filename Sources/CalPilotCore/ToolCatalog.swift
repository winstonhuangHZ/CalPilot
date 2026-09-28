import Foundation

/// The tools the agent may call, plus their execution.
///
/// Read tools never mutate anything. Write tools (`propose_plan`, `apply_plan`,
/// `undo_last_batch`) always route through the confirmation closure the caller
/// supplied, so a model can never write to the calendar on its own.
public enum ToolCatalog {
    public struct Context {
        public var config: AppConfig
        public var service: CalendarService
        public var planner: Planner
        public var agent: Agent
        public var confirm: (String) -> Bool
        public var now: Date

        public init(
            config: AppConfig,
            service: CalendarService,
            planner: Planner,
            agent: Agent,
            confirm: @escaping (String) -> Bool,
            now: Date
        ) {
            self.config = config
            self.service = service
            self.planner = planner
            self.agent = agent
            self.confirm = confirm
            self.now = now
        }
    }

    // MARK: - Definitions

    public static let definitions: [LLMClient.ToolDefinition] = [
        LLMClient.ToolDefinition(
            name: "list_events",
            description: """
            List existing events in a window. Use it to see what is immovable, and pass a \
            past `from`/`to` to look at history.
            """,
            parameters: .obj([
                "type": .string("object"),
                "properties": .obj([
                    "from": .obj(["type": .string("string"), "description": .string("Start of the range, e.g. 2026-09-28, today, 明天 09:00, +2d.")]),
                    "to": .obj(["type": .string("string"), "description": .string("End of the range.")]),
                    "days": .obj(["type": .string("integer"), "description": .string("Days to look ahead when `to` is omitted. Defaults to 7.")]),
                    "calendar": .obj(["type": .string("string"), "description": .string("Limit to one calendar by name.")]),
                ]),
                "required": .array([]),
            ])
        ),
        LLMClient.ToolDefinition(
            name: "calendar_analysis",
            description: """
            Aggregate statistics over a past window: hours per calendar, average load per \
            weekday, busiest days, how much of the working day is booked, and how fragmented \
            the free time is. Use this instead of guessing when the user asks how their time \
            was spent, whether a week was busy, or where the hours went.
            """,
            parameters: .obj([
                "type": .string("object"),
                "properties": .obj([
                    "lookback_days": .obj([
                        "type": .string("integer"),
                        "description": .string("How many days back from now to analyse. Defaults to 30."),
                    ]),
                    "from": .obj([
                        "type": .string("string"),
                        "description": .string("Explicit window start, overriding lookback_days."),
                    ]),
                    "to": .obj([
                        "type": .string("string"),
                        "description": .string("Explicit window end. Defaults to now."),
                    ]),
                    "calendar": .obj([
                        "type": .string("string"),
                        "description": .string("Limit the analysis to one calendar."),
                    ]),
                ]),
                "required": .array([]),
            ])
        ),
        LLMClient.ToolDefinition(
            name: "find_free_slots",
            description: "Return the free slots inside the user's available hours, with buffers already applied.",
            parameters: .obj([
                "type": .string("object"),
                "properties": .obj([
                    "from": .obj(["type": .string("string")]),
                    "to": .obj(["type": .string("string")]),
                    "days": .obj(["type": .string("integer"), "description": .string("Defaults to 7.")]),
                    "min_minutes": .obj(["type": .string("integer"), "description": .string("Only report slots at least this long. Defaults to 30.")]),
                ]),
                "required": .array([]),
            ])
        ),
        LLMClient.ToolDefinition(
            name: "propose_plan",
            description: """
            Show the user a concrete plan. Every event must lie inside a free slot reported by \
            find_free_slots. This only displays a proposal; nothing is written to the calendar.
            Calling it again replaces the previous proposal.
            """,
            parameters: .obj([
                "type": .string("object"),
                "properties": .obj([
                    "summary": .obj(["type": .string("string"), "description": .string("One short paragraph about the shape of the plan.")]),
                    "goal": .obj(["type": .string("string"), "description": .string("The request this plan answers.")]),
                    "from": .obj(["type": .string("string")]),
                    "to": .obj(["type": .string("string")]),
                    "days": .obj(["type": .string("integer")]),
                    "events": .obj([
                        "type": .string("array"),
                        "items": .obj([
                            "type": .string("object"),
                            "properties": .obj([
                                "title": .obj(["type": .string("string")]),
                                "start": .obj(["type": .string("string"), "description": .string("ISO-8601 local time with UTC offset.")]),
                                "end": .obj(["type": .string("string")]),
                                "duration_minutes": .obj(["type": .string("integer")]),
                                "location": .obj(["type": .string("string")]),
                                "notes": .obj(["type": .string("string")]),
                                "reason": .obj(["type": .string("string"), "description": .string("One sentence on why this slot.")]),
                            ]),
                            "required": .array([.string("title"), .string("start")]),
                        ]),
                    ]),
                    "unscheduled": .obj([
                        "type": .string("array"),
                        "items": .obj([
                            "type": .string("object"),
                            "properties": .obj([
                                "title": .obj(["type": .string("string")]),
                                "reason": .obj(["type": .string("string")]),
                                "suggestedMinutes": .obj(["type": .string("integer")]),
                            ]),
                            "required": .array([.string("title")]),
                        ]),
                    ]),
                ]),
                "required": .array([.string("events")]),
            ])
        ),
        LLMClient.ToolDefinition(
            name: "apply_plan",
            description: "Write the most recent proposal into the calendar. The user confirms first; only call this after they agree.",
            parameters: .obj(["type": .string("object"), "properties": .obj([:]), "required": .array([])])
        ),
        LLMClient.ToolDefinition(
            name: "undo_last_batch",
            description: "Remove the events CalPilot created in its most recent batch.",
            parameters: .obj(["type": .string("object"), "properties": .obj([:]), "required": .array([])])
        ),
        LLMClient.ToolDefinition(
            name: "list_memories",
            description: "List everything currently in the user's personal memory block.",
            parameters: .obj(["type": .string("object"), "properties": .obj([:]), "required": .array([])])
        ),
        LLMClient.ToolDefinition(
            name: "remember",
            description: "Store a durable preference, constraint, fact, or person detail about this user.",
            parameters: .obj([
                "type": .string("object"),
                "properties": .obj([
                    "text": .obj(["type": .string("string"), "description": .string("A short standing instruction, e.g. 上午不要安排会议.")]),
                    "kind": .obj([
                        "type": .string("string"),
                        "enum": .array([.string("preference"), .string("constraint"), .string("fact"), .string("person")]),
                    ]),
                    "pinned": .obj(["type": .string("boolean"), "description": .string("Pin it so it is always in context.")]),
                ]),
                "required": .array([.string("text")]),
            ])
        ),
        LLMClient.ToolDefinition(
            name: "forget",
            description: "Delete a memory by its id.",
            parameters: .obj([
                "type": .string("object"),
                "properties": .obj([
                    "id": .obj(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
            ])
        ),
        LLMClient.ToolDefinition(
            name: "answer",
            description: "Reply to the user without touching the calendar. Use this to ask a clarifying question or to report a result.",
            parameters: .obj([
                "type": .string("object"),
                "properties": .obj([
                    "text": .obj(["type": .string("string")]),
                ]),
                "required": .array([.string("text")]),
            ])
        ),
    ]

    /// Instructions used when the endpoint cannot do native tool calling.
    public static let jsonProtocolInstructions = """
    ## JSON protocol (this endpoint has no tool API)
    Instead of tool calls, reply with exactly one JSON object per turn:

      {"tool": "<name>", "arguments": { ... }}

    You will receive the tool result as a user message shaped like
      {"tool_result": {"tool": "<name>", "result": <result>}}

    Available tools and their arguments:
    \(definitions.map { definition in
        let schema = definition.function.parameters
        let properties = schema["properties"]?.objectValue?.keys.sorted().joined(separator: ", ") ?? ""
        return "  - \(definition.function.name)(\(properties))"
    }.joined(separator: "\n"))

    Use {"tool": "answer", "arguments": {"text": "..."}} when you are done talking.
    """

    // MARK: - Dispatch

    static func run(name: String, arguments: [String: JSONValue], context: Context) throws -> Agent.Outcome {
        switch name {
        case "list_events":
            return try listEvents(arguments: arguments, context: context)
        case "calendar_analysis":
            return try calendarAnalysis(arguments: arguments, context: context)
        case "find_free_slots":
            return try findFreeSlots(arguments: arguments, context: context)
        case "propose_plan":
            return try proposePlan(arguments: arguments, context: context)
        case "apply_plan":
            return try applyPlan(context: context)
        case "undo_last_batch":
            return try undoLastBatch(context: context)
        case "list_memories":
            return listMemories(context: context)
        case "remember":
            return remember(arguments: arguments, context: context)
        case "forget":
            return forget(arguments: arguments, context: context)
        case "answer":
            let text = arguments["text"]?.stringValue ?? ""
            return Agent.Outcome(content: #"{"ok": true}"#, halt: true, spokenSummary: text)
        default:
            return Agent.Outcome(content: #"{"error": "unknown tool \#(name)"}"#)
        }
    }

    // MARK: - Read tools

    private static func listEvents(arguments: [String: JSONValue], context: Context) throws -> Agent.Outcome {
        let config = context.config
        let range = try DateRangeResolver.resolve(
            from: arguments["from"]?.stringValue,
            to: arguments["to"]?.stringValue,
            days: arguments["days"]?.intValue ?? 7,
            defaultFromNow: true,
            config: config,
            now: context.now
        )
        var ids: [String]? = nil
        if let name = arguments["calendar"]?.stringValue,
           let match = context.service.findCalendar(named: name) {
            ids = [match.calendarIdentifier]
        }
        let events = context.service.events(from: range.start, to: range.end, calendarIDs: ids)
        let payload = events.map { event -> JSONValue in
            .obj([
                "title": .string(event.title),
                "start": .string(Format.iso(event.start, calendar: config.calendar)),
                "end": .string(Format.iso(event.end, calendar: config.calendar)),
                "allDay": .bool(event.isAllDay),
                "calendar": .string(event.calendarName),
                "createdByCalPilot": .bool(event.createdByCalPilot),
                "recurring": .bool(event.isRecurring),
            ])
        }
        let result = JSONValue.obj([
            "windowStart": .string(Format.iso(range.start, calendar: config.calendar)),
            "windowEnd": .string(Format.iso(range.end, calendar: config.calendar)),
            "timeZone": .string(config.timeZone),
            "events": .array(payload),
        ])
        return Agent.Outcome(content: result.jsonString)
    }

    private static func findFreeSlots(arguments: [String: JSONValue], context: Context) throws -> Agent.Outcome {
        let config = context.config
        let range = try DateRangeResolver.resolve(
            from: arguments["from"]?.stringValue,
            to: arguments["to"]?.stringValue,
            days: arguments["days"]?.intValue ?? 7,
            defaultFromNow: true,
            config: config,
            now: context.now
        )
        let minMinutes = max(5, arguments["min_minutes"]?.intValue ?? 30)
        let events = context.service.events(from: range.start, to: range.end).filter { !$0.isAllDay }
        let slots = context.planner.finder.freeSlots(
            busy: events.map { $0.interval },
            from: range.start,
            to: range.end,
            minMinutes: minMinutes
        )
        let payload = slots.map { slot -> JSONValue in
            .obj([
                "start": .string(Format.iso(slot.start, calendar: config.calendar)),
                "end": .string(Format.iso(slot.end, calendar: config.calendar)),
                "minutes": .number(Double(slot.minutes)),
                "weekday": .string(Format.weekday(slot.start, calendar: config.calendar)),
            ])
        }
        let result = JSONValue.obj([
            "timeZone": .string(config.timeZone),
            "availableHours": .string(config.availabilitySummary),
            "bufferMinutes": .number(Double(config.bufferMinutes)),
            "maxEventsPerDay": .number(Double(config.maxEventsPerDay)),
            "freeSlots": .array(payload),
        ])
        return Agent.Outcome(content: result.jsonString)
    }

    private static func calendarAnalysis(arguments: [String: JSONValue], context: Context) throws -> Agent.Outcome {
        let config = context.config
        // Analysis looks backwards: `lookback_days` counts back from now.
        let lookback = max(1, arguments["lookback_days"]?.intValue ?? arguments["days"]?.intValue ?? 30)
        let end: Date
        if let raw = arguments["to"]?.stringValue, !raw.isEmpty {
            end = try FlexibleDate.parse(raw, calendar: config.calendar, now: context.now)
        } else {
            end = context.now
        }
        let start: Date
        if let raw = arguments["from"]?.stringValue, !raw.isEmpty {
            start = try FlexibleDate.parse(raw, calendar: config.calendar, now: context.now)
        } else {
            start = config.calendar.date(byAdding: .day, value: -lookback, to: end) ?? end.addingTimeInterval(-Double(lookback) * 86_400)
        }
        guard end > start else {
            return Agent.Outcome(content: #"{"error": "the analysis window ends before it starts"}"#)
        }

        var ids: [String]? = nil
        if let name = arguments["calendar"]?.stringValue,
           let match = context.service.findCalendar(named: name) {
            ids = [match.calendarIdentifier]
        }

        let events = context.service.events(from: start, to: end, calendarIDs: ids)
        let analysis = CalendarAnalyzer.analyze(
            events: events,
            config: config,
            rangeStart: start,
            rangeEnd: end
        )
        guard let data = try? CalPilotJSON.encoder(pretty: false).encode(analysis),
              let json = String(data: data, encoding: .utf8)
        else {
            return Agent.Outcome(content: #"{"error": "could not encode the analysis"}"#)
        }
        return Agent.Outcome(content: json)
    }

    private static func listMemories(context: Context) -> Agent.Outcome {
        let payload = context.agent.memory.entries.map { entry -> JSONValue in
            .obj([
                "id": .string(entry.id),
                "text": .string(entry.text),
                "kind": .string(entry.kind.rawValue),
                "pinned": .bool(entry.pinned),
            ])
        }
        return Agent.Outcome(content: JSONValue.array(payload).jsonString)
    }

    // MARK: - Write tools

    private static func proposePlan(arguments: [String: JSONValue], context: Context) throws -> Agent.Outcome {
        let config = context.config
        let range = try DateRangeResolver.resolve(
            from: arguments["from"]?.stringValue,
            to: arguments["to"]?.stringValue,
            days: arguments["days"]?.intValue ?? 7,
            defaultFromNow: true,
            config: config,
            now: context.now
        )
        let goal = arguments["goal"]?.stringValue ?? "agent proposal"
        let request = PlanningRequest(goal: goal, rangeStart: range.start, rangeEnd: range.end)
        let planContext = context.planner.buildContext(request: request, now: context.now)

        // Reuse the same validation path as the one-shot planner: the model's times are
        // re-checked against the real calendar before the user ever sees the plan.
        let plan = try context.planner.makePlan(
            rawResponse: JSONValue.object(arguments).jsonString,
            request: request,
            context: planContext,
            source: "agent",
            now: context.now
        )
        context.agent.storePlan(plan)

        let summary = JSONValue.obj([
            "accepted": .number(Double(plan.items.count)),
            "unscheduled": .number(Double(plan.unscheduled.count)),
            "movedToAvoidConflicts": .number(Double(plan.items.filter { $0.adjustedFrom != nil }.count)),
            "displayedToUser": .bool(true),
        ])
        return Agent.Outcome(content: summary.jsonString)
    }

    private static func applyPlan(context: Context) throws -> Agent.Outcome {
        guard let plan = context.agent.pendingPlan else {
            return Agent.Outcome(content: #"{"error": "there is no proposal to apply; call propose_plan first"}"#)
        }
        guard !plan.items.isEmpty else {
            return Agent.Outcome(content: #"{"error": "the current proposal is empty"}"#)
        }
        let target = context.config.writeCalendar
        guard context.confirm("Write \(plan.items.count) event(s) into \"\(target)\"?") else {
            return Agent.Outcome(content: #"{"applied": false, "reason": "the user declined"}"#)
        }
        let created = try PlanApplier.apply(
            plan: plan,
            config: context.config,
            service: context.service,
            calendarName: nil,
            source: "agent"
        )
        context.agent.emitPlanApplied(created)
        let summary = JSONValue.obj([
            "applied": .bool(true),
            "created": .number(Double(created.count)),
            "calendar": .string(created.first?.calendarName ?? target),
        ])
        return Agent.Outcome(
            content: summary.jsonString,
            halt: true,
            spokenSummary: "已写入 \(created.count) 个事件到「\(created.first?.calendarName ?? target)」。用 `calpilot undo` 可以撤销。"
        )
    }

    private static func undoLastBatch(context: Context) throws -> Agent.Outcome {
        guard context.confirm("Remove the events from CalPilot's most recent batch?") else {
            return Agent.Outcome(content: #"{"removed": 0, "reason": "the user declined"}"#)
        }
        guard let result = try PlanApplier.undo(config: context.config, service: context.service) else {
            return Agent.Outcome(content: #"{"removed": 0, "reason": "there is nothing to undo"}"#)
        }
        let payload = JSONValue.obj([
            "removed": .number(Double(result.removed)),
            "attempted": .number(Double(result.attempted)),
            "batch": .string(result.batchID),
        ])
        return Agent.Outcome(
            content: payload.jsonString,
            halt: true,
            spokenSummary: "已撤销 \(result.removed) 个事件。"
        )
    }

    private static func remember(arguments: [String: JSONValue], context: Context) -> Agent.Outcome {
        guard let text = arguments["text"]?.stringValue, !text.isEmpty else {
            return Agent.Outcome(content: #"{"error": "text is required"}"#)
        }
        let kind = arguments["kind"]?.stringValue.flatMap(MemoryEntry.Kind.init(rawValue:)) ?? .preference
        let pinned = arguments["pinned"]?.boolValue ?? false
        guard let entry = context.agent.remember(text: text, kind: kind, pinned: pinned) else {
            return Agent.Outcome(content: #"{"error": "the memory was empty"}"#)
        }
        return Agent.Outcome(content: JSONValue.obj([
            "id": .string(entry.id),
            "text": .string(entry.text),
            "kind": .string(entry.kind.rawValue),
        ]).jsonString)
    }

    private static func forget(arguments: [String: JSONValue], context: Context) -> Agent.Outcome {
        guard let id = arguments["id"]?.stringValue else {
            return Agent.Outcome(content: #"{"error": "id is required"}"#)
        }
        guard let removed = context.agent.forget(idOrPrefix: id) else {
            return Agent.Outcome(content: JSONValue.obj(["removed": .bool(false)]).jsonString)
        }
        return Agent.Outcome(content: JSONValue.obj([
            "removed": .bool(true),
            "text": .string(removed.text),
        ]).jsonString)
    }

    // MARK: - Rendering helpers

    public static func summary(for name: String, arguments: [String: JSONValue]) -> String {
        switch name {
        case "list_events", "find_free_slots":
            let from = arguments["from"]?.stringValue ?? "now"
            let to = arguments["to"]?.stringValue ?? "+\(arguments["days"]?.intValue ?? 7)d"
            return "\(name)(\(from) → \(to))"
        case "calendar_analysis":
            let from = arguments["from"]?.stringValue
                ?? "last \(arguments["lookback_days"]?.intValue ?? 30)d"
            let to = arguments["to"]?.stringValue ?? "now"
            return "calendar_analysis(\(from) → \(to))"
        case "propose_plan":
            let count = arguments["events"]?.arrayValue?.count ?? 0
            return "propose_plan(\(count) event\(count == 1 ? "" : "s"))"
        case "remember":
            return "remember(\"\(arguments["text"]?.stringValue ?? "")\")"
        case "forget":
            return "forget(\(arguments["id"]?.stringValue ?? "?"))"
        default:
            return "\(name)()"
        }
    }

    public static func resultSummary(for name: String, content: String) -> String {
        guard let data = content.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return "\(content.prefix(120))" }
        switch name {
        case "list_events":
            let count = value["events"]?.arrayValue?.count ?? 0
            return "\(count) event(s)"
        case "calendar_analysis":
            let total = value["totalEvents"]?.intValue ?? 0
            let utilization = value["utilization"]?.numberValue ?? 0
            return "\(total) event(s) analysed, available hours \(Int((utilization * 100).rounded()))% booked"
        case "find_free_slots":
            let slots = value["freeSlots"]?.arrayValue ?? []
            let minutes = slots.compactMap { $0["minutes"]?.intValue }.reduce(0, +)
            return "\(slots.count) free slot(s), \(Format.duration(minutes: minutes)) total"
        case "propose_plan":
            let accepted = value["accepted"]?.intValue ?? 0
            let moved = value["movedToAvoidConflicts"]?.intValue ?? 0
            return "\(accepted) event(s) proposed" + (moved > 0 ? ", \(moved) moved to avoid a conflict" : "")
        case "apply_plan", "undo_last_batch":
            return value.jsonString
        case "remember":
            return "id \(value["id"]?.stringValue ?? "?")"
        default:
            return "ok"
        }
    }
}
