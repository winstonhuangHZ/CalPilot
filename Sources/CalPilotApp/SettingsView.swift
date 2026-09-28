import CalPilotCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey = ""
    @State private var rules: [ScheduleRule] = []
    @State private var newMemory = ""
    @State private var newMemoryKind: MemoryEntry.Kind = .preference
    @State private var newMemoryPinned = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置").font(.headline)
                Spacer()
                Button("完成") {
                    model.config.schedule = rules
                    model.saveSettings(apiKey: apiKey)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()

            Form {
                Section("语言模型") {
                    TextField("Base URL", text: $model.config.baseURL)
                    TextField("Model", text: $model.config.model)
                    SecureField("API Key（留空则沿用 Keychain 里的）", text: $apiKey)
                    Text("Key 存在登录钥匙串，不写进配置文件。任何 OpenAI 兼容端点都可以。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScheduleSection(rules: $rules)

                Section("排程偏好") {
                    TextField("写入日历", text: $model.config.writeCalendar)
                    Stepper("事件间隔 \(model.config.bufferMinutes) 分钟",
                            value: $model.config.bufferMinutes, in: 0...60, step: 5)
                    Stepper("每天最多 \(model.config.maxEventsPerDay) 个新事件",
                            value: $model.config.maxEventsPerDay, in: 1...12)
                    Stepper("默认时长 \(model.config.defaultEventMinutes) 分钟",
                            value: $model.config.defaultEventMinutes, in: 15...240, step: 15)
                }

                Section("记忆块") {
                    ForEach(model.memoryEntries) { entry in
                        HStack(spacing: 8) {
                            Button {
                                model.togglePin(id: entry.id)
                            } label: {
                                Image(systemName: entry.pinned ? "pin.fill" : "pin")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.borderless)
                            .help(entry.pinned ? "取消置顶" : "置顶（始终进入提示词）")

                            Text(entry.text).font(.system(size: 12))
                            Spacer()
                            Text(entry.kind.rawValue)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Button {
                                model.removeMemory(id: entry.id)
                            } label: {
                                Image(systemName: "trash").font(.system(size: 11))
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    HStack(spacing: 6) {
                        TextField("例如：上午做深度工作，不要排会议", text: $newMemory)
                        Picker("", selection: $newMemoryKind) {
                            ForEach(MemoryEntry.Kind.allCases, id: \.self) { kind in
                                Text(kind.rawValue).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        Toggle("置顶", isOn: $newMemoryPinned)
                            .toggleStyle(.checkbox)
                        Button("添加") {
                            let text = newMemory.trimmingCharacters(in: .whitespaces)
                            guard !text.isEmpty else { return }
                            model.addMemory(text, kind: newMemoryKind, pinned: newMemoryPinned)
                            newMemory = ""
                            newMemoryPinned = false
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 620, height: 640)
        .onAppear {
            // Materialise the legacy single window so the editor has something to edit.
            rules = model.config.effectiveSchedule
        }
    }
}

// MARK: - Availability editor

/// Edits the hours CalPilot may schedule into.
///
/// One window plus a lunch break only fits a nine-to-five week. This editor is grouped by
/// weekday so a late-finishing school day and a weekend that starts later are both
/// expressible, and each rule can carry several breaks.
private struct ScheduleSection: View {
    @Binding var rules: [ScheduleRule]

    private static let tinyLabels = [1: "日", 2: "一", 3: "二", 4: "三", 5: "四", 6: "五", 7: "六"]

    var body: some View {
        Section("可安排时段") {
            if rules.isEmpty {
                Text("还没有规则，按 09:00–18:00 处理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 3) {
                        ForEach(1...7, id: \.self) { day in
                            Toggle(Self.tinyLabels[day] ?? "?", isOn: dayBinding(index, day))
                                .toggleStyle(.button)
                                .controlSize(.small)
                        }
                        Spacer()
                        Text(rule.days.isEmpty ? "每天" : "")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Button {
                            rules.remove(at: index)
                        } label: {
                            Image(systemName: "trash").font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                    }

                    HStack(spacing: 6) {
                        TextField("07:40", text: $rules[index].start)
                            .frame(width: 64)
                        Text("–")
                        TextField("21:00", text: $rules[index].end)
                            .frame(width: 64)
                        TextField("休息 11:40-12:30, 17:00-18:00", text: breaksBinding(index))
                    }
                    .font(.system(size: 12))

                    if let range = Format.parseClockRange("\(rule.start)-\(rule.end)"),
                       range.end.0 * 60 + range.end.1 <= range.start.0 * 60 + range.start.1 {
                        Text("结束时间需要晚于开始时间，这条会被跳过。")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 2)
            }

            HStack {
                Button("+ 添加时段") {
                    rules.append(ScheduleRule(days: [2, 3, 4, 5, 6], start: "09:00", end: "18:00"))
                }
                Spacer()
                if rules.count > 1 {
                    Button("合并为一条") {
                        let days = Array(Set(rules.flatMap { $0.days })).sorted()
                        if let first = rules.first {
                            rules = [ScheduleRule(days: days, start: first.start, end: first.end, breaks: first.breaks)]
                        }
                    }
                    .font(.system(size: 11))
                }
            }

            Text("按星期分组，工作日和周末可以不一样；规则取并集，每条规则里的休息时间会被扣掉。全部不选＝每天。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func dayBinding(_ index: Int, _ day: Int) -> Binding<Bool> {
        Binding(
            get: { rules.indices.contains(index) && rules[index].days.contains(day) },
            set: { isOn in
                guard rules.indices.contains(index) else { return }
                if isOn {
                    if !rules[index].days.contains(day) {
                        rules[index].days.append(day)
                        rules[index].days.sort()
                    }
                } else {
                    rules[index].days.removeAll { $0 == day }
                }
            }
        )
    }

    private func breaksBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { rules.indices.contains(index) ? rules[index].breaks.joined(separator: ", ") : "" },
            set: { text in
                guard rules.indices.contains(index) else { return }
                rules[index].breaks = text
                    .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }
}
