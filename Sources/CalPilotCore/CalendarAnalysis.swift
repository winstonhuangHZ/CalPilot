import Foundation

/// A deterministic read of how time was actually spent over a range.
///
/// Computed in code rather than asked of the model: the numbers stay exact, cost no
/// tokens, and work with no API key. The model can request the same structure through the
/// `calendar_analysis` tool, so its prose rests on real arithmetic.
public struct CalendarAnalysis: Codable {
    public struct CalendarShare: Codable, Hashable {
        public var calendarName: String
        public var hours: Double
        public var eventCount: Int
        public var share: Double
    }

    public struct DayStat: Codable, Hashable {
        public var date: Date
        public var weekday: String
        public var hours: Double
        public var eventCount: Int
    }

    public struct WeekdayStat: Codable, Hashable {
        public var weekday: String
        public var averageHours: Double
        public var totalHours: Double
        public var days: Int
    }

    public struct TitleStat: Codable, Hashable {
        public var title: String
        public var count: Int
        public var hours: Double
    }

    public var rangeStart: Date
    public var rangeEnd: Date
    public var timeZone: String
    public var days: Int

    public var totalEvents: Int
    public var timedEvents: Int
    public var allDayEvents: Int
    public var recurringEvents: Int
    public var totalHours: Double
    public var averageEventMinutes: Int
    public var medianEventMinutes: Int

    public var byCalendar: [CalendarShare]
    public var byWeekday: [WeekdayStat]
    public var busiestDays: [DayStat]
    public var mostCommonTitles: [TitleStat]

    /// Booked time inside the configured available hours, versus what was available.
    public var availableHours: Double
    public var bookedHours: Double
    public var utilization: Double
    public var longestFocusBlockMinutes: Int
    public var averageFocusBlockMinutes: Int
    /// Days that are inside your schedule but carry no fixed commitments.
    public var daysWithNoCommitments: Int

    public var notes: [String]

    /// Compact lines for a sidebar or a terminal header.
    public var summaryLines: [String] {
        var lines: [String] = []
        lines.append("\(days) 天里 \(totalEvents) 个日程，共 \(Format.hours(totalHours))")
        if availableHours > 0 {
            lines.append("可安排时段占用 \(Int((utilization * 100).rounded()))%"
                + "（\(Format.hours(bookedHours)) / \(Format.hours(availableHours))）")
        }
        lines.append("最长连续空档 \(Format.duration(minutes: longestFocusBlockMinutes))，平均 \(Format.duration(minutes: averageFocusBlockMinutes))")
        if let top = byCalendar.first {
            lines.append("最占时间：\(top.calendarName) \(Int((top.share * 100).rounded()))%")
        }
        if !byWeekday.isEmpty, let heaviest = byWeekday.max(by: { $0.averageHours < $1.averageHours }) {
            lines.append("最忙的是周\(heaviest.weekday)，平均 \(Format.hours(heaviest.averageHours))")
        }
        return lines
    }
}

public enum CalendarAnalyzer {
    public static func analyze(
        events: [EventDTO],
        config: AppConfig,
        rangeStart: Date,
        rangeEnd: Date
    ) -> CalendarAnalysis {
        let calendar = config.calendar
        let timed = events.filter { !$0.isAllDay }.sorted { $0.start < $1.start }

        // Clip to the range so a long event straddling the boundary is not over-counted.
        func clipped(_ event: EventDTO) -> DateInterval? {
            let start = max(event.start, rangeStart)
            let end = min(event.end, rangeEnd)
            guard end > start else { return nil }
            return DateInterval(start: start, end: end)
        }

        var hoursByCalendar: [String: (hours: Double, count: Int)] = [:]
        var hoursByDay: [Date: (hours: Double, count: Int)] = [:]
        var titleStats: [String: (count: Int, minutes: Double)] = [:]
        var totalSeconds: Double = 0
        var durations: [Int] = []

        for event in timed {
            guard let interval = clipped(event) else { continue }
            let hours = interval.duration / 3_600
            totalSeconds += interval.duration

            let existing = hoursByCalendar[event.calendarName] ?? (0, 0)
            hoursByCalendar[event.calendarName] = (existing.hours + hours, existing.count + 1)

            // Attribute to the day the *clipped* interval starts on, not the day the event
            // starts on. Otherwise an event straddling the window edge contributes to the
            // total but lands on a day outside the report, and the per-day figures stop
            // adding up to the headline number.
            let day = calendar.startOfDay(for: interval.start)
            let dayExisting = hoursByDay[day] ?? (0, 0)
            hoursByDay[day] = (dayExisting.hours + hours, dayExisting.count + 1)

            let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                let stat = titleStats[title] ?? (0, 0)
                titleStats[title] = (stat.count + 1, stat.minutes + interval.duration / 60)
            }
            durations.append(Int(interval.duration / 60))
        }

        let totalHours = totalSeconds / 3_600

        let byCalendar: [CalendarAnalysis.CalendarShare] = hoursByCalendar
            .map { name, value in
                CalendarAnalysis.CalendarShare(
                    calendarName: name,
                    hours: value.hours,
                    eventCount: value.count,
                    share: totalHours > 0 ? value.hours / totalHours : 0
                )
            }
            .sorted { $0.hours > $1.hours }

        let dayStats: [CalendarAnalysis.DayStat] = hoursByDay
            .map { day, value in
                CalendarAnalysis.DayStat(
                    date: day,
                    weekday: Format.weekday(day, calendar: calendar),
                    hours: value.hours,
                    eventCount: value.count
                )
            }
            .sorted { $0.hours > $1.hours }

        // Average hours per weekday, over the days actually covered by the range.
        var weekdayAccumulator: [String: (hours: Double, days: Int)] = [:]
        var cursor = calendar.startOfDay(for: rangeStart)
        while cursor < rangeEnd {
            let name = Format.weekday(cursor, calendar: calendar)
            let hours = hoursByDay[cursor]?.hours ?? 0
            let existing = weekdayAccumulator[name] ?? (0, 0)
            weekdayAccumulator[name] = (existing.hours + hours, existing.days + 1)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        let weekdayOrder = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let byWeekday: [CalendarAnalysis.WeekdayStat] = weekdayAccumulator
            .map { name, value in
                CalendarAnalysis.WeekdayStat(
                    weekday: name,
                    averageHours: value.days > 0 ? value.hours / Double(value.days) : 0,
                    totalHours: value.hours,
                    days: value.days
                )
            }
            .sorted { lhs, rhs in
                let li = weekdayOrder.firstIndex(of: lhs.weekday) ?? 99
                let ri = weekdayOrder.firstIndex(of: rhs.weekday) ?? 99
                return li < ri
            }

        // Working-hour utilisation and focus fragmentation.
        var rawFinder = config
        rawFinder.bufferMinutes = 0
        let finder = SlotFinder(config: rawFinder)
        let windows = finder.availableWindows(from: rangeStart, to: rangeEnd)
        let available = windows.reduce(0) { $0 + $1.duration } / 3_600

        var bookedSeconds: Double = 0
        for window in windows {
            for event in timed {
                guard let interval = clipped(event) else { continue }
                let overlap = min(window.end, interval.end).timeIntervalSince(max(window.start, interval.start))
                if overlap > 0 { bookedSeconds += overlap }
            }
        }
        let booked = bookedSeconds / 3_600

        let focusSlots = finder.freeSlots(
            busy: timed.compactMap { clipped($0) },
            from: rangeStart,
            to: rangeEnd,
            minMinutes: 15
        )
        let focusMinutes = focusSlots.map { $0.minutes }
        let longestFocus = focusMinutes.max() ?? 0
        let averageFocus = focusMinutes.isEmpty ? 0 : focusMinutes.reduce(0, +) / focusMinutes.count

        let workdays = Set(windows.map { calendar.startOfDay(for: $0.start) })
        let daysWithEvents = Set(timed.map { calendar.startOfDay(for: $0.start) })
        let quietWorkdays = workdays.subtracting(daysWithEvents).count

        let totalDays = max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: rangeStart),
                                                       to: calendar.startOfDay(for: rangeEnd)).day ?? 0)

        var notes: [String] = []
        if timed.isEmpty {
            notes.append("这段时间没有任何有固定时间的日程。")
        } else {
            if totalHours > 0, let top = byCalendar.first, top.share > 0.5 {
                notes.append("超过一半的日程时间都记在「\(top.calendarName)」里。")
            }
            if available > 0, booked / available > 0.6 {
                notes.append("可安排时段占用超过 60%，几乎没有留白。")
            }
            if timed.count >= 5, averageFocus < 60 {
                notes.append("平均连续空档不到 1 小时，时间被打得很碎。")
            }
            if quietWorkdays > 0 {
                notes.append("有 \(quietWorkdays) 天完全没有固定日程。")
            }
        }

        return CalendarAnalysis(
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            timeZone: config.timeZone,
            days: totalDays,
            totalEvents: events.count,
            timedEvents: timed.count,
            allDayEvents: events.count - timed.count,
            recurringEvents: events.filter { $0.isRecurring }.count,
            totalHours: totalHours,
            averageEventMinutes: durations.isEmpty ? 0 : durations.reduce(0, +) / durations.count,
            medianEventMinutes: median(durations),
            byCalendar: byCalendar,
            byWeekday: byWeekday,
            busiestDays: Array(dayStats.prefix(5)),
            mostCommonTitles: titleStats
                .map { CalendarAnalysis.TitleStat(title: $0.key, count: $0.value.count, hours: $0.value.minutes / 60) }
                .sorted { $0.count > $1.count }
                .prefix(8)
                .map { $0 },
            availableHours: available,
            bookedHours: booked,
            utilization: available > 0 ? booked / available : 0,
            longestFocusBlockMinutes: longestFocus,
            averageFocusBlockMinutes: averageFocus,
            daysWithNoCommitments: quietWorkdays,
            notes: notes
        )
    }

    private static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
