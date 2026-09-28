import ArgumentParser
import CalPilotCore
import Foundation

/// Manages when CalPilot is allowed to put things.
///
/// A single weekday window plus a lunch break is a work model. School, shift work, and
/// most real weeks need several rules — weekdays that run late, weekends that start later,
/// more than one fixed break.
struct ScheduleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schedule",
        abstract: "Manage the hours CalPilot may schedule into.",
        discussion: """
        Rules are unioned: if two rules both cover Monday, both windows are available.
        Breaks inside a rule are subtracted. Without any rules, CalPilot falls back to the
        legacy workDayStart/workDayEnd/lunchBreak fields.
        """,
        subcommands: [
            ScheduleShowCommand.self,
            ScheduleAddCommand.self,
            ScheduleRemoveCommand.self,
            SchedulePresetCommand.self,
            ScheduleClearCommand.self,
        ],
        defaultSubcommand: ScheduleShowCommand.self
    )
}

/// Weekday names only — deliberately no bare numbers, because "1" means Monday to most
/// people and Sunday to `Calendar`, and that ambiguity is not worth the keystrokes saved.
enum WeekdayParser {
    static let aliases: [String: Int] = [
        "mon": 2, "monday": 2, "周一": 2, "星期一": 2, "礼拜一": 2,
        "tue": 3, "tues": 3, "tuesday": 3, "周二": 3, "星期二": 3, "礼拜二": 3,
        "wed": 4, "wednesday": 4, "周三": 4, "星期三": 4, "礼拜三": 4,
        "thu": 5, "thur": 5, "thurs": 5, "thursday": 5, "周四": 5, "星期四": 5, "礼拜四": 5,
        "fri": 6, "friday": 6, "周五": 6, "星期五": 6, "礼拜五": 6,
        "sat": 7, "saturday": 7, "周六": 7, "星期六": 7, "礼拜六": 7,
        "sun": 1, "sunday": 1, "周日": 1, "周天": 1, "星期日": 1, "星期天": 1, "礼拜日": 1,
    ]

    static let everyDay = ["daily", "everyday", "every", "每天", "全部", "all"]

    /// Parses `mon,tue,wed` or `周一、周三` or `每天`. Returns nil when nothing matched.
    static func parse(_ raw: String) -> [Int]? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.isEmpty { return nil }
        if everyDay.contains(trimmed) { return [] }

        let tokens = trimmed
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "、", with: ",")
            .replacingOccurrences(of: " ", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var days: [Int] = []
        for token in tokens {
            guard let day = aliases[token] else { return nil }
            days.append(day)
        }
        return days.isEmpty ? nil : Array(Set(days)).sorted()
    }
}

struct ScheduleShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show the current availability rules.")

    func run() async throws {
        let config = try Runtime.loadConfig()
        let rules = config.effectiveSchedule
        Console.heading("可安排时段")
        Console.table(
            headers: ["#", "星期", "起", "止", "休息"],
            rows: rules.enumerated().map { index, rule in
                [String(index), rule.dayDescription, rule.start, rule.end, rule.breaks.joined(separator: "、")]
            }
        )
        if config.usesLegacySchedule {
            Console.note("  来源：workDayStart / workDayEnd / lunchBreak（旧的单时段字段）")
            Console.note("  想要按星期分别设置，用 `calpilot schedule add` 或 `calpilot schedule preset school`。")
        } else {
            Console.note("  来源：schedule 字段")
        }
        Console.note("  缓冲 \(Format.duration(minutes: config.bufferMinutes))，每天最多 \(config.maxEventsPerDay) 个新日程")
        for warning in config.schedulingWarnings {
            Console.warn(warning)
        }
    }
}

struct ScheduleAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add an availability rule.",
        discussion: """
        Example: calpilot schedule add --days mon,tue,wed,thu,fri --start 07:40 --end 21:00 \
        --break 11:40-12:30 --break 17:00-18:00
        """
    )

    @Option(name: .long, help: "Weekday names: mon,tue,wed,thu,fri,sat,sun (or 每天).")
    var days: String

    @Option(name: .long, help: "Window start, e.g. 07:40.")
    var start: String

    @Option(name: .long, help: "Window end, e.g. 21:00.")
    var end: String

    @Option(name: .long, parsing: .upToNextOption, help: "Unavailable stretch inside the window, e.g. 11:40-12:30. Repeatable.")
    var `break`: [String] = []

    @Flag(name: .long, help: "Replace every existing rule instead of adding to them.")
    var replace = false

    func run() async throws {
        var config = try Runtime.loadConfig()
        guard let parsedDays = WeekdayParser.parse(days) else {
            throw CLIError("--days must be weekday names like mon,tue,wed (or 每天). Got \"\(days)\".")
        }
        guard let range = Format.parseClockRange("\(start)-\(end)") else {
            throw CLIError("--start and --end must be clock times like 07:40 and 21:00.")
        }
        let startMinutes = range.start.0 * 60 + range.start.1
        let endMinutes = range.end.0 * 60 + range.end.1
        guard endMinutes > startMinutes else {
            throw CLIError("--end (\(end)) must be after --start (\(start)).")
        }
        for entry in self.break where Format.parseClockRange(entry) == nil {
            throw CLIError("--break needs two times, e.g. 11:40-12:30. Got \"\(entry)\".")
        }

        let rule = ScheduleRule(days: parsedDays, start: start, end: end, breaks: self.break)
        var rules = replace ? [] : config.effectiveSchedule
        rules.append(rule)
        config.schedule = rules
        try ConfigStore.save(config)

        Console.success("added \(rule.summary)")
        if config.usesLegacySchedule {
            Console.note("  these rules now take precedence over workDayStart/workDayEnd")
        }
        if replace {
            Console.note("  replaced the previous rules")
        }
    }
}

struct ScheduleRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove a rule by its index.")

    @Argument(help: "Rule index as shown by `calpilot schedule show`.")
    var index: Int

    func run() async throws {
        var config = try Runtime.loadConfig()
        var rules = config.effectiveSchedule
        guard rules.indices.contains(index) else {
            throw CLIError("No rule at index \(index). Run `calpilot schedule show`.")
        }
        let removed = rules.remove(at: index)
        config.schedule = rules.isEmpty ? nil : rules
        try ConfigStore.save(config)
        Console.success("removed \(removed.summary)")
        if rules.isEmpty {
            Console.note("  no rules left, so the legacy workDayStart/workDayEnd fields apply again")
        }
    }
}

struct SchedulePresetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preset",
        abstract: "Start from a sensible set of rules you can then edit.",
        discussion: "Presets replace every existing rule."
    )

    enum Preset: String, CaseIterable, ExpressibleByArgument {
        case office
        case school
        case shift
    }

    @Argument(help: "office | school | shift")
    var preset: Preset

    func run() async throws {
        var config = try Runtime.loadConfig()
        let weekdays: [Int] = [2, 3, 4, 5, 6]
        let weekend: [Int] = [1, 7]
        let rules: [ScheduleRule]
        switch preset {
        case .office:
            rules = [ScheduleRule(days: weekdays, start: "09:00", end: "18:00", breaks: ["12:00-13:00"])]
        case .school:
            rules = [
                ScheduleRule(days: weekdays, start: "08:00", end: "20:00", breaks: ["12:00-13:00", "17:00-18:00"]),
                ScheduleRule(days: weekend, start: "10:00", end: "18:00"),
            ]
        case .shift:
            rules = [
                ScheduleRule(days: [2, 3, 4, 5], start: "08:00", end: "16:00"),
                ScheduleRule(days: [6, 7, 1], start: "12:00", end: "22:00"),
            ]
        }
        config.schedule = rules
        try ConfigStore.save(config)
        Console.success("applied the \(preset.rawValue) preset")
        for rule in rules {
            Console.note("  " + rule.summary)
        }
        Console.note("  edit with `calpilot schedule add` / `remove`, or in the app's Settings.")
    }
}

struct ScheduleClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Drop every rule and fall back to the legacy single window."
    )

    func run() async throws {
        var config = try Runtime.loadConfig()
        config.schedule = nil
        try ConfigStore.save(config)
        Console.success("cleared the rules; workDayStart/workDayEnd/lunchBreak apply again")
        Console.note("  \(config.availabilitySummary)")
    }
}
