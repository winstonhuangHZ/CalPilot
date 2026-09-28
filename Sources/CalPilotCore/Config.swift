import Foundation

/// One availability rule: which weekdays, what hours, and the breaks inside those hours.
///
/// A single window plus a lunch break is a work model. School, shift work, and most
/// real weeks need several: weekdays that run late, weekends that start late, and more
/// than one fixed break.
public struct ScheduleRule: Codable, Hashable, Identifiable {
    /// `Calendar` weekday numbers, 1 = Sunday … 7 = Saturday. Empty means every day.
    public var days: [Int]
    public var start: String
    public var end: String
    /// Unavailable stretches inside the window: lunch, commute, dinner, a standing class.
    public var breaks: [String]

    public var id: String { "\(days.sorted().map(String.init).joined(separator: ","))-\(start)-\(end)-\(breaks.joined(separator: "|"))" }

    public init(days: [Int], start: String, end: String, breaks: [String] = []) {
        self.days = days
        self.start = start
        self.end = end
        self.breaks = breaks
    }

    public var dayDescription: String { Format.describeDays(days) }

    /// "周一–周五 07:40–21:00（休息 11:40–12:30、17:00–18:00）"
    public var summary: String {
        var text = "\(dayDescription) \(start)–\(end)"
        if !breaks.isEmpty {
            text += "（休息 \(breaks.joined(separator: "、"))）"
        }
        return text
    }
}

/// User-editable configuration, stored at `~/.config/calpilot/config.json`.
public struct AppConfig: Codable {
    // Language model access (any OpenAI-compatible endpoint).
    public var baseURL: String
    public var model: String
    /// Environment variable that holds the API key when the Keychain is empty.
    public var apiKeyEnv: String
    /// Optional, only used when `--base-url` points at a non-standard path.
    public var chatPath: String

    // Calendar behaviour.
    /// Calendar that CalPilot is allowed to write to. Everything else stays untouched.
    public var writeCalendar: String
    public var autoCreateCalendar: Bool
    public var timeZone: String

    // Availability handed to the model.
    //
    // `schedule` is the modern form. The four fields below it are the original
    // single-window model, still honoured when `schedule` is absent so an existing
    // config.json keeps working.
    public var schedule: [ScheduleRule]?
    public var workDayStart: String
    public var workDayEnd: String
    /// `Calendar` weekday numbers: 1 = Sunday ... 7 = Saturday.
    public var workDays: [Int]
    public var defaultEventMinutes: Int
    public var bufferMinutes: Int
    public var maxEventsPerDay: Int
    public var lunchBreak: String?
    public var extraInstructions: String

    public init(
        baseURL: String = "https://api.openai.com/v1",
        model: String = "gpt-4o-mini",
        apiKeyEnv: String = "OPENAI_API_KEY",
        chatPath: String = "/chat/completions",
        writeCalendar: String = "CalPilot",
        autoCreateCalendar: Bool = true,
        timeZone: String = TimeZone.current.identifier,
        schedule: [ScheduleRule]? = nil,
        workDayStart: String = "09:00",
        workDayEnd: String = "18:00",
        workDays: [Int] = [2, 3, 4, 5, 6],
        defaultEventMinutes: Int = 60,
        bufferMinutes: Int = 10,
        maxEventsPerDay: Int = 4,
        lunchBreak: String? = "12:00-13:00",
        extraInstructions: String = ""
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKeyEnv = apiKeyEnv
        self.chatPath = chatPath
        self.writeCalendar = writeCalendar
        self.autoCreateCalendar = autoCreateCalendar
        self.timeZone = timeZone
        self.schedule = schedule
        self.workDayStart = workDayStart
        self.workDayEnd = workDayEnd
        self.workDays = workDays
        self.defaultEventMinutes = defaultEventMinutes
        self.bufferMinutes = bufferMinutes
        self.maxEventsPerDay = maxEventsPerDay
        self.lunchBreak = lunchBreak
        self.extraInstructions = extraInstructions
    }

    public var timeZoneObject: TimeZone {
        TimeZone(identifier: timeZone) ?? .current
    }

    public var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZoneObject
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    /// The rules the scheduler actually uses: `schedule` when present, otherwise one rule
    /// assembled from the legacy fields.
    public var effectiveSchedule: [ScheduleRule] {
        if let schedule, !schedule.isEmpty { return schedule }
        let breaks = [lunchBreak]
            .compactMap { $0 }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return [ScheduleRule(days: workDays, start: workDayStart, end: workDayEnd, breaks: breaks)]
    }

    public var usesLegacySchedule: Bool {
        (schedule?.isEmpty ?? true)
    }

    /// One line for prompts and the UI: "周一–周五 07:40–21:00（休息 11:40–12:30）；周六、周日 10:00–18:00".
    public var availabilitySummary: String {
        effectiveSchedule.map { $0.summary }.joined(separator: "；")
    }

    /// Longest window in the schedule, used to sanity-check the block sizing.
    public var longestAvailableWindowMinutes: Int {
        effectiveSchedule.compactMap { rule in
            Format.parseClockRange("\(rule.start)-\(rule.end)").map { range -> Int in
                let start = range.start.0 * 60 + range.start.1
                let end = range.end.0 * 60 + range.end.1
                return max(0, end - start)
            }
        }.max() ?? 0
    }

    /// Values the scheduler could not read, phrased for a human. Surfaced by `doctor`,
    /// `plan`, and the window on launch, because a silently ignored preference is the
    /// worst outcome: the plan looks fine but quietly ignores what you asked for.
    public var schedulingWarnings: [String] {
        var warnings: [String] = []
        for (index, rule) in effectiveSchedule.enumerated() {
            let label = usesLegacySchedule ? "排程时段" : "第 \(index + 1) 条时段规则"
            guard let range = Format.parseClockRange("\(rule.start)-\(rule.end)") else {
                warnings.append("\(label)「\(rule.start)-\(rule.end)」无法识别，已按 09:00-18:00 处理。")
                continue
            }
            let startMinutes = range.start.0 * 60 + range.start.1
            let endMinutes = range.end.0 * 60 + range.end.1
            if endMinutes <= startMinutes {
                warnings.append("\(label)的结束时间 \(rule.end) 不在 \(rule.start) 之后，这条规则会被跳过。")
            }
            for entry in rule.breaks where Format.parseClockRange(entry) == nil {
                warnings.append("\(label)的休息时间「\(entry)」无法识别，已被忽略。")
            }
        }
        if let schedule, schedule.isEmpty {
            warnings.append("schedule 为空数组，已回退到 workDayStart/workDayEnd 的单一时段。")
        }
        if usesLegacySchedule, workDays.isEmpty {
            warnings.append("workDays 为空，已按每天都可以排处理。")
        }
        if defaultEventMinutes < 5 {
            warnings.append("默认时长少于 5 分钟，已按 5 分钟处理。")
        }
        return warnings
    }
}

public enum ConfigStore {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/calpilot", isDirectory: true)
    }

    public static var configURL: URL { directory.appendingPathComponent("config.json") }
    public static var journalURL: URL { directory.appendingPathComponent("journal.jsonl") }

    public static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Loads config, creating a default one on first run.
    ///
    /// A config that cannot be decoded does not abort the run: the file is left alone
    /// (it may hold settings worth recovering by hand) and the defaults are used in
    /// memory only.
    @discardableResult
    public static func loadOrCreate() throws -> AppConfig {
        try ensureDirectory()
        if !FileManager.default.fileExists(atPath: configURL.path) {
            let cfg = AppConfig()
            try save(cfg)
            return cfg
        }
        let data = try Data(contentsOf: configURL)
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            Console.warn("""
            \(configURL.path) could not be read (\(error.localizedDescription)).
            Falling back to defaults in memory; the file was left untouched.
            """)
            return AppConfig()
        }
    }

    public static func save(_ config: AppConfig) throws {
        try ensureDirectory()
        let data = try CalPilotJSON.encoder(pretty: true).encode(config)
        try data.write(to: configURL, options: .atomic)
    }
}

// MARK: - API key resolution

public enum Credentials {
    public static let keychainService = "calpilot"

    /// Resolution order: explicit flag, `CALPILOT_API_KEY`, configured env var, Keychain.
    ///
    /// `keychainHint` is only supplied by the command line. Keychain ACLs are bound to the
    /// *binary*, not the bundle, so the terminal tool is a different identity from the
    /// window: the first read from the other one blocks on a system permission dialog.
    /// Without a heads-up that looks exactly like a freeze, so the read is watched and the
    /// hint fires if it takes longer than a second.
    public static func resolveAPIKey(
        config: AppConfig,
        explicit: String? = nil,
        keychainHint: (() -> Void)? = nil
    ) -> (key: String, source: String)? {
        if let explicit, !explicit.trimmingCharacters(in: .whitespaces).isEmpty {
            return (explicit.trimmingCharacters(in: .whitespaces), "--api-key")
        }
        let env = ProcessInfo.processInfo.environment
        if let v = env["CALPILOT_API_KEY"], !v.trimmingCharacters(in: .whitespaces).isEmpty {
            return (v.trimmingCharacters(in: .whitespaces), "env CALPILOT_API_KEY")
        }
        if let v = env[config.apiKeyEnv], !v.trimmingCharacters(in: .whitespaces).isEmpty {
            return (v.trimmingCharacters(in: .whitespaces), "env \(config.apiKeyEnv)")
        }
        let account = keychainAccount(forBaseURL: config.baseURL)
        if let keychainHint {
            if let v = readWatched(account: account, hint: keychainHint), !v.isEmpty {
                return (v, "Keychain (\(account))")
            }
        } else if let v = Keychain.read(service: keychainService, account: account), !v.isEmpty {
            return (v, "Keychain (\(account))")
        }
        return nil
    }

    private final class ValueBox: @unchecked Sendable {
        var value: String?
    }

    private static func readWatched(account: String, hint: () -> Void) -> String? {
        let box = ValueBox()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = Keychain.read(service: keychainService, account: account)
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 1) == .timedOut {
            hint()
            semaphore.wait()
        }
        return box.value
    }

    public static func keychainAccount(forBaseURL baseURL: String) -> String {
        guard let host = URL(string: baseURL)?.host else { return "default" }
        return host
    }
}
