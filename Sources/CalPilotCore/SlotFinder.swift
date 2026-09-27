import Foundation

/// Computes working windows and free slots, and snaps desired times into gaps.
public struct SlotFinder {
    public let calendar: Calendar
    public let workDays: Set<Int>
    public let dayStart: (hour: Int, minute: Int)
    public let dayEnd: (hour: Int, minute: Int)
    public let lunch: (start: (hour: Int, minute: Int), end: (hour: Int, minute: Int))?
    public let bufferMinutes: Int

    public init(config: AppConfig) {
        self.calendar = config.calendar
        self.workDays = Set(config.workDays)
        let range = Format.parseClockRange("\(config.workDayStart)-\(config.workDayEnd)")
        self.dayStart = range?.start ?? (9, 0)
        self.dayEnd = range?.end ?? (18, 0)
        if let lunchRaw = config.lunchBreak, let parsed = Format.parseClockRange(lunchRaw) {
            self.lunch = (parsed.start, parsed.end)
        } else {
            self.lunch = nil
        }
        self.bufferMinutes = max(0, config.bufferMinutes)
    }

    // MARK: - Windows

    /// All working windows (work hours minus lunch) between two instants.
    public func workingWindows(from start: Date, to end: Date) -> [DateInterval] {
        var windows: [DateInterval] = []
        var day = calendar.startOfDay(for: start)
        let lastDay = calendar.startOfDay(for: end)

        while day <= lastDay {
            let weekday = calendar.component(.weekday, from: day)
            if workDays.isEmpty || workDays.contains(weekday) {
                for window in dayWindows(on: day) {
                    let clippedStart = max(window.start, start)
                    let clippedEnd = min(window.end, end)
                    if clippedEnd > clippedStart {
                        windows.append(DateInterval(start: clippedStart, end: clippedEnd))
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return windows
    }

    private func dayWindows(on day: Date) -> [DateInterval] {
        func instant(_ hm: (hour: Int, minute: Int)) -> Date? {
            var comps = calendar.dateComponents([.year, .month, .day], from: day)
            comps.hour = hm.hour
            comps.minute = hm.minute
            comps.second = 0
            return calendar.date(from: comps)
        }
        guard let start = instant(dayStart), let end = instant(dayEnd), end > start else { return [] }
        guard let lunch, let lunchStart = instant(lunch.start), let lunchEnd = instant(lunch.end),
              lunchEnd > lunchStart, lunchStart > start, lunchEnd < end
        else {
            return [DateInterval(start: start, end: end)]
        }
        return [
            DateInterval(start: start, end: lunchStart),
            DateInterval(start: lunchEnd, end: end),
        ]
    }

    // MARK: - Free slots

    public func freeSlots(
        busy: [DateInterval],
        from start: Date,
        to end: Date,
        minMinutes: Int = 30
    ) -> [FreeSlot] {
        // Inflating the busy blocks by the buffer means the padding is only applied at
        // event boundaries, never against the edges of the working day.
        let merged = Self.merge(Self.inflate(busy, by: TimeInterval(bufferMinutes * 60)))
        let windows = workingWindows(from: start, to: end)
        var slots: [FreeSlot] = []

        for window in windows {
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
    /// otherwise moves it to the nearest free slot on the same day, then the next
    /// available day inside the range.
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
        guard isInsideWorkingWindow(start: start, end: end) else { return false }
        let padded = Self.inflate(busy, by: TimeInterval(bufferMinutes * 60))
        for block in padded where block.start < end && block.end > start {
            return false
        }
        return true
    }

    public func isInsideWorkingWindow(start: Date, end: Date) -> Bool {
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
