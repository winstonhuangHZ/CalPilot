import ArgumentParser
import CalPilotCore
import Foundation

/// Exercises the scheduling engine without touching the calendar or the network.
struct SelfTestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "selftest",
        abstract: "Run the built-in checks for date parsing, slot finding, and plan validation."
    )

    func run() async throws {
        var checks = 0
        var failures: [String] = []

        func expect(_ condition: Bool, _ label: String) {
            checks += 1
            if condition {
                print("  \(Console.green("ok"))   \(label)")
            } else {
                print("  \(Console.red("FAIL")) \(label)")
                failures.append(label)
            }
        }

        var config = AppConfig()
        config.timeZone = "Asia/Shanghai"
        let calendar = config.calendar
        let anchor = FlexibleDateTestHelper.anchor(calendar: calendar)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        func iso(_ date: Date) -> String { formatter.string(from: date) }

        Console.heading("Date parsing")
        let cases: [(String, String)] = [
            ("2026-09-28 09:30", "2026-09-28T01:30:00Z"),
            ("2026-09-28T09:30", "2026-09-28T01:30:00Z"),
            ("今天 09:00", "2026-09-27T01:00:00Z"),
            ("明天 09:00", "2026-09-28T01:00:00Z"),
            ("后天 14:00", "2026-09-29T06:00:00Z"),
            ("+2d", "2026-09-29T02:00:00Z"),
            ("2026-09-28T09:30:00+08:00", "2026-09-28T01:30:00Z"),
        ]
        for (input, expected) in cases {
            do {
                let parsed = try FlexibleDate.parse(input, calendar: calendar, now: anchor)
                let actual = iso(parsed)
                expect(actual == expected, "\(input) -> \(actual)\(actual == expected ? "" : " (expected \(expected))")")
            } catch {
                expect(false, "\(input) -> threw \(error)")
            }
        }

        Console.heading("Free slot calculation")
        let day = try FlexibleDate.parse("2026-09-28 00:00", calendar: calendar, now: anchor)
        let rangeEnd = calendar.date(byAdding: .day, value: 1, to: day)!
        let busy = [
            DateInterval(start: try FlexibleDate.parse("2026-09-28 10:00", calendar: calendar, now: anchor),
                         end: try FlexibleDate.parse("2026-09-28 11:00", calendar: calendar, now: anchor)),
            DateInterval(start: try FlexibleDate.parse("2026-09-28 15:00", calendar: calendar, now: anchor),
                         end: try FlexibleDate.parse("2026-09-28 15:30", calendar: calendar, now: anchor)),
        ]
        let finder = SlotFinder(config: config)
        let slots = finder.freeSlots(busy: busy, from: day, to: rangeEnd, minMinutes: 30)
        let starts = slots.map { Format.clock($0.start, calendar: calendar) }
        expect(slots.count == 4, "lunch plus two busy blocks leave 4 slots (got \(slots.count))")
        expect(starts == ["09:00", "11:10", "13:00", "15:40"],
               "slots respect the 10 minute buffer, starting at 09:00, 11:10, 13:00, 15:40 (got \(starts))")
        expect(slots.first?.minutes == 50, "the first slot is 50 minutes (got \(slots.first?.minutes ?? -1))")

        let conflict = finder.snap(
            desiredStart: try FlexibleDate.parse("2026-09-28 10:30", calendar: calendar, now: anchor),
            minutes: 45,
            busy: busy,
            rangeStart: day,
            rangeEnd: rangeEnd
        )
        expect(conflict?.moved == true, "a conflicting request gets moved")
        expect(conflict.map { finder.isInsideWorkingWindow(start: $0.start, end: $0.end) } == true,
               "the moved request stays inside working hours")

        Console.heading("Plan validation")
        let context = Planner.Context(
            now: anchor,
            rangeStart: day,
            rangeEnd: rangeEnd,
            busy: [
                BusyBlock(start: busy[0].start, end: busy[0].end, title: "standup", calendarName: "Work"),
            ],
            allDay: [],
            ownEvents: [],
            freeSlots: slots
        )
        let request = PlanningRequest(
            goal: "test",
            rangeStart: day,
            rangeEnd: rangeEnd,
            tasks: [PlannedTask(title: "写周报", minutes: 60)]
        )
        let cannedReply = """
        ```json
        {
          "summary": "放两个任务",
          "events": [
            {"title": "写周报", "start": "2026-09-28T10:30:00+08:00", "end": "2026-09-28T11:30:00+08:00", "reason": "早上状态好"},
            {"title": "健身", "start": "2026-09-28T16:00:00+08:00", "durationMinutes": 90, "reason": "下午"},
            {"title": "没有时间", "start": "2026-09-28T23:00:00+08:00", "end": "2026-09-28T23:30:00+08:00"}
          ],
          "unscheduled": []
        }
        ```
        """
        let planner = Planner(config: config, service: CalendarService())
        let plan = try planner.makePlan(
            rawResponse: cannedReply,
            request: request,
            context: context,
            source: "selftest",
            now: anchor
        )
        expect(plan.items.count == 3, "all three events were placed (got \(plan.items.count))")
        Console.table(
            headers: ["Placed", "Time", "Len", "From"],
            rows: plan.items.map { item in
                [
                    item.title,
                    "\(Format.clock(item.start, calendar: calendar))-\(Format.clock(item.end, calendar: calendar))",
                    Format.duration(minutes: item.minutes),
                    item.adjustedFrom.map { Format.clock($0, calendar: calendar) } ?? "as requested",
                ]
            }
        )
        expect(plan.items.allSatisfy { item in
            context.busy.allSatisfy { block in
                !(item.start < block.end && block.start < item.end)
            }
        }, "no proposed event overlaps an existing one")
        expect(plan.unscheduled.isEmpty, "nothing had to be dropped (got \(plan.unscheduled.map { $0.title }))")
        expect(plan.items.allSatisfy { planner.finder.isInsideWorkingWindow(start: $0.start, end: $0.end) },
               "every proposed event sits inside working hours")
        expect(plan.items.contains { $0.title == "写周报" && $0.adjustedFrom != nil },
               "the conflicting 写周报 entry was relocated instead of written on top of the standup")
        expect(plan.items.contains { $0.title == "没有时间" && $0.adjustedFrom != nil },
               "the out-of-hours entry was relocated into a working slot")

        Console.heading("JSON extraction")
        expect(JSONExtraction.firstObject(in: "sure! {\"a\":1} done") == "{\"a\":1}", "prose around the JSON is ignored")
        expect(JSONExtraction.firstObject(in: #"{"a":"}"}"#) == #"{"a":"}"}"#, "braces inside strings do not terminate early")

        Console.heading("Personal memory block")
        var memory = MemoryStore()
        memory.add(text: "上午做深度工作，不要安排会议", kind: .preference)
        memory.add(text: "周三晚上不排事情", kind: .constraint, pinned: true)
        let duplicate = memory.add(text: "上午做深度工作，不要安排会议")
        expect(memory.entries.count == 2, "duplicates are not stored twice (got \(memory.entries.count))")
        expect(duplicate?.id == memory.entries.first?.id, "adding a duplicate returns the existing entry")
        let block = memory.promptBlock()
        expect(block.contains("上午做深度工作"), "the prompt block contains the preference")
        expect(block.contains("pinned"), "pinned memories are tagged in the prompt block")
        expect(block.contains("[constraint, pinned]"), "the memory kind and pin state are both shown (got \(block.split(separator: "\n").last ?? ""))")
        expect(memory.promptEntries(limit: 1).first?.pinned == true, "pinned entries come first even when the budget is 1")
        expect(memory.remove(idOrPrefix: "zzzz") == nil, "removing an unknown id returns nil")
        let removedID = memory.entries.first?.id ?? ""
        expect(memory.remove(idOrPrefix: String(removedID.prefix(4))) != nil, "a unique id prefix is enough to delete")
        expect(memory.entries.count == 1, "remove actually deletes (got \(memory.entries.count))")
        expect(MemoryStore().promptBlock().isEmpty, "an empty memory block contributes no prompt text")

        Console.heading("Prompt-cache stability")
        let schema = JSONValue.object(["zeta": .number(1), "alpha": .number(2), "mid": .object(["b": .number(1), "a": .number(2)])])
        expect(schema.jsonString == #"{"alpha":2,"mid":{"a":2,"b":1},"zeta":1}"#,
               "JSON keys are emitted in a stable sorted order (got \(schema.jsonString))")
        let firstEncoding = try CalPilotJSON.encodeToString(ToolCatalog.definitions, pretty: false)
        let secondEncoding = try CalPilotJSON.encodeToString(ToolCatalog.definitions, pretty: false)
        expect(firstEncoding == secondEncoding, "the tool schema encodes to identical bytes every time")
        expect(firstEncoding.contains(#""parameters":{"properties""#), "the schema survives encoding intact")

        let agent = Agent(
            config: config,
            service: CalendarService(),
            client: LLMClient(config: config, apiKey: "selftest"),
            memory: memory,
            confirm: { _ in false },
            now: { anchor },
            emit: { _ in }
        )
        let promptAtAnchor = agent.systemPrompt()
        expect(!promptAtAnchor.contains("2026-09-27"), "the system prompt carries no volatile clock data")
        expect(promptAtAnchor.contains("上午做深度工作") || promptAtAnchor.contains("周三晚上不排事情"),
               "memories reach the system prompt")
        let turnLine = agent.formattedUserTurn("帮我安排这周", at: anchor)
        expect(turnLine.contains("time: 2026-09-27 10:00:00 +08:00"), "user turns carry a timestamp in the configured zone (got \(turnLine.split(separator: "\n").first ?? ""))")
        expect(turnLine.contains("weekday: Sun"), "user turns carry the weekday")
        expect(turnLine.contains("帮我安排这周"), "the user's text is preserved verbatim")
        expect(!turnLine.contains("since your previous message"), "the first turn has no previous turn to compare against")
        let laterTurn = agent.formattedUserTurn("再改一下", at: anchor.addingTimeInterval(3_900), previousTurnAt: anchor)
        expect(laterTurn.contains("1h 5m since your previous message"),
               "later turns report the elapsed time (got \(laterTurn.split(separator: "\n").first ?? ""))")

        Console.heading("Agent tool surface")
        let toolNames = ToolCatalog.definitions.map { $0.function.name }
        expect(toolNames.contains("propose_plan") && toolNames.contains("apply_plan"),
               "the agent can propose and apply plans")
        expect(toolNames.contains("remember") && toolNames.contains("forget"),
               "the agent can maintain the memory block")
        expect(ToolCatalog.definitions.allSatisfy { $0.function.parameters["type"]?.stringValue == "object" },
               "every tool declares an object schema")

        Console.heading("Turn-based agent loop")
        let scripted = ScriptedClient(script: [
            .init(content: nil, toolCalls: [
                SelfTestCommand.toolCall("find_free_slots", ["days": .number(7)]),
            ], finishReason: "tool_calls"),
            .init(content: nil, toolCalls: [
                SelfTestCommand.toolCall("propose_plan", [
                    "goal": .string("安排这周"),
                    "days": .number(7),
                    "summary": .string("早上一小时写周报"),
                    "events": .array([
                        .obj([
                            "title": .string("写周报"),
                            "start": .string("2026-09-28T09:00:00+08:00"),
                            "end": .string("2026-09-28T10:00:00+08:00"),
                            "reason": .string("早上精力好"),
                        ]),
                    ]),
                ]),
            ], finishReason: "tool_calls"),
            .init(content: nil, toolCalls: [
                SelfTestCommand.toolCall("answer", ["text": .string("计划好了，要写入吗？")]),
            ], finishReason: "tool_calls"),
        ])

        var observed: [String] = []
        let loopAgent = Agent(
            config: config,
            service: CalendarService(),
            client: scripted,
            memory: MemoryStore(),
            confirm: { _ in false },
            now: { anchor },
            emit: { event in
                switch event {
                case let .toolCall(name, _): observed.append("call:\(name)")
                case let .planProposed(plan): observed.append("plan:\(plan.items.count)")
                case let .assistantText(text): observed.append("say:\(text)")
                default: break
                }
            }
        )
        try await loopAgent.send("帮我安排这周")

        expect(observed.contains("call:find_free_slots"), "the agent inspected the calendar before proposing (got \(observed))")
        expect(observed.contains("plan:1"), "the proposal reached the renderer with one accepted event")
        expect(observed.contains("say:计划好了，要写入吗？"), "the closing answer is spoken to the user")
        expect(loopAgent.pendingPlan != nil, "the proposal is kept for a later apply")
        expect(loopAgent.transcript.first?.role == "system", "the transcript always opens with the system prompt")
        expect(scripted.seenMessages.count == 3, "the loop ran three model turns (got \(scripted.seenMessages.count))")
        let fedBackTools = scripted.seenMessages[2].filter { $0.role == "tool" }.compactMap { $0.name }
        expect(fedBackTools == ["find_free_slots", "propose_plan"],
               "tool results are fed back in order (got \(fedBackTools))")
        let firstUser = loopAgent.transcript.first { $0.role == "user" }?.content ?? ""
        expect(firstUser.contains("time: 2026-09-27 10:00:00 +08:00") && firstUser.contains("帮我安排这周"),
               "the model sees the user's timestamp and their text")

        Console.heading("Result")
        if failures.isEmpty {
            Console.success("\(checks) checks passed")
        } else {
            Console.error("\(failures.count) of \(checks) checks failed")
            throw ExitCode(ExitCodes.failure)
        }
    }

    static func toolCall(_ name: String, _ arguments: [String: JSONValue]) -> LLMClient.ToolCall {
        LLMClient.ToolCall(
            id: "call-\(name)-\(UUID().uuidString.prefix(4))",
            function: .init(name: name, arguments: JSONValue.object(arguments).jsonString)
        )
    }
}

/// A stand-in for the network client: replays a fixed script of tool calls so the
/// whole turn loop can be verified offline.
private final class ScriptedClient: LLMChatClient {
    var modelName: String { "scripted" }
    private var script: [LLMClient.Completion]
    private(set) var seenMessages: [[LLMClient.Message]] = []

    init(script: [LLMClient.Completion]) {
        self.script = script
    }

    func complete(
        messages: [LLMClient.Message],
        tools: [LLMClient.ToolDefinition],
        options: LLMClient.Options
    ) async throws -> LLMClient.Completion {
        seenMessages.append(messages)
        guard !script.isEmpty else {
            return LLMClient.Completion(content: "done", toolCalls: [])
        }
        return script.removeFirst()
    }
}

private enum FlexibleDateTestHelper {
    /// 2026-09-27 10:00 in Asia/Shanghai.
    static func anchor(calendar: Calendar) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 9
        comps.day = 27
        comps.hour = 10
        comps.minute = 0
        comps.second = 0
        return calendar.date(from: comps) ?? Date()
    }
}
