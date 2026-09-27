import Foundation

public enum DateParseError: Error, CustomStringConvertible {
    case unrecognized(String)

    public var description: String {
        switch self {
        case let .unrecognized(raw):
            return """
            Could not understand the date "\(raw)".
            Accepted examples: 2026-09-28, 2026-09-28 09:30, 09:30, today 09:30, tomorrow 14:00, \
            明天 09:00, 周一 10:00, mon 10:00, +2d, +3h, +45m, now.
            """
        }
    }
}

/// Lenient, human-friendly date parsing in the configured time zone.
public enum FlexibleDate {
    private static let weekdayAliases: [String: Int] = [
        // Calendar weekday: 1 = Sunday ... 7 = Saturday
        "sun": 1, "sunday": 1, "周日": 1, "周天": 1, "星期日": 1, "星期天": 1, "礼拜日": 1,
        "mon": 2, "monday": 2, "周一": 2, "星期一": 2, "礼拜一": 2,
        "tue": 3, "tues": 3, "tuesday": 3, "周二": 3, "星期二": 3, "礼拜二": 3,
        "wed": 4, "wednesday": 4, "周三": 4, "星期三": 4, "礼拜三": 4,
        "thu": 5, "thur": 5, "thurs": 5, "thursday": 5, "周四": 5, "星期四": 5, "礼拜四": 5,
        "fri": 6, "friday": 6, "周五": 6, "星期五": 6, "礼拜五": 6,
        "sat": 7, "saturday": 7, "周六": 7, "星期六": 7, "礼拜六": 7,
    ]

    private static let dayOffsets: [String: Int] = [
        "today": 0, "今天": 0, "本日": 0,
        "tomorrow": 1, "tmr": 1, "明天": 1, "明日": 1,
        "后天": 2, "後天": 2,
        "yesterday": -1, "昨天": -1, "昨日": -1,
        "前天": -2,
    ]

    public static func parse(_ raw: String, calendar: Calendar, now: Date = Date()) throws -> Date {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw DateParseError.unrecognized(raw) }
        let lower = input.lowercased()

        if lower == "now" || lower == "现在" { return now }

        // Relative offsets: +3h, -2d, +45m, +1w
        if lower.hasPrefix("+") || lower.hasPrefix("-") {
            if let date = parseRelative(lower, now: now) { return date }
        }

        // Absolute formats with an explicit offset or `Z` win outright.
        if let date = absoluteISO(input) { return date }

        // Split an optional day expression from an optional time expression.
        let (dayPart, timePart) = splitDayAndTime(input)
        guard let time = timePart else {
            // Day only -> midnight of that day.
            if let day = resolveDay(dayPart, calendar: calendar, now: now) { return day }
            throw DateParseError.unrecognized(raw)
        }
        let (hour, minute) = time

        if let dayBase = resolveDay(dayPart, calendar: calendar, now: now) {
            return combine(day: dayBase, hour: hour, minute: minute, calendar: calendar)
        }
        // Bare "09:30" -> today at that time.
        if dayPart.isEmpty {
            return combine(day: now, hour: hour, minute: minute, calendar: calendar)
        }
        throw DateParseError.unrecognized(raw)
    }

    // MARK: - Pieces

    private static func absoluteISO(_ input: String) -> Date? {
        let hasOffset = input.contains("Z") || input.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil
        guard input.contains("T") || hasOffset else { return nil }
        guard hasOffset else { return nil }
        return CalPilotJSON.parseISODate(input)
    }

    private static func parseRelative(_ input: String, now: Date) -> Date? {
        let pattern = #"^([+-])(\d+)([wdhm])$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              match.numberOfRanges == 4,
              let signRange = Range(match.range(at: 1), in: input),
              let valueRange = Range(match.range(at: 2), in: input),
              let unitRange = Range(match.range(at: 3), in: input),
              let value = Double(input[valueRange])
        else { return nil }
        let sign = input[signRange] == "-" ? -1.0 : 1.0
        let unit = String(input[unitRange])
        let seconds: Double
        switch unit {
        case "w": seconds = 604_800
        case "d": seconds = 86_400
        case "h": seconds = 3_600
        default: seconds = 60
        }
        return now.addingTimeInterval(sign * value * seconds)
    }

    /// Returns (dayExpression, (hour, minute)).
    private static func splitDayAndTime(_ input: String) -> (String, (Int, Int)?) {
        // "2026-09-28 09:30" / "2026-09-28T09:30"
        let patterns = [
            #"^(\d{4}-\d{2}-\d{2})[T\s](\d{1,2}):(\d{2})(?::\d{2})?$"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
               match.numberOfRanges == 4,
               let d = Range(match.range(at: 1), in: input),
               let h = Range(match.range(at: 2), in: input),
               let m = Range(match.range(at: 3), in: input),
               let hour = Int(input[h]), let minute = Int(input[m]) {
                return (String(input[d]), (hour, minute))
            }
        }

        // "<day words> 09:30" or "09:30 <day words>"
        let timeToken = #"(\d{1,2}):(\d{2})(?::\d{2})?"#
        let trailingTime = #"^(.*?)[\s，,]*\#(timeToken)$"#
        let leadingTime = #"^\#(timeToken)[\s，,]+(.*)$"#
        if let regex = try? NSRegularExpression(pattern: trailingTime),
           let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
           match.numberOfRanges == 4,
           let day = Range(match.range(at: 1), in: input),
           let h = Range(match.range(at: 2), in: input),
           let m = Range(match.range(at: 3), in: input),
           let hour = Int(input[h]), let minute = Int(input[m]) {
            return (String(input[day]).trimmingCharacters(in: .whitespaces), (hour, minute))
        }
        if let regex = try? NSRegularExpression(pattern: leadingTime),
           let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
           match.numberOfRanges == 4,
           let h = Range(match.range(at: 1), in: input),
           let m = Range(match.range(at: 2), in: input),
           let day = Range(match.range(at: 3), in: input),
           let hour = Int(input[h]), let minute = Int(input[m]) {
            return (String(input[day]).trimmingCharacters(in: .whitespaces), (hour, minute))
        }

        // Pure time.
        if let regex = try? NSRegularExpression(pattern: #"^(\d{1,2}):(\d{2})(?::\d{2})?$"#),
           let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
           match.numberOfRanges == 3,
           let h = Range(match.range(at: 1), in: input),
           let m = Range(match.range(at: 2), in: input),
           let hour = Int(input[h]), let minute = Int(input[m]) {
            return ("", (hour, minute))
        }

        return (input, nil)
    }

    private static func resolveDay(_ expression: String, calendar: Calendar, now: Date) -> Date? {
        let token = expression.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if token.isEmpty { return nil }

        if let offset = dayOffsets[token] {
            return calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))
        }

        // "9/28", "2026/9/28", "2026-9-28"
        if let date = parseNumericDay(token, calendar: calendar) { return date }

        // Weekday name -> next occurrence (today counts).
        if let weekday = weekdayAliases[token] {
            return nextOccurrence(of: weekday, after: now, calendar: calendar)
        }

        // "next monday", "下周一"
        if token.hasPrefix("next ") {
            let rest = String(token.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if let weekday = weekdayAliases[rest] {
                let base = nextOccurrence(of: weekday, after: now, calendar: calendar)
                if calendar.isDate(base, inSameDayAs: now) {
                    return calendar.date(byAdding: .weekOfYear, value: 1, to: base)
                }
                return base
            }
        }
        if token.hasPrefix("下") {
            let rest = String(token.dropFirst()).trimmingCharacters(in: .whitespaces)
            let stripped = rest.replacingOccurrences(of: "周", with: "周")
            if let weekday = weekdayAliases[stripped] ?? weekdayAliases["周" + stripped] {
                let base = nextOccurrence(of: weekday, after: now, calendar: calendar)
                if calendar.isDate(base, inSameDayAs: now) {
                    return calendar.date(byAdding: .weekOfYear, value: 1, to: base)
                }
                return base
            }
        }

        return nil
    }

    private static func parseNumericDay(_ token: String, calendar: Calendar) -> Date? {
        let separators = CharacterSet(charactersIn: "-/.")
        let parts = token.components(separatedBy: separators).filter { !$0.isEmpty }
        guard parts.count == 2 || parts.count == 3, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        let year = calendar.component(.year, from: Date())
        var comps = DateComponents()
        if parts.count == 3 {
            comps.year = Int(parts[0])
            comps.month = Int(parts[1])
            comps.day = Int(parts[2])
        } else {
            comps.year = year
            comps.month = Int(parts[0])
            comps.day = Int(parts[1])
        }
        comps.hour = 0
        comps.minute = 0
        return calendar.date(from: comps)
    }

    private static func nextOccurrence(of weekday: Int, after date: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        let current = calendar.component(.weekday, from: start)
        var delta = weekday - current
        if delta < 0 { delta += 7 }
        return calendar.date(byAdding: .day, value: delta, to: start) ?? start
    }

    private static func combine(day: Date, hour: Int, minute: Int, calendar: Calendar) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: day)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return calendar.date(from: comps) ?? day
    }
}

// MARK: - Formatting helpers

public enum Format {
    public static func iso(_ date: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return f.string(from: date)
    }

    public static func day(_ date: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    public static func human(_ date: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }

    public static func clock(_ date: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    public static func weekday(_ date: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "EEE"
        return f.string(from: date)
    }

    /// "1h 30m" style duration.
    public static func duration(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// Compact elapsed time, used to tell the model how stale a conversation is.
    public static func elapsed(since earlier: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(earlier))
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 {
            let hours = Int(seconds / 3_600)
            let minutes = Int(seconds.truncatingRemainder(dividingBy: 3_600) / 60)
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
        let days = Int(seconds / 86_400)
        return days == 1 ? "1 day" : "\(days) days"
    }

    /// Parses "09:00" or "9:00-18:00".
    public static func parseClockRange(_ raw: String) -> (start: (Int, Int), end: (Int, Int))? {
        let parts = raw.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        func parse(_ s: String) -> (Int, Int)? {
            let hm = s.split(separator: ":")
            guard hm.count == 2, let h = Int(hm[0]), let m = Int(hm[1]) else { return nil }
            return (h, m)
        }
        guard let a = parse(parts[0]), let b = parse(parts[1]) else { return nil }
        return (a, b)
    }
}
