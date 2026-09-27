import Foundation

/// Append-only record of everything CalPilot wrote, which makes `calpilot undo` possible.
public struct JournalEntry: Codable, Hashable {
    public enum Action: String, Codable {
        case create
        case delete
    }

    public var timestamp: Date
    public var action: Action
    public var batchID: String
    public var eventID: String
    public var calendarID: String
    public var title: String
    public var start: Date
    public var end: Date
    public var source: String

    public init(
        timestamp: Date = Date(),
        action: Action,
        batchID: String,
        eventID: String,
        calendarID: String,
        title: String,
        start: Date,
        end: Date,
        source: String
    ) {
        self.timestamp = timestamp
        self.action = action
        self.batchID = batchID
        self.eventID = eventID
        self.calendarID = calendarID
        self.title = title
        self.start = start
        self.end = end
        self.source = source
    }
}

public enum Journal {
    public static func newBatchID() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        return "\(f.string(from: Date()))-\(suffix)"
    }

    public static func append(_ entry: JournalEntry) throws {
        try ConfigStore.ensureDirectory()
        let url = ConfigStore.journalURL
        let line = try CalPilotJSON.encodeToString(entry, pretty: false) + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    public static func all() -> [JournalEntry] {
        guard let text = try? String(contentsOf: ConfigStore.journalURL, encoding: .utf8) else { return [] }
        let decoder = CalPilotJSON.decoder()
        return text
            .split(separator: "\n")
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(JournalEntry.self, from: data)
            }
    }

    /// Event IDs CalPilot created and has not deleted again.
    public static func liveCreatedEventIDs() -> Set<String> {
        var live: [String: String] = [:]  // eventID -> action
        for entry in all() {
            live[entry.eventID] = entry.action.rawValue
        }
        return Set(live.filter { $0.value == JournalEntry.Action.create.rawValue }.keys)
    }

    /// Most recent batch that created events, plus its entries.
    public static func lastCreateBatch() -> (batchID: String, entries: [JournalEntry])? {
        let creates = all().filter { $0.action == .create }
        guard let last = creates.last else { return nil }
        let entries = creates.filter { $0.batchID == last.batchID }
        return (last.batchID, entries)
    }
}
