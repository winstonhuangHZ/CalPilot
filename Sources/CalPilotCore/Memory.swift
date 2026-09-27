import Foundation

/// One durable fact CalPilot should remember about how you like your time arranged.
public struct MemoryEntry: Codable, Identifiable, Hashable {
    public enum Kind: String, Codable, CaseIterable {
        /// How the user likes to work: "上午做深度工作".
        case preference
        /// Something that must not be violated: "周三晚上不要排事".
        case constraint
        /// Context worth knowing: "10 月要交论文初稿".
        case fact
        /// People and places: "和张老师开会要留 30 分钟缓冲".
        case person
    }

    public var id: String
    public var text: String
    public var kind: Kind
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var timesUsed: Int
    /// Pinned memories are always included in the prompt, even when the budget is tight.
    public var pinned: Bool

    public init(
        id: String = MemoryEntry.newID(),
        text: String,
        kind: Kind = .preference,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil,
        timesUsed: Int = 0,
        pinned: Bool = false
    ) {
        self.id = id
        self.text = text
        self.kind = kind
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.timesUsed = timesUsed
        self.pinned = pinned
    }

    public static func newID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}

/// JSON-backed store for the personal memory block.
public struct MemoryStore {
    public var entries: [MemoryEntry]

    public init(entries: [MemoryEntry] = []) {
        self.entries = entries
    }

    public static var storageURL: URL { ConfigStore.directory.appendingPathComponent("memory.json") }

    // MARK: - Persistence

    public static func load() -> MemoryStore {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? CalPilotJSON.decoder().decode([MemoryEntry].self, from: data)
        else { return MemoryStore() }
        return MemoryStore(entries: decoded)
    }

    /// Best-effort load that never throws: a corrupt file starts a fresh store and is
    /// moved aside instead of being silently overwritten.
    public static func loadRecovering() -> MemoryStore {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return MemoryStore() }
        if let data = try? Data(contentsOf: storageURL),
           let decoded = try? CalPilotJSON.decoder().decode([MemoryEntry].self, from: data) {
            return MemoryStore(entries: decoded)
        }
        let backup = storageURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: storageURL, to: backup)
        Console.warn("memory.json could not be read; it was moved to \(backup.lastPathComponent)")
        return MemoryStore()
    }

    public func save() throws {
        try ConfigStore.ensureDirectory()
        let data = try CalPilotJSON.encoder(pretty: true).encode(entries)
        try data.write(to: Self.storageURL, options: .atomic)
    }

    // MARK: - Mutation

    @discardableResult
    public mutating func add(text: String, kind: MemoryEntry.Kind = .preference, pinned: Bool = false) -> MemoryEntry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = entries.first(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        let entry = MemoryEntry(text: trimmed, kind: kind, pinned: pinned)
        entries.append(entry)
        return entry
    }

    @discardableResult
    public mutating func remove(idOrPrefix: String) -> MemoryEntry? {
        let needle = idOrPrefix.lowercased()
        guard let index = entries.firstIndex(where: { $0.id.lowercased() == needle || $0.id.lowercased().hasPrefix(needle) }) else {
            return nil
        }
        return entries.remove(at: index)
    }

    public mutating func markUsed(ids: [String], at date: Date = Date()) {
        let wanted = Set(ids)
        for index in entries.indices where wanted.contains(entries[index].id) {
            entries[index].lastUsedAt = date
            entries[index].timesUsed += 1
        }
    }

    // MARK: - Prompt block

    /// Selection rules: every pinned entry, then the most recently used, then the newest,
    /// capped so the memory block cannot crowd out the calendar context.
    public func promptEntries(limit: Int = 20, matching query: String? = nil) -> [MemoryEntry] {
        var pool = entries
        if let query, !query.isEmpty {
            let tokens = query.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
                .map(String.init)
                .filter { $0.count > 1 }
            if !tokens.isEmpty {
                let relevant = pool.filter { entry in
                    let haystack = entry.text.lowercased()
                    return tokens.contains { haystack.contains($0) }
                }
                let pinned = pool.filter { $0.pinned && !relevant.contains($0) }
                pool = relevant + pinned
            }
        }
        let pinned = pool.filter { $0.pinned }
        let rest = pool.filter { !$0.pinned }
            .sorted { lhs, rhs in
                let l = lhs.lastUsedAt ?? lhs.createdAt
                let r = rhs.lastUsedAt ?? rhs.createdAt
                return l > r
            }
        return Array((pinned + rest).prefix(limit))
    }

    /// Renders the memory block that is injected into every planning prompt.
    public func promptBlock(limit: Int = 20, matching query: String? = nil) -> String {
        let selected = promptEntries(limit: limit, matching: query)
        guard !selected.isEmpty else { return "" }
        var lines = ["## What you already know about this user"]
        lines.append("Treat these as standing instructions. They outrank your own defaults.")
        for entry in selected {
            let tag = entry.pinned ? "\(entry.kind.rawValue), pinned" : entry.kind.rawValue
            lines.append("- [\(tag)] \(entry.text)")
        }
        return lines.joined(separator: "\n")
    }

    public func selectedIDs(limit: Int = 20, matching query: String? = nil) -> [String] {
        promptEntries(limit: limit, matching: query).map { $0.id }
    }
}
