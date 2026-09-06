import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store.shared
    lazy var client = SgxClient(store: store)
    let engine = PomodoroEngine()

    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?
    var currentRecord: SessionRecord?
    var serverTodayMinutes: Int?
    var serverTodayCount: Int?

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.onTick = { [weak self] phase, remaining in
            self?.updateStatusTitle(phase: phase, remaining: remaining)
        }
        engine.onFocusFinished = { [weak self] start, end, seconds in
            self?.handleFocusFinished(start: start, end: end, seconds: seconds)
        }
        engine.onRestFinished = { [weak self] in
            self?.handleRestFinished()
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusTitle(phase: .idle, remaining: 0)

        if store.config.mobile.isEmpty && store.config.token.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showSettings()
            }
        }
        refreshServerStats()
        Task {
            // 启动即拉取专注任务列表（已配置账号时），并补传离线记录
            if self.store.config.syncEnabled,
               !self.store.config.mobile.isEmpty || !self.store.config.token.isEmpty {
                _ = try? await self.client.repeatList()
            }
            await self.client.flushPending()
            self.refreshServerStats()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveHistory()
    }

    // MARK: - 状态栏标题

    private func mmss(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    func updateStatusTitle(phase: Phase, remaining: TimeInterval) {
        guard let button = statusItem?.button else { return }
        let text: String
        switch phase {
        case .idle:
            text = "🍅"
        case .focus:
            text = "\(engine.isPaused ? "⏸" : "🍅") \(mmss(remaining))"
        case .rest:
            text = "☕️ \(mmss(remaining))"
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        ]
        button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
    }

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func menuItem(_ title: String, _ action: Selector? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = action == nil ? nil : self
        return item
    }

    func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        let today = store.todaySessions()
        let localMinutes = today.reduce(0) { $0 + $1.seconds } / 60
        var summary = "今日本地：\(today.count) 个番茄 · \(localMinutes) 分钟"
        if let minutes = serverTodayMinutes {
            summary += "   |   时光序：\(minutes) 分钟 · \(serverTodayCount ?? 0) 次"
        }
        let info = menuItem(summary)
        info.isEnabled = false
        menu.addItem(info)

        menu.addItem(.separator())

        switch engine.phase {
        case .idle:
            let task = store.selectedTask()
            let minutes = (store.config.syncEnabled && task != nil) ? (task?.timeMinutes ?? store.config.focusMinutes) : store.config.focusMinutes
            let title = (store.config.syncEnabled && task != nil) ? "开始专注（\(task!.title) · \(minutes) 分钟）" : "开始专注（\(minutes) 分钟）"
            menu.addItem(menuItem(title, #selector(startFocus(_:))))
            let restMinutes = breakMinutes()
            menu.addItem(menuItem("开始休息（\(restMinutes) 分钟）", #selector(startRest(_:))))
        case .focus, .rest:
            menu.addItem(menuItem(engine.isPaused ? "继续" : "暂停", #selector(togglePause(_:))))
            menu.addItem(menuItem("放弃本次", #selector(stopTimer(_:))))
        }

        let pending = store.pendingCount()
        let syncTitle = pending > 0 ? "同步时光序（\(pending) 条待上传）" : "同步时光序"
        menu.addItem(menuItem(syncTitle, #selector(syncNow(_:))))

        menu.addItem(.separator())

        if !today.isEmpty {
            let header = menuItem("今日记录")
            header.isEnabled = false
            menu.addItem(header)
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            for session in today.reversed().prefix(5) {
                let mark = session.synced ? "✅" : "⏳"
                let row = menuItem("\(formatter.string(from: session.start)) – \(formatter.string(from: session.end)) · \(session.seconds / 60) 分钟 \(mark)")
                row.isEnabled = false
                menu.addItem(row)
            }
        }

        if !store.config.syncEnabled {
            let note = menuItem("同步已关闭（仅本地记录）")
            note.isEnabled = false
            menu.addItem(note)
        } else if store.config.mobile.isEmpty && store.config.token.isEmpty {
            let note = menuItem("未配置账号，点击「设置」填写")
            note.isEnabled = false
            menu.addItem(note)
        }

        menu.addItem(.separator())
        menu.addItem(menuItem("设置…", #selector(openSettings(_:)), key: ","))
        let quit = NSMenuItem(title: "退出时光番茄", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func breakMinutes() -> Int {
        if store.config.syncEnabled, let task = store.selectedTask(), task.focusType == 3, task.restTime > 0 {
            return task.restTime
        }
        return store.config.breakMinutes
    }

    // MARK: - 动作

    @objc func startFocus(_ sender: Any?) {
        let task = store.selectedTask()
        let useTask = store.config.syncEnabled && task != nil
        let minutes = useTask ? (task?.timeMinutes ?? store.config.focusMinutes) : store.config.focusMinutes
        let title = task?.title ?? "番茄钟"
        let repeatId = useTask ? (task?.id ?? "") : ""
        let focusType = task?.focusType ?? 3
        let focusNum = task?.focusNum ?? 0
        currentRecord = SessionRecord(
            start: Date(), end: Date(), seconds: minutes * 60,
            taskTitle: title, taskRepeatId: repeatId, focusType: focusType,
            fullTime: minutes, focusNum: focusNum,
            synced: repeatId.isEmpty || !store.config.syncEnabled
        )
        engine.startFocus(minutes: minutes)
    }

    @objc func startRest(_ sender: Any?) {
        engine.startRest(minutes: breakMinutes())
    }

    @objc func togglePause(_ sender: Any?) {
        if engine.isPaused {
            engine.resume()
        } else {
            engine.pause()
        }
    }

    @objc func stopTimer(_ sender: Any?) {
        engine.stop()
        currentRecord = nil
    }

    @objc func syncNow(_ sender: Any?) {
        Task {
            await self.client.flushPending(force: true)
            self.refreshServerStats()
        }
    }

    @objc func openSettings(_ sender: Any?) {
        showSettings()
    }

    // MARK: - 完成回调

    private func handleFocusFinished(start: Date, end: Date, seconds: Int) {
        if var record = currentRecord {
            record.start = start
            record.end = end
            record.seconds = seconds
            store.addSession(record)
        } else {
            let task = store.selectedTask()
            let useTask = store.config.syncEnabled && task != nil
            store.addSession(SessionRecord(
                start: start, end: end, seconds: seconds,
                taskTitle: task?.title ?? "番茄钟",
                taskRepeatId: useTask ? (task?.id ?? "") : "",
                focusType: task?.focusType ?? 3,
                fullTime: seconds / 60,
                focusNum: task?.focusNum ?? 0,
                synced: !useTask
            ))
        }
        currentRecord = nil

        if store.config.soundEnabled {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }
        Task {
            await self.client.flushPending()
            self.refreshServerStats()
        }

        if store.config.autoStartBreak {
            engine.startRest(minutes: breakMinutes())
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            let alert = NSAlert()
            alert.messageText = "🍅 番茄完成！"
            alert.informativeText = "专注 \(seconds / 60) 分钟（\(formatter.string(from: start)) – \(formatter.string(from: end))），已记录。"
            alert.addButton(withTitle: "开始休息")
            alert.addButton(withTitle: "好的")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                engine.startRest(minutes: breakMinutes())
            }
        }
    }

    private func handleRestFinished() {
        if store.config.soundEnabled {
            NSSound(named: NSSound.Name("Ping"))?.play()
        }
        let alert = NSAlert()
        alert.messageText = "☕️ 休息结束"
        alert.informativeText = "准备好开始下一个番茄了吗？"
        alert.addButton(withTitle: "开始专注")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            engine.startFocus(minutes: focusMinutesForStart())
        }
    }

    private func focusMinutesForStart() -> Int {
        let task = store.selectedTask()
        if store.config.syncEnabled && task != nil {
            return task?.timeMinutes ?? store.config.focusMinutes
        }
        return store.config.focusMinutes
    }

    // MARK: - 服务端统计

    func refreshServerStats() {
        guard store.config.syncEnabled,
              !store.config.mobile.isEmpty || !store.config.token.isEmpty else { return }
        Task {
            do {
                let stats = try await self.client.fetchTodayStats()
                self.serverTodayMinutes = stats.minutes
                self.serverTodayCount = stats.count
            } catch {
                // 静默失败：菜单里继续显示本地统计
            }
        }
    }

    // MARK: - 设置窗口

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "时光番茄 · 设置"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(onSaved: { [weak self] in
                guard let self = self else { return }
                self.rebuildMenu()
                if self.store.config.syncEnabled {
                    Task {
                        await self.client.flushPending(force: true)
                        self.refreshServerStats()
                    }
                }
            }))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
