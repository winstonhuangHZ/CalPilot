import ArgumentParser
import CalPilotCore
import Foundation

@main
struct CalPilot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calpilot",
        abstract: "Read and write your macOS Calendar, and let a language model plan your time.",
        discussion: """
        CalPilot reads every calendar you can see, but only ever writes into a single \
        calendar (default: "CalPilot"), and records what it wrote so `calpilot undo` can take it back.

        Get started:
          calpilot doctor                       check access, config, and the model endpoint
          calpilot config set-key sk-...        store the API key in the macOS Keychain
          calpilot plan --goal "安排这周" --days 7
          calpilot plan --goal "..." --apply    write the validated plan to the calendar
        """,
        version: "0.1.0",
        subcommands: [
            DoctorCommand.self,
            CalendarsCommand.self,
            EventsCommand.self,
            FreeCommand.self,
            PlanCommand.self,
            ChatCommand.self,
            ApplyCommand.self,
            UndoCommand.self,
            MemoryCommand.self,
            ConfigCommand.self,
            SelfTestCommand.self,
        ],
        defaultSubcommand: nil
    )
}

// MARK: - doctor

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check calendar access, configuration, and language model connectivity."
    )

    @Flag(name: .long, help: "Also send a tiny test request to the language model.")
    var pingLLM = false

    func run() async throws {
        let config = try Runtime.loadConfig()
        Console.heading("Configuration")
        print("  config file   \(ConfigStore.configURL.path)")
        print("  journal       \(ConfigStore.journalURL.path)")
        print("  time zone     \(config.timeZone)")
        print("  work hours    \(config.workDayStart)-\(config.workDayEnd)\(config.lunchBreak.map { ", lunch \($0)" } ?? "")")
        print("  write target  \(config.writeCalendar)\(config.autoCreateCalendar ? " (created on demand)" : "")")

        Console.heading("Calendar access")
        let service = CalendarService()
        print("  status        \(service.authorizationDescription)")
        if service.authorizationStatus != .fullAccess {
            Console.note("  requesting access…")
            let granted = (try? await service.requestFullAccess()) ?? false
            print("  after request \(service.authorizationDescription)")
            if !granted {
                Console.warn("Full calendar access is required. Grant it in System Settings > Privacy & Security > Calendars.")
            }
        }
        if service.authorizationStatus == .fullAccess {
            let calendars = service.calendarDTOs()
            Console.success("\(calendars.count) calendar(s) visible")
            for calendar in calendars where calendar.allowsModification {
                print("    · \(calendar.title) [\(calendar.source)]")
            }
            let writable = service.findCalendar(named: config.writeCalendar)
            if let writable, writable.allowsContentModifications {
                Console.success("write target \"\(writable.title)\" is ready")
            } else {
                Console.note("  write target \"\(config.writeCalendar)\" does not exist yet; it will be created on first apply")
            }
        }

        Console.heading("Language model")
        print("  endpoint      \(config.baseURL)\(config.chatPath)")
        print("  model         \(config.model)")
        if let resolved = Credentials.resolveAPIKey(config: config) {
            let masked = resolved.key.count > 8
                ? "\(resolved.key.prefix(3))…\(resolved.key.suffix(4))"
                : "…"
            print("  api key       \(masked)  (from \(resolved.source))")
            if pingLLM {
                let client = LLMClient(config: config, apiKey: resolved.key)
                Console.note("  sending test request…")
                do {
                    let reply = try await client.ping()
                    Console.success("model replied: \(reply.replacingOccurrences(of: "\n", with: " "))")
                } catch {
                    Console.error("test request failed: \(error)")
                }
            }
        } else {
            Console.warn("no API key found. Set one with `calpilot config set-key`, or export CALPILOT_API_KEY / \(config.apiKeyEnv).")
            Console.note("  `calpilot plan --offline` schedules without a model.")
        }
    }
}

// MARK: - calendars

struct CalendarsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendars",
        abstract: "List the calendars CalPilot can see."
    )

    @Flag(name: .long, help: "Emit JSON.")
    var json = false

    func run() async throws {
        let config = try Runtime.loadConfig()
        let service = try await Runtime.connectedService(config: config)
        let calendars = service.calendarDTOs()
        if json {
            try Runtime.printJSON(calendars)
            return
        }
        let rows = calendars.map { calendar -> [String] in
            [
                calendar.allowsModification ? "rw" : "ro",
                calendar.title,
                calendar.source,
                calendar.id.prefix(12) + "…",
            ]
        }
        Console.table(headers: ["Access", "Calendar", "Account", "ID"], rows: rows)
    }
}

// MARK: - config

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Inspect and edit the CalPilot configuration.",
        subcommands: [ConfigShowCommand.self, ConfigPathCommand.self, ConfigSetKeyCommand.self, ConfigSetCommand.self],
        defaultSubcommand: ConfigShowCommand.self
    )
}

struct ConfigShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Print the current configuration.")

    func run() async throws {
        let config = try Runtime.loadConfig()
        print(try CalPilotJSON.encodeToString(config, pretty: true))
        if let resolved = Credentials.resolveAPIKey(config: config) {
            Console.note("api key: found via \(resolved.source)")
        } else {
            Console.note("api key: not set")
        }
    }
}

struct ConfigPathCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "path", abstract: "Print config and journal paths.")

    func run() async throws {
        _ = try Runtime.loadConfig()
        print("config:  \(ConfigStore.configURL.path)")
        print("journal: \(ConfigStore.journalURL.path)")
    }
}

struct ConfigSetKeyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-key",
        abstract: "Store the language model API key in the macOS Keychain."
    )

    @Argument(help: "The API key. Omit to be prompted for it.")
    var key: String?

    @Option(name: .long, help: "Override the base URL the key belongs to (defaults to the configured one).")
    var baseURL: String?

    func run() async throws {
        let config = try Runtime.loadConfig()
        let value: String
        var isSecret = true
        if let key, !key.isEmpty {
            value = key.trimmingCharacters(in: .whitespaces)
        } else {
            print("API key: ", terminator: "")
            value = (readLine() ?? "").trimmingCharacters(in: .whitespaces)
            isSecret = false
        }
        _ = isSecret
        guard !value.isEmpty else { throw CLIError("No API key provided.") }
        let account = Credentials.keychainAccount(forBaseURL: baseURL ?? config.baseURL)
        try Keychain.write(service: Credentials.keychainService, account: account, value: value)
        Console.success("stored API key for \(account) in the login keychain")
    }
}

struct ConfigSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Update individual configuration values.",
        discussion: "Example: calpilot config set --model gpt-4o-mini --work-day-start 10:00 --work-day-end 19:00"
    )

    @Option(name: .long) var baseURL: String?
    @Option(name: .long) var model: String?
    @Option(name: .long) var apiKeyEnv: String?
    @Option(name: .long) var chatPath: String?
    @Option(name: .long) var writeCalendar: String?
    @Option(name: .long) var timeZone: String?
    @Option(name: .long) var workDayStart: String?
    @Option(name: .long) var workDayEnd: String?
    @Option(name: .long, help: "Weekdays as numbers 1=Sun … 7=Sat, e.g. 2,3,4,5,6")
    var workDays: String?
    @Option(name: .long) var defaultEventMinutes: Int?
    @Option(name: .long) var bufferMinutes: Int?
    @Option(name: .long) var maxEventsPerDay: Int?
    @Option(name: .long, help: "Lunch window such as 12:00-13:00, or \"none\" to disable.")
    var lunchBreak: String?
    @Option(name: .long, help: "Free-form preferences handed to the model on every plan.")
    var extraInstructions: String?

    func run() async throws {
        var config = try Runtime.loadConfig()
        if let baseURL { config.baseURL = baseURL }
        if let model { config.model = model }
        if let apiKeyEnv { config.apiKeyEnv = apiKeyEnv }
        if let chatPath { config.chatPath = chatPath }
        if let writeCalendar { config.writeCalendar = writeCalendar }
        if let timeZone {
            guard TimeZone(identifier: timeZone) != nil else {
                throw CLIError("\"\(timeZone)\" is not a known time zone identifier.")
            }
            config.timeZone = timeZone
        }
        if let workDayStart { config.workDayStart = workDayStart }
        if let workDayEnd { config.workDayEnd = workDayEnd }
        if let workDays {
            let parsed = workDays.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard !parsed.isEmpty, parsed.allSatisfy({ (1...7).contains($0) }) else {
                throw CLIError("--work-days expects numbers between 1 (Sunday) and 7 (Saturday).")
            }
            config.workDays = parsed.sorted()
        }
        if let defaultEventMinutes { config.defaultEventMinutes = max(5, defaultEventMinutes) }
        if let bufferMinutes { config.bufferMinutes = max(0, bufferMinutes) }
        if let maxEventsPerDay { config.maxEventsPerDay = max(1, maxEventsPerDay) }
        if let lunchBreak {
            config.lunchBreak = (lunchBreak.lowercased() == "none" || lunchBreak.isEmpty) ? nil : lunchBreak
        }
        if let extraInstructions { config.extraInstructions = extraInstructions }

        guard Format.parseClockRange("\(config.workDayStart)-\(config.workDayEnd)") != nil else {
            throw CLIError("Working hours must look like 09:00-18:00.")
        }
        try ConfigStore.save(config)
        Console.success("saved \(ConfigStore.configURL.path)")
    }
}
