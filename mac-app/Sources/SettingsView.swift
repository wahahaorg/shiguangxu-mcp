import SwiftUI
import AppKit

struct SettingsView: View {
    var onSaved: () -> Void

    @State private var apiBase: String
    @State private var mobile: String
    @State private var password: String
    @State private var selectedRepeatId: String
    @State private var focusMinutes: Int
    @State private var breakMinutes: Int
    @State private var autoStartBreak: Bool
    @State private var syncEnabled: Bool
    @State private var soundEnabled: Bool

    @State private var tasks: [FocusTask]
    @State private var loadingTasks = false
    @State private var testing = false
    @State private var testMessage: String?
    @State private var tasksMessage: String?

    private let store = Store.shared
    private let client = SgxClient(store: .shared)

    init(onSaved: @escaping () -> Void) {
        let config = Store.shared.config
        self.onSaved = onSaved
        _apiBase = State(initialValue: config.apiBase)
        _mobile = State(initialValue: config.mobile)
        _password = State(initialValue: config.password)
        _selectedRepeatId = State(initialValue: config.selectedRepeatId)
        _focusMinutes = State(initialValue: config.focusMinutes)
        _breakMinutes = State(initialValue: config.breakMinutes)
        _autoStartBreak = State(initialValue: config.autoStartBreak)
        _syncEnabled = State(initialValue: config.syncEnabled)
        _soundEnabled = State(initialValue: config.soundEnabled)
        _tasks = State(initialValue: Store.shared.tasks)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox(label: Label("时光序账号", systemImage: "person.crop.circle")) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("手机号", text: $mobile)
                        SecureField("密码", text: $password)
                        TextField("API 地址", text: $apiBase)
                        HStack {
                            Button(testing ? "测试中…" : "测试连接") { testConnection() }
                                .disabled(testing)
                            if let message = testMessage {
                                Text(message)
                                    .font(.footnote)
                                    .foregroundColor(message.hasPrefix("✅") ? .green : .red)
                                    .lineLimit(2)
                            }
                        }
                        Text("密码以明文直连时光序官方接口（与 shiguangxu-mcp 一致），仅保存在本机 ~/Library/Application Support/ShiguangTomato/config.json")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(6)
                }

                GroupBox(label: Label("专注任务（时光序 · 番茄专注）", systemImage: "timer")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Picker("同步到", selection: $selectedRepeatId) {
                                Text("（不关联，仅本地记录）").tag("")
                                ForEach(tasks) { task in
                                    Text("\(task.title) · \(task.typeLabel) \(task.timeMinutes) 分钟").tag(task.id)
                                }
                            }
                            Button(loadingTasks ? "拉取中…" : "刷新任务列表") { loadTasks() }
                                .disabled(loadingTasks)
                        }
                        if let message = tasksMessage {
                            Text(message).font(.footnote).foregroundColor(message.hasPrefix("✅") ? .green : .red)
                        }
                        Text("完成的番茄会以原生「专注记录」写入所选任务，在时光序 App/网页的「番茄专注」里可见（含统计）。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Toggle("启用同步到时光序", isOn: $syncEnabled)
                    }
                    .padding(6)
                }

                GroupBox(label: Label("计时", systemImage: "clock")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Stepper("默认专注时长：\(focusMinutes) 分钟", value: $focusMinutes, in: 5...180, step: 5)
                        Text("未关联任务或关闭同步时使用此时长；已关联任务时使用任务自身的时长。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Stepper("休息时长：\(breakMinutes) 分钟", value: $breakMinutes, in: 1...60, step: 1)
                        Toggle("专注结束后自动开始休息", isOn: $autoStartBreak)
                        Toggle("完成时播放提示音", isOn: $soundEnabled)
                    }
                    .padding(6)
                }

                HStack {
                    Spacer()
                    Button("取消") { closeWindow() }
                    Button("保存") { save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 480, height: 620)
        .onAppear {
            if tasks.isEmpty && !mobile.isEmpty {
                loadTasks()
            }
        }
    }

    private func testConnection() {
        testing = true
        testMessage = nil
        Task {
            do {
                let found = try await SgxClient.probe(apiBase: apiBase, mobile: mobile, password: password)
                await MainActor.run {
                    self.testing = false
                    self.testMessage = "✅ 连接成功，专注任务 \(found.count) 个"
                    self.tasks = found
                    self.tasksMessage = nil
                }
            } catch {
                await MainActor.run {
                    self.testing = false
                    self.testMessage = "❌ \(error.localizedDescription)"
                }
            }
        }
    }

    private func loadTasks() {
        loadingTasks = true
        tasksMessage = nil
        Task {
            do {
                // 若尚未登录（token 为空），先登录
                if store.config.token.isEmpty || mobile != store.config.mobile {
                    store.updateConfig {
                        $0.mobile = mobile.trimmingCharacters(in: .whitespaces)
                        $0.password = password
                        $0.apiBase = apiBase
                    }
                }
                let found = try await client.repeatList()
                await MainActor.run {
                    self.loadingTasks = false
                    self.tasks = found
                    self.tasksMessage = "✅ 已拉取 \(found.count) 个任务"
                }
            } catch {
                await MainActor.run {
                    self.loadingTasks = false
                    self.tasksMessage = "❌ \(error.localizedDescription)"
                }
            }
        }
    }

    private func save() {
        store.updateConfig {
            $0.apiBase = apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.mobile = mobile.trimmingCharacters(in: .whitespaces)
            $0.password = password
            $0.selectedRepeatId = selectedRepeatId
            $0.focusMinutes = focusMinutes
            $0.breakMinutes = breakMinutes
            $0.autoStartBreak = autoStartBreak
            $0.syncEnabled = syncEnabled
            $0.soundEnabled = soundEnabled
        }
        onSaved()
        closeWindow()
    }

    private func closeWindow() {
        NSApp.keyWindow?.close()
    }
}
