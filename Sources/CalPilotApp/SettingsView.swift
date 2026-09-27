import CalPilotCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey = ""
    @State private var newMemory = ""
    @State private var newMemoryKind: MemoryEntry.Kind = .preference
    @State private var newMemoryPinned = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置").font(.headline)
                Spacer()
                Button("完成") {
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

                Section("排程偏好") {
                    TextField("写入日历", text: $model.config.writeCalendar)
                    HStack {
                        TextField("上班", text: $model.config.workDayStart)
                            .frame(width: 70)
                        Text("–")
                        TextField("下班", text: $model.config.workDayEnd)
                            .frame(width: 70)
                        TextField("午休", text: Binding(
                            get: { model.config.lunchBreak ?? "" },
                            set: { model.config.lunchBreak = $0.isEmpty ? nil : $0 }
                        ))
                        .frame(width: 110)
                    }
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
        .frame(width: 560, height: 560)
    }
}
