import AppKit
import ServiceManagement
import NotificationCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let overlays = OverlayController()
    private let worker = DispatchQueue(label: "notification.sources", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var database: NotificationDatabase?
    private var databaseStatus = "系统通知：正在连接"
    private var hookStatus = "Codex：等待 hook 事件"
    private var setupWindow: NSWindow?
    private var healthLabel: NSTextField?
    private var recent: [Notice] = []
    private var isScreenLocked = false
    private var isScreenAsleep = false
    private var isSessionInactive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Artwork.menu()
        statusItem.button?.toolTip = "Notification · 多屏通知"
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
        overlays.hideBody = UserDefaults.standard.bool(forKey: "hideBody")
        overlays.onChange = { [weak self] in self?.updateBadge() }
        observeSession()
        startSources()
        if !UserDefaults.standard.bool(forKey: "didShowSetup") {
            showSetup()
            UserDefaults.standard.set(true, forKey: "didShowSetup")
        }
        if ProcessInfo.processInfo.arguments.contains("--demo") { demo() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSetup()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { timer?.cancel() }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(menu, "Notification  ·  实验版本", enabled: false)
        add(menu, databaseStatus, enabled: false)
        add(menu, hookStatus, enabled: false)
        add(menu, "\(NSScreen.screens.count) 个屏幕 · \(overlays.pendingCount) 条待处理", enabled: false)
        if overlays.dropped > 0 { add(menu, "通知过多：已略过 \(overlays.dropped) 条排队提醒", enabled: false) }
        menu.addItem(.separator())
        add(menu, "显示测试通知", action: #selector(demo))
        add(menu, "显示人工介入测试", action: #selector(demoHITL))
        add(menu, overlays.paused ? "恢复浮层提示" : "暂停浮层提示", action: #selector(togglePause))
        add(menu, "清除当前浮层", action: #selector(clear))
        menu.addItem(.separator())
        let history = NSMenuItem(title: "最近提醒（仅保存在内存）", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if recent.isEmpty { add(submenu, "暂无提醒", enabled: false) }
        for notice in recent.prefix(20) {
            let title = overlays.hideBody ? notice.source : "\(notice.source) · \(notice.title)"
            let item = NSMenuItem(title: String(title.prefix(65)), action: #selector(replay(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = notice; submenu.addItem(item)
        }
        history.submenu = submenu; menu.addItem(history)
        add(menu, overlays.hideBody ? "显示通知内容" : "隐藏通知内容", action: #selector(togglePrivacy))
        let login = add(menu, "登录时启动", action: #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        add(menu, "设置与接入说明…", action: #selector(showSetup))
        menu.addItem(.separator())
        add(menu, "退出 Notification", action: #selector(quit), key: "q")
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, action: Selector? = nil, key: String = "", enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; item.isEnabled = enabled; menu.addItem(item); return item
    }

    private func startSources() {
        let fixture = ProcessInfo.processInfo.environment["NOTIFICATION_TEST_DATABASE"]
        let paths = fixture.map { [URL(fileURLWithPath: $0)] } ?? NotificationDatabase.candidates()
        let path = paths.first { FileManager.default.fileExists(atPath: $0.path) } ?? paths[0]
        database = NotificationDatabase(path: path)
        var nextAttempt = Date.distantPast
        var retryDelay: TimeInterval = 1
        var latestStatus = "系统通知：正在连接"
        timer = DispatchSource.makeTimerSource(queue: worker)
        timer?.schedule(deadline: .now(), repeating: 1)
        timer?.setEventHandler { [weak self] in
            guard let self else { return }
            let events = EventInbox.drain()
            var incoming: [Notice] = []
            if Date() >= nextAttempt {
                do {
                    incoming = try self.database?.poll() ?? []
                    latestStatus = "系统通知：监听中（实验性）"; retryDelay = 1
                } catch {
                    let reason = error.localizedDescription.lowercased()
                    if reason.contains("authoriz") || reason.contains("permission") || reason.contains("not permitted") || reason.contains("unable to open") {
                        latestStatus = "系统通知：需要完全磁盘访问"
                    } else { latestStatus = "系统通知：读取失败，请检查版本或权限" }
                    retryDelay = min(30, retryDelay * 2)
                }
                nextAttempt = Date().addingTimeInterval(retryDelay)
            }
            let status = latestStatus
            DispatchQueue.main.async {
                self.databaseStatus = status
                for notice in incoming { self.receive(notice) }
                for event in events { self.handle(event) }
                self.updateBadge()
            }
        }
        timer?.resume()
    }

    private func receive(_ raw: Notice) {
        var notice = raw
        if let bundle = notice.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            notice.source = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        recent.insert(notice, at: 0)
        if recent.count > 50 { recent.removeLast(recent.count - 50) }
        overlays.show(notice)
    }

    private func handle(_ event: HookEvent) {
        hookStatus = "Codex：已收到 hook 事件"
        switch event.action {
        case .show: if let notice = event.notice { receive(notice) }
        case .resolve: overlays.resolve(id: event.key)
        case .clearSession: overlays.clear(session: event.sessionID)
        }
    }

    private func updateBadge() {
        let title = overlays.paused ? "Ⅱ" : (overlays.pendingCount > 0 ? " \(overlays.pendingCount)" : "")
        let hint = "Notification\n\(databaseStatus)\n\(hookStatus)"
        if statusItem.button?.title != title { statusItem.button?.title = title }
        if statusItem.button?.toolTip != hint { statusItem.button?.toolTip = hint }
        let health = "\(databaseStatus)\n\(hookStatus) · \(NSScreen.screens.count) 个屏幕"
        if healthLabel?.stringValue != health { healthLabel?.stringValue = health }
    }

    private func observeSession() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isSessionInactive = true; self?.updateVisibility()
        }
        center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isSessionInactive = false; self?.updateVisibility()
        }
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isScreenAsleep = true; self?.updateVisibility()
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isScreenAsleep = false; self?.updateVisibility()
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenLocked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenUnlocked), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    private func updateVisibility() { overlays.locked = isScreenLocked || isScreenAsleep || isSessionInactive }
    @objc private func screenLocked() { isScreenLocked = true; updateVisibility() }
    @objc private func screenUnlocked() { isScreenLocked = false; updateVisibility() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func clear() { overlays.clear() }
    @objc private func togglePause() { overlays.paused.toggle(); updateBadge() }
    @objc private func togglePrivacy() {
        overlays.hideBody.toggle(); UserDefaults.standard.set(overlays.hideBody, forKey: "hideBody")
    }
    @objc private func replay(_ sender: NSMenuItem) { if let notice = sender.representedObject as? Notice { overlays.show(notice) } }
    @objc func demo() {
        receive(Notice(source: "Notification", title: "每一块屏幕，都能看见", body: "通知会同步显示在所有屏幕上方，不打断当前输入。"))
    }
    @objc private func demoHITL() {
        receive(Notice(source: "Codex CLI · 演示", title: "待审批", body: "这是菜单栏生成的测试提醒。", kind: .approval))
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert(); alert.messageText = "未能修改登录启动设置"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }

    @objc private func showSetup() {
        if let setupWindow { setupWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 490),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Notification · 设置与接入"; window.isReleasedWhenClosed = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 28, bottom: 28, right: 28)
        let title = NSTextField(labelWithString: "让提醒出现在每一块屏幕")
        title.font = .systemFont(ofSize: 23, weight: .bold); stack.addArrangedSubview(title)
        let health = NSTextField(wrappingLabelWithString: "\(databaseStatus)\n\(hookStatus)")
        health.font = .systemFont(ofSize: 12); health.textColor = .secondaryLabelColor
        stack.addArrangedSubview(health); healthLabel = health
        let copy = NSTextField(wrappingLabelWithString: "1. 读取系统通知\n在「隐私与安全性 → 完全磁盘访问」添加 Notification.app，开启后退出并重新打开本应用。原有系统通知照常显示。\n\n2. 接收 Codex 人工介入提醒\n按仓库说明安装 hooks，在 Codex CLI 输入 /hooks 检查并信任。提醒不会替你批准操作。\n\n系统通知读取依赖 macOS 内部数据库，只能显示系统实际保存的内容。首次连接不重放历史通知。")
        copy.font = .systemFont(ofSize: 13); copy.preferredMaxLayoutWidth = 490; stack.addArrangedSubview(copy)
        let permissions = NSButton(title: "打开完全磁盘访问设置", target: self, action: #selector(openPermissions))
        stack.addArrangedSubview(permissions)
        let docs = NSButton(title: "打开接入与验证说明", target: self, action: #selector(openDocs))
        stack.addArrangedSubview(docs)
        let reveal = NSButton(title: "在 Finder 中显示本应用", target: self, action: #selector(revealApp))
        stack.addArrangedSubview(reveal)
        window.contentView = stack; window.center(); setupWindow = window
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
    @objc private func openDocs() { NSWorkspace.shared.open(URL(string: "https://github.com/goosmanlei/notification#使用")!) }
    @objc private func revealApp() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
}
