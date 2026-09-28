import AppKit
import CalPilotCore
import EventKit
import Foundation
import SwiftUI

/// Which window the right-hand sidebar is showing.
enum SidebarMode: String, CaseIterable, Identifiable {
    case upcoming
    case past

    var id: String { rawValue }
    var label: String { self == .upcoming ? "未来" : "过去" }
}

@MainActor
final class AppModel: ObservableObject {
    // Conversation
    @Published var turns: [ChatTurn] = []
    @Published var input: String = ""
    @Published var isBusy = false
    @Published var sessionTitle: String = "新对话"
    @Published var sessions: [SessionSummary] = []

    // Calendar state
    @Published var calendarStatus: String = "checking…"
    @Published var calendarReady = false

    // Sidebar
    @Published var sidebarMode: SidebarMode = .upcoming
    @Published var historyDays = 30
    @Published var upcoming: [EventDTO] = []
    @Published var analysis: CalendarAnalysis?

    // Model / plan state
    @Published var config: AppConfig
    @Published var pendingPlan: Plan?
    @Published var memoryEntries: [MemoryEntry] = []
    @Published var usageSummary: String = ""
    @Published var showSettings = false

    private var service = CalendarService()
    private var agent: Agent?
    private var session = ChatSession()
    private var lastCalendarLoad: Date?
    private var lastHistoryLoad: Date?

    init() {
        self.config = (try? ConfigStore.loadOrCreate()) ?? AppConfig()
        self.memoryEntries = MemoryStore.loadRecovering().entries
        // Pick up where the last conversation left off.
        if let recent = SessionStore.mostRecent() {
            self.session = recent
            self.turns = recent.turns
            self.sessionTitle = recent.title
            self.pendingPlan = recent.agent.pendingPlan
        }
        self.sessions = SessionStore.list()
        bootstrap()
    }

    var currentSessionID: UUID { session.id }

    // MARK: - Bootstrap

    private func bootstrap() {
        for warning in config.schedulingWarnings {
            append(.error, warning)
        }
        if Credentials.resolveAPIKey(config: config) == nil {
            append(.notice, "还没有配置 API Key。点右上角 Settings 填入，CalPilot 才能调用语言模型。")
            append(.notice, "日历读取和分析不需要 Key，右边就能看。")
        } else if turns.isEmpty {
            append(.assistant, "我是 CalPilot。告诉我这周想怎么安排，或者问我过去一段时间的时间都花在哪了。")
        }
        connect()
    }

    private func connect() {
        Task {
            do {
                let granted = try await service.requestFullAccess()
                calendarReady = granted
                if granted {
                    calendarStatus = "\(service.calendarDTOs().count) 个日历可读"
                    rebuildAgent()
                    await reloadCalendar(force: true)
                    await reloadHistory(force: true)
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

    private func rebuildAgent(restoring state: Agent.State? = nil) {
        // Carry the live transcript across the rebuild; falling back to the stored session
        // is what makes a restart resume rather than start over.
        let carry = state ?? agent?.exportState() ?? session.agent
        guard let key = Credentials.resolveAPIKey(config: config) else {
            agent = nil
            return
        }
        let client = LLMClient(config: config, apiKey: key.key)
        let newAgent = Agent(
            config: config,
            service: service,
            client: client,
            memory: MemoryStore.loadRecovering(),
            confirm: { question in
                // The agent asks from a background executor; a modal alert must run on main.
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
        newAgent.restore(carry)
        agent = newAgent
        pendingPlan = carry.pendingPlan
        usageSummary = newAgent.cacheSummary
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
            persist()
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
            persist()
            Task {
                await reloadCalendar(force: true)
                await reloadHistory(force: true)
            }
        } catch {
            append(.error, "写入失败：\(error)")
        }
    }

    func discardPendingPlan() {
        pendingPlan = nil
        agent?.clearPendingPlan()
        append(.notice, "已放弃当前提案。")
        persist()
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
            persist()
            Task {
                await reloadCalendar(force: true)
                await reloadHistory(force: true)
            }
        } catch {
            append(.error, "撤销失败：\(error)")
        }
    }

    // MARK: - Sessions

    /// Writes the visible turns plus the model transcript to disk.
    private func persist() {
        session.turns = turns
        session.updatedAt = Date()
        if let agent { session.agent = agent.exportState() }
        if !session.titleIsManual {
            session.title = ChatSession.suggestedTitle(from: turns)
        }
        sessionTitle = session.title
        do {
            try SessionStore.save(session)
        } catch {
            append(.error, "对话保存失败：\(error)")
        }
        sessions = SessionStore.list()
    }

    func newSession() {
        persist()
        session = ChatSession()
        turns = []
        pendingPlan = nil
        sessionTitle = session.title
        rebuildAgent(restoring: Agent.State())
        append(.assistant, "新对话。想安排点什么？")
        usageSummary = ""
        persist()
    }

    func openSession(id: UUID) {
        guard id != session.id else { return }
        persist()
        guard let loaded = SessionStore.load(id: id) else { return }
        session = loaded
        turns = loaded.turns
        sessionTitle = loaded.title
        rebuildAgent(restoring: loaded.agent)
        pendingPlan = loaded.agent.pendingPlan
    }

    func deleteSession(id: UUID) {
        let title = sessions.first { $0.id == id }?.title ?? "这个对话"
        let alert = NSAlert()
        alert.messageText = "删除「\(title)」"
        alert.informativeText = "只删除保存的对话记录，不影响日历。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try SessionStore.delete(id: id)
        } catch {
            append(.error, "删除失败：\(error)")
        }
        if id == session.id {
            newSession()
        } else {
            sessions = SessionStore.list()
        }
    }

    func renameCurrentSession() {
        let alert = NSAlert()
        alert.messageText = "重命名对话"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = sessionTitle
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        session.title = name
        session.titleIsManual = true
        sessionTitle = name
        persist()
    }

    // MARK: - Calendar snapshots

    func reloadCalendar(force: Bool = false) async {
        guard calendarReady else { return }
        if !force, let last = lastCalendarLoad, Date().timeIntervalSince(last) < 5 { return }
        lastCalendarLoad = Date()
        let calendar = config.calendar
        let start = Date()
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(604_800)
        upcoming = service.events(from: start, to: end).filter { !$0.isAllDay }
    }

    func reloadHistory(force: Bool = false) async {
        guard calendarReady else { return }
        if !force, let last = lastHistoryLoad, Date().timeIntervalSince(last) < 30 { return }
        lastHistoryLoad = Date()
        let calendar = config.calendar
        let end = Date()
        let start = calendar.date(byAdding: .day, value: -historyDays, to: end)
            ?? end.addingTimeInterval(-Double(historyDays) * 86_400)
        let events = service.events(from: start, to: end)
        analysis = CalendarAnalyzer.analyze(events: events, config: config, rangeStart: start, rangeEnd: end)
    }

    func setHistoryDays(_ days: Int) {
        historyDays = days
        Task { await reloadHistory(force: true) }
    }

    func setSidebarMode(_ mode: SidebarMode) {
        sidebarMode = mode
        Task {
            if mode == .past {
                await reloadHistory(force: true)
            } else {
                await reloadCalendar(force: true)
            }
        }
    }

    // MARK: - Settings & memory

    func saveSettings(apiKey: String) {
        do {
            try ConfigStore.save(config)
            if !apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
                let account = Credentials.keychainAccount(forBaseURL: config.baseURL)
                try Keychain.write(service: Credentials.keychainService, account: account, value: apiKey)
            }
            rebuildAgent()
            append(.notice, "设置已保存。")
            persist()
            Task {
                await reloadCalendar(force: true)
                await reloadHistory(force: true)
            }
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
        persist()
    }

    func removeMemory(id: String) {
        var store = MemoryStore.loadRecovering()
        _ = store.remove(idOrPrefix: id)
        try? store.save()
        memoryEntries = store.entries
        rebuildAgent()
        persist()
    }

    func togglePin(id: String) {
        var store = MemoryStore.loadRecovering()
        guard let index = store.entries.firstIndex(where: { $0.id == id }) else { return }
        store.entries[index].pinned.toggle()
        try? store.save()
        memoryEntries = store.entries
        rebuildAgent()
        persist()
    }

    // MARK: - Agent events

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
            let titles = plan.items.map { $0.title }.joined(separator: "、")
            append(.notice, "提案 \(plan.items.count) 个事件：\(titles)")
        case let .planApplied(events):
            pendingPlan = nil
            append(.notice, "已写入 \(events.count) 个事件。")
        case let .memoriesChanged(text):
            memoryEntries = MemoryStore.loadRecovering().entries
            append(.notice, text)
        case let .notice(text):
            append(.notice, text)
        }
    }

    private func append(_ kind: ChatTurn.Kind, _ text: String) {
        turns.append(ChatTurn(kind: kind, text: text))
    }
}
