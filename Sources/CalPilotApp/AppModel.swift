import AppKit
import CalPilotCore
import EventKit
import Foundation
import SwiftUI

/// One line in the visible transcript.
struct Turn: Identifiable {
    enum Kind {
        case user
        case assistant
        case tool
        case toolResult
        case notice
        case error
    }

    let id = UUID()
    var kind: Kind
    var text: String
    var at: Date = Date()
}

@MainActor
final class AppModel: ObservableObject {
    // Transcript
    @Published var turns: [Turn] = []
    @Published var input: String = ""
    @Published var isBusy = false

    // Calendar state
    @Published var calendarStatus: String = "checking…"
    @Published var calendarReady = false
    @Published var calendarCount = 0

    // Model / plan state
    @Published var config: AppConfig
    @Published var pendingPlan: Plan?
    @Published var memoryEntries: [MemoryEntry] = []
    @Published var usageSummary: String = ""
    @Published var showSettings = false

    private var service = CalendarService()
    private var agent: Agent?
    private var client: LLMClient?
    private var lastLoadedAt: Date?

    init() {
        self.config = (try? ConfigStore.loadOrCreate()) ?? AppConfig()
        self.memoryEntries = MemoryStore.loadRecovering().entries
        bootstrap()
    }

    // MARK: - Bootstrap

    private func bootstrap() {
        turns = []
        let key = Credentials.resolveAPIKey(config: config)
        if key == nil {
            append(.notice, "还没有配置 API Key。点右上角 Settings 填入，CalPilot 才能调用语言模型。")
            append(.notice, "日历读取不需要 Key，可以先在上面看到你的日程。")
        } else {
            append(.assistant, "我是 CalPilot。告诉我这周想怎么安排，我会先看你的日历，再给出方案——写入前一定问你。")
        }
        connect()
    }

    private func connect() {
        Task {
            do {
                let granted = try await service.requestFullAccess()
                calendarReady = granted
                if granted {
                    let calendars = service.calendarDTOs()
                    calendarCount = calendars.count
                    calendarStatus = "\(calendars.count) 个日历可读"
                    rebuildAgent()
                    await reloadCalendar(force: true)
                } else {
                    calendarStatus = "未授权"
                    append(.error, "日历权限未授予。到「系统设置 → 隐私与安全性 → 日历」里允许 CalPilot。")
                }
            } catch {
                calendarReady = false
                calendarStatus = "未授权"
                append(.error, "\(error)")
            }
        }
    }

    private func rebuildAgent() {
        guard let key = Credentials.resolveAPIKey(config: config) else {
            agent = nil
            client = nil
            return
        }
        let newClient = LLMClient(config: config, apiKey: key.key)
        client = newClient
        agent = Agent(
            config: config,
            service: service,
            client: newClient,
            memory: MemoryStore.loadRecovering(),
            confirm: { question in
                // The agent asks on a background executor; a modal alert has to run on main.
                var answer = false
                DispatchQueue.main.sync {
                    let alert = NSAlert()
                    alert.messageText = "确认写入"
                    alert.informativeText = question
                    alert.addButton(withTitle: "写入")
                    alert.addButton(withTitle: "取消")
                    answer = alert.runModal() == .alertFirstButtonReturn
                }
                return answer
            },
            emit: { [weak self] event in
                DispatchQueue.main.async { self?.handle(event) }
            }
        )
    }

    // MARK: - Turn handling

    func send(_ text: String? = nil) {
        let message = (text ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isBusy else { return }
        if text == nil { input = "" }

        guard let agent else {
            append(.error, "还没有配置 API Key，先在 Settings 里填一个。")
            showSettings = true
            return
        }
        append(.user, message)
        isBusy = true
        Task {
            do {
                try await agent.send(message)
            } catch {
                append(.error, "\(error)")
            }
            isBusy = false
            usageSummary = agent.cacheSummary
        }
    }

    func applyPendingPlan() {
        guard let plan = pendingPlan, !plan.items.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "写入 \(plan.items.count) 个事件"
        alert.informativeText = "写入日历「\(config.writeCalendar)」。随时可以用 Undo 撤销。"
        alert.addButton(withTitle: "写入")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let created = try PlanApplier.apply(
                plan: plan,
                config: config,
                service: service,
                source: "gui:apply"
            )
            pendingPlan = nil
            agent?.clearPendingPlan()
            append(.assistant, "已写入 \(created.count) 个事件到「\(created.first?.calendarName ?? config.writeCalendar)」。Command+Shift+Z 可以撤销。")
            Task { await reloadCalendar(force: true) }
        } catch {
            append(.error, "写入失败：\(error)")
        }
    }

    func discardPendingPlan() {
        pendingPlan = nil
        agent?.clearPendingPlan()
        append(.notice, "已放弃当前提案。")
    }

    func undoLastBatch() {
        let alert = NSAlert()
        alert.messageText = "撤销最近一次写入"
        alert.informativeText = "删除 CalPilot 上一批创建的事件。"
        alert.addButton(withTitle: "撤销")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            if let result = try PlanApplier.undo(config: config, service: service) {
                append(.assistant, "已撤销 \(result.removed) / \(result.attempted) 个事件。")
                for failure in result.failures { append(.error, failure) }
            } else {
                append(.notice, "没有可撤销的批次。")
            }
            Task { await reloadCalendar(force: true) }
        } catch {
            append(.error, "撤销失败：\(error)")
        }
    }

    func resetConversation() {
        agent?.reset()
        turns = []
        pendingPlan = nil
        append(.notice, "对话已清空（日历未改动）。")
        bootstrap()
    }

    // MARK: - Calendar snapshot

    @Published var upcoming: [EventDTO] = []

    func reloadCalendar(force: Bool = false) async {
        guard calendarReady else { return }
        if !force, let last = lastLoadedAt, Date().timeIntervalSince(last) < 5 { return }
        lastLoadedAt = Date()
        let calendar = config.calendar
        let start = Date()
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(604_800)
        upcoming = service.events(from: start, to: end).filter { !$0.isAllDay }
    }

    // MARK: - Settings

    func saveSettings(apiKey: String) {
        do {
            try ConfigStore.save(config)
            if !apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
                let account = Credentials.keychainAccount(forBaseURL: config.baseURL)
                try Keychain.write(service: Credentials.keychainService, account: account, value: apiKey)
            }
            rebuildAgent()
            append(.notice, "设置已保存。")
            Task { await reloadCalendar(force: true) }
        } catch {
            append(.error, "保存失败：\(error)")
        }
    }

    func addMemory(_ text: String, kind: MemoryEntry.Kind, pinned: Bool) {
        var store = MemoryStore.loadRecovering()
        guard store.add(text: text, kind: kind, pinned: pinned) != nil else { return }
        try? store.save()
        memoryEntries = store.entries
        rebuildAgent()
        append(.notice, "记住了：\(text)")
    }

    func removeMemory(id: String) {
        var store = MemoryStore.loadRecovering()
        _ = store.remove(idOrPrefix: id)
        try? store.save()
        memoryEntries = store.entries
        rebuildAgent()
    }

    func togglePin(id: String) {
        var store = MemoryStore.loadRecovering()
        guard let index = store.entries.firstIndex(where: { $0.id == id }) else { return }
        store.entries[index].pinned.toggle()
        try? store.save()
        memoryEntries = store.entries
        rebuildAgent()
    }

    // MARK: - Agent event rendering

    private func handle(_ event: Agent.Event) {
        switch event {
        case let .assistantText(text):
            append(.assistant, text)
        case let .toolCall(_, summary):
            append(.tool, summary)
        case let .toolResult(_, detail):
            append(.toolResult, detail)
        case let .planProposed(plan):
            pendingPlan = plan
        case let .planApplied(events):
            pendingPlan = nil
            append(.assistant, "已写入 \(events.count) 个事件。")
        case let .memoriesChanged(text):
            memoryEntries = MemoryStore.loadRecovering().entries
            append(.notice, text)
        case let .notice(text):
            append(.notice, text)
        }
    }

    private func append(_ kind: Turn.Kind, _ text: String) {
        turns.append(Turn(kind: kind, text: text))
    }
}
