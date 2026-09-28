import Foundation

/// One visible line of a conversation. Lives in Core so both the CLI and the GUI render
/// the same record, and so a session can be reopened from disk by either of them.
public struct ChatTurn: Codable, Identifiable, Hashable {
    public enum Kind: String, Codable {
        case user
        case assistant
        case tool
        case toolResult
        case notice
        case error
    }

    public var id: UUID
    public var kind: Kind
    public var text: String
    public var at: Date

    public init(id: UUID = UUID(), kind: Kind, text: String, at: Date = Date()) {
        self.id = id
        self.kind = kind
        self.text = text
        self.at = at
    }
}

/// A persisted conversation.
///
/// It stores two views of the same exchange on purpose:
/// - `turns` is what the user sees, cheap to render.
/// - `agent` is the model's actual transcript, including tool calls and their results.
///   Resuming from it keeps the context (and the prompt-cache prefix) that a replay of
///   `turns` could not reconstruct.
public struct ChatSession: Codable, Identifiable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var turns: [ChatTurn]
    public var agent: Agent.State
    /// Set when the user renamed it, so auto-titling stops overwriting their choice.
    public var titleIsManual: Bool

    public init(
        id: UUID = UUID(),
        title: String = "新对话",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        turns: [ChatTurn] = [],
        agent: Agent.State = Agent.State(),
        titleIsManual: Bool = false
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.turns = turns
        self.agent = agent
        self.titleIsManual = titleIsManual
    }

    /// Short label for a session list.
    public static func suggestedTitle(from turns: [ChatTurn], limit: Int = 24) -> String {
        guard let first = turns.first(where: { $0.kind == .user }) else { return "新对话" }
        let cleaned = first.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned.isEmpty ? "新对话" : cleaned }
        return String(cleaned.prefix(limit)) + "…"
    }

    public var messageCount: Int {
        turns.filter { $0.kind == .user || $0.kind == .assistant }.count
    }
}

public struct SessionSummary: Codable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var turnCount: Int
    public var messageCount: Int
}

/// One JSON file per conversation under `~/.config/calpilot/sessions/`.
///
/// Per-file rather than one big array so a single corrupt session cannot take the whole
/// history with it.
public enum SessionStore {
    public static var directory: URL {
        ConfigStore.directory.appendingPathComponent("sessions", isDirectory: true)
    }

    public static func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    public static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func save(_ session: ChatSession) throws {
        try ensureDirectory()
        let data = try CalPilotJSON.encoder(pretty: false).encode(session)
        try data.write(to: url(for: session.id), options: .atomic)
    }

    public static func load(id: UUID) -> ChatSession? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        return try? CalPilotJSON.decoder().decode(ChatSession.self, from: data)
    }

    public static func delete(id: UUID) throws {
        let target = url(for: id)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.removeItem(at: target)
    }

    /// All sessions, most recently updated first.
    public static func list() -> [SessionSummary] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        var summaries: [SessionSummary] = []
        for entry in entries where entry.pathExtension == "json" {
            guard let data = try? Data(contentsOf: entry),
                  let session = try? CalPilotJSON.decoder().decode(ChatSession.self, from: data)
            else { continue }
            summaries.append(SessionSummary(
                id: session.id,
                title: session.title,
                createdAt: session.createdAt,
                updatedAt: session.updatedAt,
                turnCount: session.turns.count,
                messageCount: session.messageCount
            ))
        }
        return summaries.sorted { $0.updatedAt > $1.updatedAt }
    }

    public static func mostRecent() -> ChatSession? {
        guard let newest = list().first else { return nil }
        return load(id: newest.id)
    }

    /// Resolves an id from a full UUID or any unique prefix, which is what a human types.
    public static func resolve(prefix: String) -> UUID? {
        let needle = prefix.lowercased()
        if let exact = UUID(uuidString: prefix) { return exact }
        let matches = list().filter { $0.id.uuidString.lowercased().hasPrefix(needle) }
        return matches.count == 1 ? matches[0].id : nil
    }
}
