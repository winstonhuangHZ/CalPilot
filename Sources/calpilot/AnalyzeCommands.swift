import ArgumentParser
import CalPilotCore
import Foundation

// MARK: - analyze

struct AnalyzeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Summarise how your time was actually spent over a past window.",
        discussion: """
        Statistics are computed locally, so this needs no API key and costs no tokens.
        Use it to review a period, or ask the agent the same question in `chat`.
        """
    )

    @Option(name: .long, help: "How many days back from now to analyse.")
    var days: Int = 30

    @Option(name: .long, help: "Explicit window start, overriding --days.")
    var from: String?

    @Option(name: .long, help: "Explicit window end. Defaults to now.")
    var to: String?

    @Option(name: .long, help: "Limit the analysis to one calendar.")
    var calendar: String?

    @Flag(name: .long, help: "Emit the raw analysis as JSON.")
    var json = false

    func run() async throws {
        let config = try Runtime.loadConfig()
        let service = try await Runtime.connectedService(config: config)

        let end: Date
        if let to {
            end = try FlexibleDate.parse(to, calendar: config.calendar)
        } else {
            end = Date()
        }
        let start: Date
        if let from {
            start = try FlexibleDate.parse(from, calendar: config.calendar)
        } else {
            start = config.calendar.date(byAdding: .day, value: -max(1, days), to: end)
                ?? end.addingTimeInterval(-Double(max(1, days)) * 86_400)
        }
        guard end > start else {
            throw CLIError("The window ends before it starts.")
        }

        var ids: [String]? = nil
        if let calendar {
            guard let match = service.findCalendar(named: calendar) else {
                throw CLIError("No calendar matches \"\(calendar)\". Run `calpilot calendars`.")
            }
            ids = [match.calendarIdentifier]
        }

        let events = service.events(from: start, to: end, calendarIDs: ids)
        let analysis = CalendarAnalyzer.analyze(
            events: events,
            config: config,
            rangeStart: start,
            rangeEnd: end
        )

        if json {
            try Runtime.printJSON(analysis)
            return
        }
        ReportRenderer.render(analysis, config: config)
    }
}

extension AnalyzeCommand {
    /// Shared by `analyze` and the GUI sidebar so both describe the numbers the same way.
    enum ReportRenderer {
        static func render(_ analysis: CalendarAnalysis, config: AppConfig) {
            let calendar = config.calendar
            Console.heading("时间分布")
            Console.note("  \(Format.day(analysis.rangeStart, calendar: calendar)) → \(Format.day(analysis.rangeEnd, calendar: calendar))"
                + "  ·  \(analysis.days) 天  ·  \(analysis.totalEvents) 个日程")
            print("")
            for line in analysis.summaryLines {
                print("  " + line)
            }

            Console.heading("按日历")
            let calendarRows = analysis.byCalendar.map { share -> [String] in
                [
                    share.calendarName,
                    Format.hours(share.hours),
                    "\(share.eventCount)",
                    "\(Int((share.share * 100).rounded()))%",
                    bar(share.share, width: 16),
                ]
            }
            Console.table(headers: ["日历", "时长", "条数", "占比", ""], rows: calendarRows)

            Console.heading("按星期")
            let weekdayRows = analysis.byWeekday.map { stat in
                [
                    Format.weekdayLabel(stat.weekday),
                    Format.hours(stat.averageHours),
                    Format.hours(stat.totalHours),
                    "\(stat.days)",
                    bar(stat.averageHours / max(0.001, busiestAverage(analysis)), width: 16),
                ]
            }
            Console.table(headers: ["星期", "日均", "合计", "天数", ""], rows: weekdayRows)

            if !analysis.busiestDays.isEmpty {
                Console.heading("最忙的几天")
                let rows = analysis.busiestDays.map { day in
                    [
                        Format.day(day.date, calendar: calendar),
                        Format.weekdayLabel(day.weekday),
                        Format.hours(day.hours),
                        "\(day.eventCount)",
                    ]
                }
                Console.table(headers: ["日期", "星期", "时长", "条数"], rows: rows)
            }

            if !analysis.mostCommonTitles.isEmpty {
                Console.heading("最常出现的日程")
                let rows = analysis.mostCommonTitles.map { stat in
                    [stat.title, "\(stat.count)", Format.hours(stat.hours)]
                }
                Console.table(headers: ["标题", "次数", "合计"], rows: rows)
            }

            Console.heading("碎片化")
            print("  可安排时长     \(Format.hours(analysis.availableHours))"
                + "   \(config.availabilitySummary)")
            print("  已被占用       \(Format.hours(analysis.bookedHours))"
                + "  (\(Int((analysis.utilization * 100).rounded()))%)")
            print("  最长连续空档   \(Format.duration(minutes: analysis.longestFocusBlockMinutes))")
            print("  平均连续空档   \(Format.duration(minutes: analysis.averageFocusBlockMinutes))")
            print("  无固定日程日   \(analysis.daysWithNoCommitments) 天")
            print("  单次时长       中位 \(Format.duration(minutes: analysis.medianEventMinutes))"
                + "，平均 \(Format.duration(minutes: analysis.averageEventMinutes))")

            if !analysis.notes.isEmpty {
                Console.heading("观察")
                for note in analysis.notes {
                    print("  · " + note)
                }
            }
            Console.note("\n  `calpilot analyze --json` 可以拿到完整数据。")
        }

        private static func busiestAverage(_ analysis: CalendarAnalysis) -> Double {
            analysis.byWeekday.map { $0.averageHours }.max() ?? 1
        }

        private static func bar(_ fraction: Double, width: Int) -> String {
            let filled = Int((min(1, max(0, fraction)) * Double(width)).rounded())
            return String(repeating: "█", count: filled) + String(repeating: "·", count: width - filled)
        }
    }
}

// MARK: - sessions

struct SessionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sessions",
        abstract: "Inspect and manage saved conversations.",
        subcommands: [SessionsListCommand.self, SessionsShowCommand.self, SessionsRemoveCommand.self],
        defaultSubcommand: SessionsListCommand.self
    )
}

struct SessionsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List saved conversations.")

    @Flag(name: .long, help: "Emit JSON.")
    var json = false

    func run() async throws {
        let sessions = SessionStore.list()
        if json {
            try Runtime.printJSON(sessions)
            return
        }
        guard !sessions.isEmpty else {
            Console.note("no saved conversations yet — `calpilot chat` creates one")
            return
        }
        let config = try Runtime.loadConfig()
        let rows = sessions.map { session -> [String] in
            [
                String(session.id.uuidString.prefix(8)).lowercased(),
                Format.day(session.updatedAt, calendar: config.calendar),
                "\(session.messageCount)",
                session.title,
            ]
        }
        Console.table(headers: ["ID", "最后更新", "消息", "标题"], rows: rows)
        Console.note("  \(SessionStore.directory.path)")
        Console.note("  resume one with `calpilot chat --resume <ID>`")
    }
}

struct SessionsShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Print a saved conversation.")

    @Argument(help: "Session id (a unique prefix is enough).")
    var id: String

    func run() async throws {
        let config = try Runtime.loadConfig()
        guard let resolved = SessionStore.resolve(prefix: id), let session = SessionStore.load(id: resolved) else {
            throw CLIError("No saved conversation matches \"\(id)\". Run `calpilot sessions list`.")
        }
        Console.heading("\(session.title)")
        Console.note("  id \(session.id.uuidString.lowercased())")
        Console.note("  \(Format.iso(session.createdAt, calendar: config.calendar)) → \(Format.iso(session.updatedAt, calendar: config.calendar))")
        Console.note("  \(session.turns.count) turns, \(session.agent.messages.count) model messages")
        print("")
        for turn in session.turns {
            let stamp = Format.human(turn.at, calendar: config.calendar)
            switch turn.kind {
            case .user: print("\(stamp)  › \(turn.text)")
            case .assistant: print("\(stamp)  \(turn.text)\n")
            case .tool: print("\(stamp)    · \(turn.text)")
            case .toolResult: print("\(stamp)      ↳ \(turn.text)")
            case .notice: print("\(stamp)    ~ \(turn.text)")
            case .error: print("\(stamp)    ! \(turn.text)")
            }
        }
    }
}

struct SessionsRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Delete a saved conversation.")

    @Argument(help: "Session id (a unique prefix is enough).")
    var id: String

    @Flag(name: .long, help: "Skip the confirmation prompt.")
    var yes = false

    func run() async throws {
        guard let resolved = SessionStore.resolve(prefix: id), let session = SessionStore.load(id: resolved) else {
            throw CLIError("No saved conversation matches \"\(id)\". Run `calpilot sessions list`.")
        }
        if !yes {
            guard Console.confirm("Delete \"\(session.title)\"?", default: false) else {
                Console.note("cancelled")
                throw ExitCode(ExitCodes.cancelled)
            }
        }
        try SessionStore.delete(id: resolved)
        Console.success("deleted \(session.title)")
    }
}
