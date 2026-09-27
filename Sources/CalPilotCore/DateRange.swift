import Foundation

public enum DateRangeResolver {
    /// Resolves a `from`/`to` pair with a `days` fallback, in the configured time zone.
    public static func resolve(
        from fromRaw: String?,
        to toRaw: String?,
        days: Int,
        defaultFromNow: Bool,
        config: AppConfig,
        now: Date = Date()
    ) throws -> (start: Date, end: Date) {
        let calendar = config.calendar
        let start: Date
        if let fromRaw, !fromRaw.isEmpty {
            start = try FlexibleDate.parse(fromRaw, calendar: calendar, now: now)
        } else if defaultFromNow {
            start = now
        } else {
            start = calendar.startOfDay(for: now)
        }

        let end: Date
        if let toRaw, !toRaw.isEmpty {
            end = try FlexibleDate.parse(toRaw, calendar: calendar, now: now)
        } else {
            end = calendar.date(byAdding: .day, value: max(1, days), to: start)
                ?? start.addingTimeInterval(Double(max(1, days)) * 86_400)
        }

        guard end > start else {
            throw DateParseError.unrecognized("range end \(toRaw ?? "") must be after \(fromRaw ?? "")")
        }
        return (start, end)
    }
}
