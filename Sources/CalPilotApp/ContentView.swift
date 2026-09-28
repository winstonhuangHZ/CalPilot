import CalPilotCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            StatusBar()
            Divider()

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    TranscriptView()
                    if let plan = model.pendingPlan {
                        Divider()
                        PlanCardView(plan: plan)
                    }
                    Divider()
                    InputBar(focused: $inputFocused)
                }
                Divider()
                SidebarView()
                    .frame(width: 272)
            }
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
                .environmentObject(model)
        }
        .onAppear { inputFocused = true }
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(.tint)

            Menu {
                Button("新建对话") { model.newSession() }
                Button("重命名当前对话…") { model.renameCurrentSession() }
                Button("删除当前对话…") { model.deleteSession(id: model.currentSessionID) }
                if !model.sessions.isEmpty {
                    Divider()
                }
                ForEach(model.sessions) { session in
                    Button {
                        model.openSession(id: session.id)
                    } label: {
                        Text("\(session.id == model.currentSessionID ? "✓ " : "")\(session.title)  ·  \(session.messageCount) 条")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(model.sessionTitle).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
                .font(.headline)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("切换、重命名或删除对话")

            Circle()
                .fill(model.calendarReady ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(model.calendarStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !model.usageSummary.isEmpty {
                Text(model.usageSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
            }
            Button {
                model.undoLastBatch()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help("撤销最近一次写入")
            Button {
                model.showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .help("设置")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Transcript

private struct TranscriptView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.turns) { turn in
                        TurnRow(turn: turn)
                            .id(turn.id)
                    }
                    if model.isBusy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("思考中…").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 2)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.turns.count) {
                guard let last = model.turns.last else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct TurnRow: View {
    let turn: ChatTurn

    var body: some View {
        switch turn.kind {
        case .user:
            HStack(alignment: .top, spacing: 8) {
                Spacer(minLength: 60)
                Text(turn.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
            }

        case .assistant:
            Text(turn.text)
                .textSelection(.enabled)
                .font(.system(size: 13))
                .padding(.trailing, 60)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .tool:
            Label(turn.text, systemImage: "wrench.and.screwdriver")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

        case .toolResult:
            Text("↳ \(turn.text)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.leading, 14)

        case .notice:
            Text(turn.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

        case .error:
            Label(turn.text, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Plan card

private struct PlanCardView: View {
    @EnvironmentObject private var model: AppModel
    let plan: Plan

    private var calendar: Calendar { model.config.calendar }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("当前提案 · \(plan.items.count) 个事件", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                if plan.items.contains(where: { $0.adjustedFrom != nil }) {
                    Text("· 已自动避开冲突")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("放弃") { model.discardPendingPlan() }
                Button("写入日历") { model.applyPendingPlan() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }

            if !plan.summary.isEmpty {
                Text(plan.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(plan.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Format.day(item.start, calendar: calendar))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text("\(Format.clock(item.start, calendar: calendar))–\(Format.clock(item.end, calendar: calendar))")
                                .font(.system(size: 11, design: .monospaced))
                            Text(Format.duration(minutes: item.minutes))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .leading)
                            Text(item.title).font(.system(size: 12))
                            if item.adjustedFrom != nil {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.orange)
                                    .help(item.adjustmentNote ?? "已调整时间")
                            }
                            Spacer()
                            if let reason = item.reason, !reason.isEmpty {
                                Text(reason)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 150)

            if !plan.unscheduled.isEmpty {
                Text("放不下：" + plan.unscheduled.map { "\($0.title)（\($0.reason)）" }.joined(separator: "、"))
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.07))
    }
}

// MARK: - Input

private struct InputBar: View {
    @EnvironmentObject private var model: AppModel
    var focused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                quick("帮我把这周安排一下", icon: "wand.and.stars")
                quick("我上个月时间都花哪了", icon: "chart.bar")
                quick("这周有哪些空闲时间", icon: "clock")
                Spacer()
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("告诉 CalPilot 你想怎么安排…", text: $model.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused(focused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    .onSubmit { model.send() }

                Button {
                    model.send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                }
                .buttonStyle(.borderless)
                .disabled(model.isBusy || model.input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
    }

    private func quick(_ text: String, icon: String) -> some View {
        Button {
            model.send(text)
        } label: {
            Label(text, systemImage: icon)
                .font(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(model.isBusy)
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: Binding(
                get: { model.sidebarMode },
                set: { model.setSidebarMode($0) }
            )) {
                ForEach(SidebarMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            switch model.sidebarMode {
            case .upcoming: UpcomingList()
            case .past: HistoryPanel()
            }

            Divider()
            VStack(alignment: .leading, spacing: 3) {
                Text("记忆块 · \(model.memoryEntries.count) 条").font(.caption).bold()
                Text("写入目标：\(model.config.writeCalendar)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct UpcomingList: View {
    @EnvironmentObject private var model: AppModel

    private var calendar: Calendar { model.config.calendar }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("未来 7 天").font(.caption).bold()
                Spacer()
                Button {
                    Task { await model.reloadCalendar(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if model.upcoming.isEmpty {
                        Text(model.calendarReady ? "没有日程" : "未授权日历")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                    }
                    ForEach(model.upcoming) { event in
                        EventRow(event: event, calendar: calendar)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

private struct HistoryPanel: View {
    @EnvironmentObject private var model: AppModel

    private var calendar: Calendar { model.config.calendar }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("", selection: Binding(
                    get: { model.historyDays },
                    set: { model.setHistoryDays($0) }
                )) {
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Spacer()
                Button {
                    Task { await model.reloadHistory(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let analysis = model.analysis {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(analysis.summaryLines, id: \.self) { line in
                                Text(line).font(.system(size: 11))
                            }
                        }

                        if !analysis.byCalendar.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("按日历").font(.caption).bold()
                                ForEach(analysis.byCalendar.prefix(6), id: \.calendarName) { share in
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(share.calendarName)
                                                .font(.system(size: 11))
                                                .lineLimit(1)
                                            Spacer()
                                            Text(Format.hours(share.hours))
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }
                                        ProgressView(value: min(1, max(0, share.share)))
                                            .controlSize(.small)
                                    }
                                }
                            }
                        }

                        if !analysis.busiestDays.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("最忙的几天").font(.caption).bold()
                                ForEach(analysis.busiestDays.prefix(4), id: \.date) { day in
                                    HStack(spacing: 6) {
                                        Text(Format.day(day.date, calendar: calendar))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        Text(Format.weekdayLabel(day.weekday))
                                            .font(.system(size: 10))
                                        Spacer()
                                        Text(Format.hours(day.hours))
                                            .font(.system(size: 10, design: .monospaced))
                                    }
                                }
                            }
                        }

                        if !analysis.notes.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("观察").font(.caption).bold()
                                ForEach(analysis.notes, id: \.self) { note in
                                    Text("· " + note)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    } else {
                        Text(model.calendarReady ? "计算中…" : "未授权日历")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct EventRow: View {
    let event: EventDTO
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(event.title)
                .font(.system(size: 12))
                .lineLimit(2)
            HStack(spacing: 4) {
                Text(Format.day(event.start, calendar: calendar))
                Text("\(Format.clock(event.start, calendar: calendar))–\(Format.clock(event.end, calendar: calendar))")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            Text(event.calendarName)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}
