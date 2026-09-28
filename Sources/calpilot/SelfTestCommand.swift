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
        let annotatedBreak = Format.parseClockRange("11:40-12:30（学校）")
        expect(annotatedBreak != nil && annotatedBreak!.end.0 == 12 && annotatedBreak!.end.1 == 30,
               "a lunch break with a note still parses (annotations are ignored)")
        let enDash = Format.parseClockRange("9:00 – 18:00")
        expect(enDash != nil && enDash!.start.0 == 9 && enDash!.start.1 == 0,
               "en dashes and spacing are tolerated")
        let tilde = Format.parseClockRange("07:40~21:00")
        expect(tilde != nil && tilde!.end.0 == 21, "a tilde separator is tolerated")
        expect(Format.parseClockRange("garbage") == nil, "a value with no times is rejected")
        var badConfig = config
        badConfig.lunchBreak = "吃完再说"
        expect(badConfig.schedulingWarnings.contains { $0.contains("休息") },
               "an unreadable lunch break is reported instead of silently dropped")
        badConfig.lunchBreak = "12:00-13:00"
        expect(badConfig.schedulingWarnings.isEmpty,
               "a readable config produces no warnings (got \(badConfig.schedulingWarnings))")

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
        expect(conflict.map { finder.isInsideAvailableWindow(start: $0.start, end: $0.end) } == true,
               "the moved request stays inside the available hours")

        Console.heading("Availability rules")
        expect(Format.describeDays([2, 3, 4, 5, 6]) == "周一–周五",
               "consecutive weekdays collapse (got \(Format.describeDays([2, 3, 4, 5, 6])))")
        expect(Format.describeDays([1, 7]) == "周六、周日",
               "a weekend is listed, not dashed (got \(Format.describeDays([1, 7])))")
        expect(Format.describeDays([6, 7, 1]) == "周五–周日",
               "a three-day run across the week boundary collapses (got \(Format.describeDays([6, 7, 1])))")
        expect(Format.describeDays([2, 4, 6]) == "周一、周三、周五",
               "scattered days are listed (got \(Format.describeDays([2, 4, 6])))")
        expect(Format.describeDays([1, 2, 3, 4, 5, 6, 7]) == "每天",
               "all seven days read as 每天")
        expect(AppConfig().usesLegacySchedule,
               "a config with no rules falls back to the legacy single window")
        expect(AppConfig().effectiveSchedule.count == 1, "the fallback produces exactly one rule")

        var schoolConfig = AppConfig()
        schoolConfig.timeZone = "Asia/Shanghai"
        schoolConfig.schedule = [
            ScheduleRule(days: [2, 3, 4, 5, 6], start: "07:40", end: "21:00",
                         breaks: ["11:40-12:30（学校）", "17:00-18:00"]),
            ScheduleRule(days: [1, 7], start: "10:00", end: "18:00"),
        ]
        let schoolFinder = SlotFinder(config: schoolConfig)
        let schoolMonday = try FlexibleDate.parse("2026-09-28 00:00", calendar: calendar, now: anchor)
        let schoolSaturday = try FlexibleDate.parse("2026-10-03 00:00", calendar: calendar, now: anchor)
        let mondayWindows = schoolFinder.availableWindows(from: schoolMonday, to: schoolMonday.addingTimeInterval(86_400))
        let saturdayWindows = schoolFinder.availableWindows(from: schoolSaturday, to: schoolSaturday.addingTimeInterval(86_400))
        expect(mondayWindows.count == 3,
               "two breaks split a school day into three windows (got \(mondayWindows.count))")
        expect(mondayWindows.first.map { Format.clock($0.start, calendar: calendar) } == "07:40"
                && mondayWindows.last.map { Format.clock($0.end, calendar: calendar) } == "21:00",
               "the weekday rule runs 07:40–21:00")
        expect(saturdayWindows.count == 1
                && Format.clock(saturdayWindows[0].start, calendar: calendar) == "10:00"
                && Format.clock(saturdayWindows[0].end, calendar: calendar) == "18:00",
               "the weekend rule takes over on Saturday")
        expect(schoolFinder.isInsideAvailableWindow(
            start: try FlexibleDate.parse("2026-09-28 20:00", calendar: calendar, now: anchor),
            end: try FlexibleDate.parse("2026-09-28 20:30", calendar: calendar, now: anchor)
        ), "an evening slot on a school day is available")
        expect(!schoolFinder.isInsideAvailableWindow(
            start: try FlexibleDate.parse("2026-10-03 09:00", calendar: calendar, now: anchor),
            end: try FlexibleDate.parse("2026-10-03 09:30", calendar: calendar, now: anchor)
        ), "Saturday before 10:00 is not available")
        expect(schoolConfig.availabilitySummary.contains("周一–周五 07:40–21:00"),
               "the summary describes the rules (got \(schoolConfig.availabilitySummary))")
        expect(schoolConfig.schedulingWarnings.isEmpty,
               "a well-formed schedule produces no warnings (got \(schoolConfig.schedulingWarnings))")

        var unionConfig = schoolConfig
        unionConfig.schedule = [
            ScheduleRule(days: [2, 3, 4, 5, 6], start: "09:00", end: "12:00"),
            ScheduleRule(days: [2], start: "18:00", end: "21:00"),
        ]
        let unionWindows = SlotFinder(config: unionConfig)
            .availableWindows(from: schoolMonday, to: schoolMonday.addingTimeInterval(86_400))
        expect(unionWindows.count == 2,
               "a Monday-only rule adds a second window instead of replacing the first (got \(unionWindows.count))")

        var brokenRule = AppConfig()
        brokenRule.schedule = [ScheduleRule(days: [2], start: "21:00", end: "08:00")]
        expect(brokenRule.schedulingWarnings.contains { $0.contains("结束时间") },
               "a rule that ends before it starts is reported instead of silently skipped")
        var legacyBreak = AppConfig()
        legacyBreak.lunchBreak = "吃完再说"
        expect(legacyBreak.schedulingWarnings.contains { $0.contains("午休") || $0.contains("休息") },
               "an unreadable break in the legacy fields is reported too")

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
        expect(plan.items.allSatisfy { planner.finder.isInsideAvailableWindow(start: $0.start, end: $0.end) },
               "every proposed event sits inside the available hours")
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

        Console.heading("Past-time analysis")
        func sample(_ title: String, _ from: String, _ to: String, into name: String = "工作") -> EventDTO {
            EventDTO(
                id: UUID().uuidString,
                title: title,
                start: (try? FlexibleDate.parse(from, calendar: calendar, now: anchor)) ?? anchor,
                end: (try? FlexibleDate.parse(to, calendar: calendar, now: anchor)) ?? anchor,
                calendarID: name,
                calendarName: name
            )
        }
        // Two days of history, plus one event deliberately straddling the window start.
        let synthetic = [
            sample("周会", "2026-09-21 09:00", "2026-09-21 11:00"),
            sample("写论文", "2026-09-21 13:00", "2026-09-21 17:00", into: "个人"),
            sample("面试", "2026-09-22 10:00", "2026-09-22 11:00"),
            sample("跨窗口", "2026-09-20 23:00", "2026-09-21 00:30"),
        ]
        let analysisRange = try Runtime.resolveRange(
            from: "2026-09-21 00:00", to: "2026-09-23 00:00", days: 2,
            defaultStartFromNow: false, config: config
        )
        let analysis = CalendarAnalyzer.analyze(
            events: synthetic,
            config: config,
            rangeStart: analysisRange.start,
            rangeEnd: analysisRange.end
        )
        // 2h + 4h + 1h, plus only the 30 in-window minutes of the straddling event.
        expect(abs(analysis.totalHours - 7.5) < 0.001,
               "hours are summed and clipped to the window (got \(analysis.totalHours))")
        // 个人 holds the 4h block; 工作 holds 2h + 1h + the 30 clipped minutes.
        expect(analysis.byCalendar.first?.calendarName == "个人",
               "the busiest calendar sorts first (got \(analysis.byCalendar.first?.calendarName ?? "none"))")
        expect(abs(analysis.byCalendar.map { $0.share }.reduce(0, +) - 1) < 0.001,
               "calendar shares add up to 100%")
        expect(analysis.byWeekday.count == 2 && analysis.byWeekday.first?.weekday == "Mon",
               "weekdays are reported in order (got \(analysis.byWeekday.map { $0.weekday }))")
        expect(abs((analysis.byWeekday.first?.averageHours ?? 0) - 6.5) < 0.001,
               "Monday averages 6.5h (got \(analysis.byWeekday.first?.averageHours ?? -1))")
        expect(analysis.busiestDays.first?.hours == 6.5,
               "the busiest day is Monday (got \(analysis.busiestDays.first?.hours ?? -1))")
        // Monday is fully booked either side of lunch; Tuesday afternoon is free.
        expect(analysis.longestFocusBlockMinutes == 300,
               "the longest free block is found across the whole window (got \(analysis.longestFocusBlockMinutes))")
        expect(analysis.utilization > 0 && analysis.utilization < 1,
               "utilisation lands strictly between 0 and 1 (got \(analysis.utilization))")
        expect(!analysis.summaryLines.isEmpty, "the analysis renders summary lines")

        Console.heading("Conversation persistence")
        var stored = ChatSession(title: "写周报", turns: [
            ChatTurn(kind: .user, text: "帮我安排这周", at: anchor),
            ChatTurn(kind: .assistant, text: "好的", at: anchor),
        ])
        stored.agent.messages = [.system("stable"), .user("hi"), .assistant("hello")]
        stored.agent.pendingPlan = plan
        stored.agent.lastUserTurnAt = anchor

        let roundTripped = try CalPilotJSON.decoder().decode(
            ChatSession.self,
            from: CalPilotJSON.encoder(pretty: false).encode(stored)
        )
        expect(roundTripped.id == stored.id, "a session survives a JSON round trip")
        expect(roundTripped.turns.count == 2, "the visible turns survive")
        expect(roundTripped.agent.messages.count == 3, "the model transcript survives")
        expect(roundTripped.agent.messages.first?.content == "stable", "the system message survives")
        expect(roundTripped.agent.pendingPlan?.items.count == plan.items.count, "a pending proposal survives")
        expect(roundTripped.agent.lastUserTurnAt == anchor, "the last turn timestamp survives")
        expect(ChatSession.suggestedTitle(from: stored.turns) == "帮我安排这周",
               "the title comes from the first user turn")
        expect(ChatSession.suggestedTitle(from: [ChatTurn(kind: .user, text: String(repeating: "长", count: 60))], limit: 10)
                .hasSuffix("…"),
               "a long title is truncated with an ellipsis")

        // Exercises the real disk path and removes exactly what it wrote.
        let diskProbe = ChatSession(title: "selftest-probe", turns: [ChatTurn(kind: .notice, text: "probe")])
        try SessionStore.save(diskProbe)
        expect(SessionStore.load(id: diskProbe.id)?.title == "selftest-probe",
               "a session is written to and read back from disk")
        expect(SessionStore.list().contains { $0.id == diskProbe.id }, "saved sessions appear in the list")
        try SessionStore.delete(id: diskProbe.id)
        expect(SessionStore.load(id: diskProbe.id) == nil, "a deleted session is gone")

        Console.heading("Resuming a conversation")
        let resumeClient = ScriptedClient(script: [])
        let exported = stored.agent
        expect(exported.messages.count == 3, "an exported state keeps every message")
        expect(exported.pendingPlan?.items.count == plan.items.count, "an exported state keeps the proposal")

        // A memory added between sessions must reach the resumed conversation.
        var grownMemory = MemoryStore()
        grownMemory.add(text: "新加的偏好", kind: .preference)
        let resumed = Agent(
            config: config,
            service: CalendarService(),
            client: resumeClient,
            memory: grownMemory,
            confirm: { _ in false },
            now: { anchor },
            emit: { _ in }
        )
        resumed.restore(exported)
        expect(resumed.systemPrompt().contains("新加的偏好"),
               "a resumed session picks up memories added since it was saved")
        expect(exported.messages.first?.content != resumed.systemPrompt(),
               "the system prompt from disk is not reused verbatim")
        expect(resumed.transcript.count == 3, "the restored transcript is in place")
        let resumedTurn = resumed.formattedUserTurn("继续", at: anchor.addingTimeInterval(7_200))
        expect(resumedTurn.contains("2h since your previous message"),
               "a resumed session still knows when the last turn was (got \(resumedTurn.split(separator: "\n").first ?? ""))")

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
