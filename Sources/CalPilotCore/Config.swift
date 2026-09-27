import Foundation

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

    // Scheduling preferences handed to the model.
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
    @discardableResult
    public static func loadOrCreate() throws -> AppConfig {
        try ensureDirectory()
        if !FileManager.default.fileExists(atPath: configURL.path) {
            let cfg = AppConfig()
            try save(cfg)
            return cfg
        }
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(AppConfig.self, from: data)
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
    public static func resolveAPIKey(config: AppConfig, explicit: String? = nil) -> (key: String, source: String)? {
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
        if let v = Keychain.read(service: keychainService, account: account), !v.isEmpty {
            return (v, "Keychain (\(account))")
        }
        return nil
    }

    public static func keychainAccount(forBaseURL baseURL: String) -> String {
        guard let host = URL(string: baseURL)?.host else { return "default" }
        return host
    }
}
