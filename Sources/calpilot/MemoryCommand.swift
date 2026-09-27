import ArgumentParser
import CalPilotCore
import Foundation

/// Manages the personal memory block that is injected into every planning prompt.
struct MemoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "memory",
        abstract: "Manage the personal memory block the agent always sees.",
        discussion: """
        Memories are durable statements about how you like your time arranged. They are
        injected into the system prompt of both `plan` and `chat`, ahead of your defaults.
        """,
        subcommands: [
            MemoryListCommand.self,
            MemoryAddCommand.self,
            MemoryRemoveCommand.self,
            MemoryPinCommand.self,
        ],
        defaultSubcommand: MemoryListCommand.self
    )
}

struct MemoryListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List the memory block.")

    @Flag(name: .long, help: "Emit JSON.")
    var json = false

    func run() async throws {
        let store = MemoryStore.loadRecovering()
        if json {
            try Runtime.printJSON(store.entries)
            return
        }
        if store.entries.isEmpty {
            Console.note("the memory block is empty — add one with `calpilot memory add \"上午不要安排会议\"`")
            return
        }
        Console.table(
            headers: ["ID", "Kind", "Pinned", "Used", "Memory"],
            rows: store.entries.map { entry in
                [
                    entry.id,
                    entry.kind.rawValue,
                    entry.pinned ? "yes" : "",
                    entry.timesUsed == 0 ? "" : "\(entry.timesUsed)",
                    entry.text,
                ]
            }
        )
        Console.note("  \(MemoryStore.storageURL.path)")
        Console.note("  \(store.promptEntries().count) of \(store.entries.count) entries are in the prompt right now")
    }
}

struct MemoryAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a durable preference, constraint, fact, or person detail."
    )

    @Argument(help: "The memory text, e.g. \"上午做深度工作，不要安排会议\".")
    var text: String

    @Option(name: .long, help: "preference | constraint | fact | person")
    var kind: String = MemoryEntry.Kind.preference.rawValue

    @Flag(name: .long, help: "Always include this memory in the prompt.")
    var pin = false

    func run() async throws {
        guard let parsedKind = MemoryEntry.Kind(rawValue: kind.lowercased()) else {
            throw CLIError("--kind must be one of: \(MemoryEntry.Kind.allCases.map { $0.rawValue }.joined(separator: ", "))")
        }
        var store = MemoryStore.loadRecovering()
        guard let entry = store.add(text: text, kind: parsedKind, pinned: pin) else {
            throw CLIError("The memory was empty.")
        }
        try store.save()
        Console.success("remembered [\(entry.kind.rawValue)\(entry.pinned ? ", pinned" : "")] \(entry.text)")
        Console.note("  id \(entry.id)")
    }
}

struct MemoryRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Delete a memory by id.")

    @Argument(help: "Memory id (a unique prefix is enough).")
    var id: String

    func run() async throws {
        var store = MemoryStore.loadRecovering()
        guard let removed = store.remove(idOrPrefix: id) else {
            throw CLIError("No memory matches \"\(id)\". Run `calpilot memory list`.")
        }
        try store.save()
        Console.success("forgot: \(removed.text)")
    }
}

struct MemoryPinCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pin",
        abstract: "Pin or unpin a memory so it is always part of the prompt."
    )

    @Argument(help: "Memory id.")
    var id: String

    @Flag(name: .long, help: "Remove the pin instead of adding one.")
    var off = false

    func run() async throws {
        var store = MemoryStore.loadRecovering()
        let needle = id.lowercased()
        guard let index = store.entries.firstIndex(where: {
            $0.id.lowercased() == needle || $0.id.lowercased().hasPrefix(needle)
        }) else {
            throw CLIError("No memory matches \"\(id)\". Run `calpilot memory list`.")
        }
        store.entries[index].pinned = !off
        let entry = store.entries[index]
        try store.save()
        Console.success("\(off ? "unpinned" : "pinned"): \(entry.text)")
    }
}
