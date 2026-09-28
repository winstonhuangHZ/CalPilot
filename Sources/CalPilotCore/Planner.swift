import Foundation

/// A task the user explicitly wants scheduled.
public struct PlannedTask: Codable, Hashable {
    public var title: String
    public var minutes: Int
    public var priority: String?

    public init(title: String, minutes: Int, priority: String? = nil) {
        self.title = title
        self.minutes = minutes
        self.priority = priority
    }

    /// Parses `"写周报:90"`, `"写周报 90"`, `"写周报:90:high"`, `"写周报"`.
    public static func parse(_ raw: String, defaultMinutes: Int) -> PlannedTask? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 1 {
            // "title 90" form
            if let space = trimmed.lastIndex(of: " "), let minutes = Int(trimmed[trimmed.index(after: space)...]) {
                return PlannedTask(title: String(trimmed[..<space]), minutes: minutes)
            }
            return PlannedTask(title: trimmed, minutes: defaultMinutes)
        }
        let title = parts[0]
        guard !title.isEmpty else { return nil }
        var minutes = defaultMinutes
        var priority: String?
        if parts.count >= 2, let value = Int(parts[1]) {
            minutes = value
        } else if parts.count >= 2, !parts[1].isEmpty {
            priority = parts[1]
        }
        if parts.count >= 3, !parts[2].isEmpty {
            priority = parts[2]
        }
        return PlannedTask(title: title, minutes: max(5, minutes), priority: priority)
    }
}

public struct PlanningRequest {
    public var goal: String
    public var rangeStart: Date
    public var rangeEnd: Date
    public var preferences: String?
    public var tasks: [PlannedTask]
    public var busyCalendarIDs: [String]?
    /// Calendars whose events may be moved/removed by the model (CalPilot's own by default).
    public var allowReplacingCalPilotEvents: Bool

    public init(
        goal: String,
        rangeStart: Date,
        rangeEnd: Date,
        preferences: String? = nil,
        tasks: [PlannedTask] = [],
        busyCalendarIDs: [String]? = nil,
        allowReplacingCalPilotEvents: Bool = true
    ) {
        self.goal = goal
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.preferences = preferences
        self.tasks = tasks
        self.busyCalendarIDs = busyCalendarIDs
        self.allowReplacingCalPilotEvents = allowReplacingCalPilotEvents
    }
}

/// The scheduling engine: gathers calendar state, asks the model for a plan,
/// then validates everything locally so a hallucinated slot can never be written.
public struct Planner {
    public let config: AppConfig
    public let service: CalendarService
    public let finder: SlotFinder
    /// Personal memory injected into the system prompt.
    public var memory: MemoryStore

    public init(config: AppConfig, service: CalendarService, memory: MemoryStore = MemoryStore()) {
        self.config = config
        self.service = service
        self.memory = memory
        self.finder = SlotFinder(config: config)
    }

    // MARK: - Context

    public struct Context {
        public var now: Date
        public var rangeStart: Date
        public var rangeEnd: Date
        public var busy: [BusyBlock]
        public var allDay: [EventDTO]
        public var ownEvents: [EventDTO]
        public var freeSlots: [FreeSlot]

        public init(
            now: Date,
            rangeStart: Date,
            rangeEnd: Date,
            busy: [BusyBlock],
            allDay: [EventDTO],
            ownEvents: [EventDTO],
            freeSlots: [FreeSlot]
        ) {
            self.now = now
            self.rangeStart = rangeStart
            self.rangeEnd = rangeEnd
            self.busy = busy
            self.allDay = allDay
            self.ownEvents = ownEvents
            self.freeSlots = freeSlots
        }

        public var busyIntervals: [DateInterval] {
            busy.map { DateInterval(start: $0.start, end: $0.end) }
        }
    }

    public func buildContext(request: PlanningRequest, now: Date = Date()) -> Context {
        let events = service.events(from: request.rangeStart, to: request.rangeEnd, calendarIDs: request.busyCalendarIDs)
        let timed = events.filter { !$0.isAllDay }
        let allDayEvents = events.filter { $0.isAllDay }

        let busy = timed.map { BusyBlock(start: $0.start, end: $0.end, title: $0.title, calendarName: $0.calendarName) }
        let own = request.allowReplacingCalPilotEvents ? events.filter { $0.createdByCalPilot } : []

        // CalPilot's own bookings are treated as movable, so they do not block planning.
        let movableIDs = Set(own.map { $0.id })
        let blocking = timed
            .filter { !movableIDs.contains($0.id) }
            .map { DateInterval(start: $0.start, end: $0.end) }

        let slots = finder.freeSlots(
            busy: blocking,
            from: request.rangeStart,
            to: request.rangeEnd,
            minMinutes: 30
        )

        return Context(
            now: now,
            rangeStart: request.rangeStart,
            rangeEnd: request.rangeEnd,
            busy: busy,
            allDay: allDayEvents,
            ownEvents: own,
            freeSlots: slots
        )
    }

    // MARK: - Prompt

    public func systemPrompt() -> String {
        let memoryBlock = memory.promptBlock()
        return """
        You are CalPilot, a meticulous personal scheduling engine for a macOS calendar.

        You receive a request together with the user's real calendar state and a list of \
        available free slots. You return a concrete placement plan as strict JSON.

        Hard rules:
        1. Every proposed event must lie entirely inside one of the provided free slots.
        2. Never overlap two proposed events, and never touch an existing busy block.
        3. Respect the available hours, buffer minutes, and the per-day event cap.
        4. Respect the requested duration for each task; never shorten a task below its request.
        5. Prefer the earliest suitable slot unless the preferences or the task's nature argue otherwise.
        6. Leave reasoning short: one sentence per event in "reason".
        7. If a task genuinely cannot fit, list it under "unscheduled" with a one-line reason \
        instead of forcing it in.
        8. Write event titles and the summary in the same language as the user's goal text.
        9. Output JSON only. No markdown fences, no commentary.

        Output schema:
        {
          "summary": "one short paragraph describing the overall shape of the week",
          "events": [
            {
              "title": "string",
              "start": "ISO-8601 local time with UTC offset",
              "end": "ISO-8601 local time with UTC offset",
              "location": "optional string",
              "notes": "optional string",
              "reason": "why this slot"
            }
          ],
          "unscheduled": [
            { "title": "string", "reason": "string", "suggestedMinutes": 30 }
          ]
        }
        \(memoryBlock.isEmpty ? "" : "\n" + memoryBlock + "\n")
        """
    }

    public func userPrompt(request: PlanningRequest, context: Context) -> String {
        var lines: [String] = []
        lines.append("## Request")
        lines.append("Goal: \(request.goal)")
        if let preferences = request.preferences, !preferences.isEmpty {
            lines.append("Additional preferences: \(preferences)")
        }
        if !config.extraInstructions.isEmpty {
            lines.append("Standing instructions from config: \(config.extraInstructions)")
        }
        lines.append("")

        lines.append("## Clock")
        lines.append("Now: \(Format.iso(context.now, calendar: config.calendar))")
        lines.append("Time zone: \(config.timeZone)")
        lines.append("Planning window: \(Format.iso(request.rangeStart, calendar: config.calendar)) → \(Format.iso(request.rangeEnd, calendar: config.calendar))")
        lines.append("Available hours: \(config.availabilitySummary)")
        lines.append("Buffer between events: \(config.bufferMinutes) minutes")
        lines.append("The free slots below already have that buffer applied, so use them as-is.")
        lines.append("Maximum new events per day: \(config.maxEventsPerDay)")
        lines.append("Default task length when unspecified: \(config.defaultEventMinutes) minutes")
        lines.append("")

        if !request.tasks.isEmpty {
            lines.append("## Tasks to schedule")
            for task in request.tasks {
                let priority = task.priority.map { " [priority: \($0)]" } ?? ""
                lines.append("- \(task.title) — \(Format.duration(minutes: task.minutes))\(priority)")
            }
            lines.append("")
        }

        lines.append("## Existing events (immovable)")
        if context.busy.isEmpty {
            lines.append("- none")
        } else {
            for block in context.busy where !block.title.isEmpty {
                let own = context.ownEvents.contains { $0.start == block.start && $0.title == block.title }
                let tag = own ? " (already booked by CalPilot — you may move or replace it)" : ""
                lines.append("- \(Format.iso(block.start, calendar: config.calendar)) → \(Format.iso(block.end, calendar: config.calendar)) | \(block.title) [\(block.calendarName)]\(tag)")
            }
        }
        lines.append("")

        if !context.allDay.isEmpty {
            lines.append("## All-day entries (context only, they do not block slots)")
            for event in context.allDay {
                lines.append("- \(Format.day(event.start, calendar: config.calendar)) | \(event.title)")
            }
            lines.append("")
        }

        lines.append("## Available free slots")
        if context.freeSlots.isEmpty {
            lines.append("- none — everything planned must go under \"unscheduled\"")
        } else {
            for slot in context.freeSlots {
                lines.append("- \(Format.iso(slot.start, calendar: config.calendar)) → \(Format.iso(slot.end, calendar: config.calendar)) (\(Format.duration(minutes: slot.minutes)), \(Format.weekday(slot.start, calendar: config.calendar)))")
            }
        }
        lines.append("")
        lines.append("Return the JSON plan now.")
        return lines.joined(separator: "\n")
    }

    // MARK: - LLM plan

    public func planWithLLM(request: PlanningRequest, client: LLMClient, now: Date = Date()) async throws -> Plan {
        let context = buildContext(request: request, now: now)
        let messages = [
            LLMClient.Message.system(systemPrompt()),
            LLMClient.Message.user(userPrompt(request: request, context: context)),
        ]
        let raw = try await client.chat(messages: messages, options: .init(temperature: 0.2))
        return try makePlan(rawResponse: raw, request: request, context: context, source: "llm:\(client.model)", now: now)
    }

    /// Deterministic earliest-fit scheduling, used by `--offline` and as a fallback shape.
    public func planHeuristically(request: PlanningRequest, now: Date = Date()) -> Plan {
        let context = buildContext(request: request, now: now)
        var accepted: [PlanItem] = []
        var unscheduled: [UnscheduledItem] = []
        var perDay: [Date: Int] = [:]

        for task in request.tasks {
            let interval = DateInterval(start: request.rangeStart, end: request.rangeEnd)
            let blocking = context.busyIntervals + accepted.map { DateInterval(start: $0.start, end: $0.end) }
            let slots = finder.freeSlots(busy: blocking, from: interval.start, to: interval.end, minMinutes: task.minutes)
            let candidate = slots.first { slot in
                let day = config.calendar.startOfDay(for: slot.start)
                return (perDay[day] ?? 0) < config.maxEventsPerDay
            }
            guard let slot = candidate else {
                unscheduled.append(UnscheduledItem(title: task.title, reason: "no free slot long enough in the planning window", suggestedMinutes: task.minutes))
                continue
            }
            let end = slot.start.addingTimeInterval(Double(task.minutes * 60))
            perDay[config.calendar.startOfDay(for: slot.start), default: 0] += 1
            accepted.append(PlanItem(title: task.title, start: slot.start, end: end, reason: "earliest free slot that fits"))
        }

        accepted.sort { $0.start < $1.start }
        return Plan(
            timeZone: config.timeZone,
            model: "heuristic (offline)",
            goal: request.goal,
            rangeStart: request.rangeStart,
            rangeEnd: request.rangeEnd,
            summary: accepted.isEmpty
                ? "No tasks were placed; see unscheduled."
                : "Placed \(accepted.count) task(s) as early as possible inside the available free slots.",
            items: accepted,
            unscheduled: unscheduled,
            warnings: []
        )
    }

    // MARK: - Validation

    /// Turns a raw model reply into a validated plan. Anything that does not fit is
    /// moved to a legal slot or reported, never written blindly.
    public func makePlan(
        rawResponse: String,
        request: PlanningRequest,
        context: Context,
        source: String,
        now: Date = Date()
    ) throws -> Plan {
        guard let json = JSONExtraction.firstObject(in: rawResponse) else {
            throw LLMClient.LLMError.decoding("no JSON object found in the reply")
        }
        guard let data = json.data(using: .utf8) else {
            throw LLMClient.LLMError.decoding("reply was not valid UTF-8")
        }
        let draft: PlanDraft
        do {
            draft = try JSONDecoder().decode(PlanDraft.self, from: data)
        } catch {
            throw LLMClient.LLMError.decoding("\(error.localizedDescription) — raw reply: \(json.prefix(400))")
        }

        var warnings: [String] = []
        var accepted: [PlanItem] = []
        var unscheduled: [UnscheduledItem] = (draft.unscheduled ?? []).map {
            UnscheduledItem(title: $0.title, reason: $0.reason ?? "not scheduled", suggestedMinutes: $0.suggestedMinutes)
        }
        var perDay: [Date: Int] = [:]

        // Existing CalPilot bookings are being replaced by this plan, so they do not block.
        let blocking = context.busy.filter { block in
            !context.ownEvents.contains { $0.start == block.start && $0.title == block.title }
        }.map { DateInterval(start: $0.start, end: $0.end) }

        for raw in draft.events ?? [] {
            let title = raw.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                warnings.append("skipped an event with no title")
                continue
            }
            guard let start = raw.resolvedStart(calendar: config.calendar, now: now) else {
                warnings.append("skipped \"\(title)\": unparsable start time \(raw.start ?? "nil")")
                continue
            }
            var minutes = raw.resolvedMinutes(calendar: config.calendar, start: start) ?? config.defaultEventMinutes
            if minutes < 5 {
                warnings.append("\"\(title)\" was shorter than 5 minutes; extended to 5.")
                minutes = 5
            }
            if minutes > 8 * 60 {
                warnings.append("\"\(title)\" exceeded 8 hours; truncated to 8 hours.")
                minutes = 8 * 60
            }

            let busy = blocking + accepted.map { DateInterval(start: $0.start, end: $0.end) }
            guard let snap = finder.snap(
                desiredStart: start,
                minutes: minutes,
                busy: busy,
                rangeStart: request.rangeStart,
                rangeEnd: request.rangeEnd
            ) else {
                unscheduled.append(UnscheduledItem(title: title, reason: "no free slot long enough inside the planning window", suggestedMinutes: minutes))
                continue
            }

            let day = config.calendar.startOfDay(for: snap.start)
            let dayCount = perDay[day] ?? 0
            if dayCount >= config.maxEventsPerDay {
                // Try the next slot on another day before giving up.
                let alternatives = finder.freeSlots(
                    busy: busy,
                    from: request.rangeStart,
                    to: request.rangeEnd,
                    minMinutes: minutes
                ).filter { slot in
                    let slotDay = config.calendar.startOfDay(for: slot.start)
                    return slotDay != day && (perDay[slotDay] ?? 0) < config.maxEventsPerDay
                }
                guard let alternative = alternatives.first else {
                    unscheduled.append(UnscheduledItem(title: title, reason: "daily cap of \(config.maxEventsPerDay) events reached", suggestedMinutes: minutes))
                    continue
                }
                let end = alternative.start.addingTimeInterval(Double(minutes * 60))
                perDay[config.calendar.startOfDay(for: alternative.start), default: 0] += 1
                accepted.append(PlanItem(
                    title: title,
                    start: alternative.start,
                    end: end,
                    location: raw.location,
                    notes: raw.notes,
                    reason: raw.reason,
                    adjustedFrom: start,
                    adjustmentNote: "moved to respect the \(config.maxEventsPerDay)-events-per-day cap"
                ))
                continue
            }

            perDay[day, default: 0] += 1
            accepted.append(PlanItem(
                title: title,
                start: snap.start,
                end: snap.end,
                location: raw.location,
                notes: raw.notes,
                reason: raw.reason,
                adjustedFrom: snap.moved ? start : nil,
                adjustmentNote: snap.note
            ))
        }

        // De-duplicate identical placements.
        var seen = Set<String>()
        accepted = accepted.filter { item in
            let key = "\(item.title)|\(item.start.timeIntervalSince1970)"
            return seen.insert(key).inserted
        }.sorted { $0.start < $1.start }

        return Plan(
            timeZone: config.timeZone,
            model: source,
            goal: request.goal,
            rangeStart: request.rangeStart,
            rangeEnd: request.rangeEnd,
            summary: draft.summary ?? "",
            items: accepted,
            unscheduled: unscheduled,
            warnings: warnings
        )
    }

    // MARK: - Draft decoding

    private struct PlanDraft: Decodable {
        var summary: String?
        var events: [DraftEvent]?
        var unscheduled: [DraftUnscheduled]?
    }

    private struct DraftUnscheduled: Decodable {
        var title: String
        var reason: String?
        var suggestedMinutes: Int?

        enum CodingKeys: String, CodingKey {
            case title, reason, suggestedMinutes, suggested_minutes, minutes
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = (try? c.decode(String.self, forKey: .title)) ?? "untitled"
            reason = try? c.decodeIfPresent(String.self, forKey: .reason)
            var minutes: Int? = try? c.decodeIfPresent(Int.self, forKey: .suggestedMinutes)
            if minutes == nil { minutes = try? c.decodeIfPresent(Int.self, forKey: .suggested_minutes) }
            if minutes == nil { minutes = try? c.decodeIfPresent(Int.self, forKey: .minutes) }
            suggestedMinutes = minutes
        }
    }

    private struct DraftEvent: Decodable {
        var title: String
        var start: String?
        var end: String?
        var durationMinutes: Int?
        var location: String?
        var notes: String?
        var reason: String?

        enum CodingKeys: String, CodingKey {
            case title, start, end, location, notes, reason
            case durationMinutes, duration_minutes, duration, minutes
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = (try? c.decode(String.self, forKey: .title)) ?? "untitled"
            start = try? c.decodeIfPresent(String.self, forKey: .start)
            end = try? c.decodeIfPresent(String.self, forKey: .end)
            location = try? c.decodeIfPresent(String.self, forKey: .location)
            notes = try? c.decodeIfPresent(String.self, forKey: .notes)
            reason = try? c.decodeIfPresent(String.self, forKey: .reason)
            var duration: Int? = try? c.decodeIfPresent(Int.self, forKey: .durationMinutes)
            if duration == nil { duration = try? c.decodeIfPresent(Int.self, forKey: .duration_minutes) }
            if duration == nil { duration = try? c.decodeIfPresent(Int.self, forKey: .duration) }
            if duration == nil { duration = try? c.decodeIfPresent(Int.self, forKey: .minutes) }
            durationMinutes = duration
        }

        func resolvedStart(calendar: Calendar, now: Date) -> Date? {
            guard let start else { return nil }
            if let date = try? FlexibleDate.parse(start, calendar: calendar, now: now) { return date }
            if let date = CalPilotJSON.parseISODate(start) { return date }
            // Last resort: the literal string may be a bare number of minutes from now.
            if let minutes = Int(start) { return now.addingTimeInterval(Double(minutes * 60)) }
            return nil
        }

        func resolvedMinutes(calendar: Calendar, start: Date) -> Int? {
            if let durationMinutes, durationMinutes > 0 { return durationMinutes }
            guard let end else { return nil }
            let parsedEnd = (try? FlexibleDate.parse(end, calendar: calendar, now: start))
                ?? CalPilotJSON.parseISODate(end)
            guard let parsedEnd else { return nil }
            let minutes = Int(parsedEnd.timeIntervalSince(start) / 60)
            return minutes > 0 ? minutes : nil
        }
    }
}
