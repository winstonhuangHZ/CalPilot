import Foundation

/// Computes the hours you are willing to have something scheduled into, and the free gaps
/// inside them.
///
/// The window comes from `AppConfig.effectiveSchedule`, which supports several rules so a
/// weekday that runs late and a weekend that starts late are both expressible. Rules that
/// match the same day are unioned, and each rule's breaks are subtracted.
public struct SlotFinder {
    public let calendar: Calendar
    public let rules: [ScheduleRule]
    public let bufferMinutes: Int

    public init(config: AppConfig) {
        self.calendar = config.calendar
        self.rules = config.effectiveSchedule
        self.bufferMinutes = max(0, config.bufferMinutes)
    }

    // MARK: - Windows

    /// Every available window between two instants, clipped to the range.
    public func availableWindows(from start: Date, to end: Date) -> [DateInterval] {
        var windows: [DateInterval] = []
        var day = calendar.startOfDay(for: start)
        let lastDay = calendar.startOfDay(for: end)

        while day <= lastDay {
            for window in dayWindows(on: day) {
                let clippedStart = max(window.start, start)
                let clippedEnd = min(window.end, end)
                if clippedEnd > clippedStart {
                    windows.append(DateInterval(start: clippedStart, end: clippedEnd))
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return windows
    }

    /// The windows for one calendar day, with breaks removed.
    private func dayWindows(on day: Date) -> [DateInterval] {
        let weekday = calendar.component(.weekday, from: day)
        let matching = rules.filter { $0.days.isEmpty || $0.days.contains(weekday) }
        var windows: [DateInterval] = []

        for rule in matching {
            guard let start = instant(rule.start, on: day),
                  let end = instant(rule.end, on: day),
                  end > start
            else { continue }

            var pieces = [DateInterval(start: start, end: end)]
            for entry in rule.breaks {
                guard let range = Format.parseClockRange(entry),
                      let breakStart = instant(range.start, on: day),
                      let breakEnd = instant(range.end, on: day),
                      breakEnd > breakStart
                else { continue }
                pieces = pieces.flatMap { subtract($0, from: breakStart, to: breakEnd) }
            }
            windows.append(contentsOf: pieces)
        }

        // Union overlapping rules so a broad rule plus a narrow one cannot double-count.
        return Self.merge(windows)
    }

    private func instant(_ clock: (hour: Int, minute: Int), on day: Date) -> Date? {
        var comps = calendar.dateComponents([.year, .month, .day], from: day)
        comps.hour = clock.hour
        comps.minute = clock.minute
        comps.second = 0
        return calendar.date(from: comps)
    }

    private func instant(_ text: String, on day: Date) -> Date? {
        guard let clock = Format.parseClock(text) else { return nil }
        return instant(clock, on: day)
    }

    private func subtract(_ interval: DateInterval, from cutStart: Date, to cutEnd: Date) -> [DateInterval] {
        guard cutEnd > interval.start, cutStart < interval.end else { return [interval] }
        var pieces: [DateInterval] = []
        if cutStart > interval.start {
            pieces.append(DateInterval(start: interval.start, end: min(cutStart, interval.end)))
        }
        if cutEnd < interval.end {
            pieces.append(DateInterval(start: max(cutEnd, interval.start), end: interval.end))
        }
        return pieces.filter { $0.duration > 0 }
    }

    // MARK: - Free slots

    public func freeSlots(
        busy: [DateInterval],
        from start: Date,
        to end: Date,
        minMinutes: Int = 30
    ) -> [FreeSlot] {
        // Inflating the busy blocks by the buffer means the padding is only applied at
        // event boundaries, never against the edges of the day.
        let merged = Self.merge(Self.inflate(busy, by: TimeInterval(bufferMinutes * 60)))
        var slots: [FreeSlot] = []

        for window in availableWindows(from: start, to: end) {
            var cursor = window.start
            for block in merged where block.end > window.start && block.start < window.end {
                if block.start > cursor {
                    appendIfLongEnough(DateInterval(start: cursor, end: min(block.start, window.end)),
                                       minMinutes: minMinutes,
                                       into: &slots)
                }
                cursor = max(cursor, block.end)
                if cursor >= window.end { break }
            }
            if cursor < window.end {
                appendIfLongEnough(DateInterval(start: cursor, end: window.end),
                                   minMinutes: minMinutes,
                                   into: &slots)
            }
        }
        return slots
    }

    private func appendIfLongEnough(_ interval: DateInterval, minMinutes: Int, into slots: inout [FreeSlot]) {
        let minutes = Int(interval.duration / 60)
        guard minutes >= minMinutes else { return }
        slots.append(FreeSlot(start: interval.start, end: interval.end))
    }

    // MARK: - Snapping

    public struct SnapResult {
        public var start: Date
        public var end: Date
        public var moved: Bool
        public var note: String?
    }

    /// Finds a home for a desired booking: keeps the requested time when it fits,
    /// otherwise moves it to the nearest free slot on the same day, then the nearest slot
    /// on any other day inside the range.
    public func snap(
        desiredStart: Date,
        minutes: Int,
        busy: [DateInterval],
        rangeStart: Date,
        rangeEnd: Date
    ) -> SnapResult? {
        let duration = TimeInterval(minutes * 60)
        let requestedEnd = desiredStart.addingTimeInterval(duration)

        if fits(start: desiredStart, end: requestedEnd, busy: busy, rangeStart: rangeStart, rangeEnd: rangeEnd) {
            return SnapResult(start: desiredStart, end: requestedEnd, moved: false, note: nil)
        }

        let slots = freeSlots(busy: busy, from: rangeStart, to: rangeEnd, minMinutes: minutes)
        guard !slots.isEmpty else { return nil }

        // Prefer the same calendar day, then the nearest start time.
        let sameDay = slots.filter { calendar.isDate($0.start, inSameDayAs: desiredStart) }
        let candidates = sameDay.isEmpty ? slots : sameDay
        let chosen = candidates.min { lhs, rhs in
            abs(lhs.start.timeIntervalSince(desiredStart)) < abs(rhs.start.timeIntervalSince(desiredStart))
        } ?? slots[0]

        let start = chosen.start
        let end = start.addingTimeInterval(duration)
        let note = "moved from \(Format.human(desiredStart, calendar: calendar)) to keep the slot conflict-free"
        return SnapResult(start: start, end: end, moved: true, note: note)
    }

    public func fits(start: Date, end: Date, busy: [DateInterval], rangeStart: Date, rangeEnd: Date) -> Bool {
        guard end > start else { return false }
        guard start >= rangeStart, end <= rangeEnd else { return false }
        guard isInsideAvailableWindow(start: start, end: end) else { return false }
        let padded = Self.inflate(busy, by: TimeInterval(bufferMinutes * 60))
        for block in padded where block.start < end && block.end > start {
            return false
        }
        return true
    }

    public func isInsideAvailableWindow(start: Date, end: Date) -> Bool {
        let day = calendar.startOfDay(for: start)
        return dayWindows(on: day).contains { start >= $0.start && end <= $0.end }
    }

    // MARK: - Helpers

    public static func merge(_ intervals: [DateInterval]) -> [DateInterval] {
        let sorted = intervals.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        var merged: [DateInterval] = []
        for interval in sorted {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    public static func inflate(_ intervals: [DateInterval], by seconds: TimeInterval) -> [DateInterval] {
        guard seconds > 0 else { return intervals }
        return intervals.map {
            DateInterval(start: $0.start.addingTimeInterval(-seconds),
                         end: $0.end.addingTimeInterval(seconds))
        }
    }
}

public extension EventDTO {
    var interval: DateInterval { DateInterval(start: start, end: end) }
}
