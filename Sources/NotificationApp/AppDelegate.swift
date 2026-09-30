import AppKit
import ServiceManagement
import UserNotifications
import NotificationCore
import SwiftUI
import os

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let overlays = OverlayController()
    private let worker = DispatchQueue(label: "notification.sources", qos: .userInitiated)
    private var sourceMonitor: SourceMonitor?
    private var bannerMonitor: BannerMonitor?
    private let systemMerger = SystemNoticeMerger()
    private let deliveryLog = Logger(subsystem: "me.leiguoguo.notification", category: "Delivery")
    private var sourceBundles: [String: Set<String>] = [:]
    private var database: NotificationDatabase?
    private var databaseStatus = "系统通知：正在连接"
    private var bannerStatus = "横幅即时接收：正在连接"
    private var hookStatus = "Codex：等待 hook 事件"
    private var systemTestID: String?
    private var systemTestStartedAt: TimeInterval?
    private var systemTestTitle: String?
    private var systemTestBannerMS: Int?
    private var systemTestDatabaseMS: Int?
    private var systemTestStatus: String?
    private var setupWindow: NSWindow?
    private var preferencesWindow: NSWindow?
    private var preferences = NotificationPreferences.load()
    private var healthLabel: NSTextField?
    private var showedPermissionFailure = false
    private var recent: [Notice] = []
    private var isScreenLocked = false
    private var isScreenAsleep = false
    private var isSessionInactive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Artwork.menu()
        statusItem.button?.toolTip = "Notification · 多屏通知"
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
        overlays.hideBody = UserDefaults.standard.bool(forKey: "hideBody")
        overlays.onChange = { [weak self] in self?.updateBadge() }
        observeSession()
        startSources()
        bannerMonitor = BannerMonitor(onBanner: { [weak self] notice in self?.receiveSystem(notice, from: .banner) },
                                      onStatus: { [weak self] status in self?.bannerStatus = status; self?.updateBadge() })
        bannerMonitor?.start()
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

    func applicationWillTerminate(_ notification: Notification) { sourceMonitor?.stop(); bannerMonitor?.stop() }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(menu, "Notification  ·  实验版本", enabled: false)
        add(menu, databaseStatus, enabled: false)
        add(menu, bannerStatus, enabled: false)
        add(menu, hookStatus, enabled: false)
        add(menu, "\(NSScreen.screens.count) 个屏幕 · \(overlays.pendingCount) 条待处理", enabled: false)
        if overlays.dropped > 0 { add(menu, "通知过多：已略过 \(overlays.dropped) 条排队提醒", enabled: false) }
        menu.addItem(.separator())
        add(menu, "显示测试通知", action: #selector(demo))
        add(menu, "发送系统通知测试", action: #selector(testSystemNotification))
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
        add(menu, "通知策略与过滤规则…", action: #selector(showPreferences))
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
        var nextAttempt: TimeInterval = 0
        var retryDelay: TimeInterval = 1
        var latestStatus = "系统通知：正在连接"
        let watched = [path, URL(fileURLWithPath: path.path + "-wal"), path.deletingLastPathComponent(),
                       EventInbox.directory, EventInbox.directory.deletingLastPathComponent()]
        sourceMonitor = SourceMonitor(paths: watched, queue: worker) { [weak self] _ in
            guard let self else { return }
            let events = EventInbox.drain()
            var incoming: [Notice] = []
            if ProcessInfo.processInfo.systemUptime >= nextAttempt {
                do {
                    incoming = try self.database?.poll() ?? []
                    latestStatus = "系统通知：监听中（实验性）"; retryDelay = 1
                    // The timer/event source controls healthy cadence. Only failures back off.
                    nextAttempt = 0
                } catch {
                    let reason = error.localizedDescription.lowercased()
                    if reason.contains("authoriz") || reason.contains("permission") || reason.contains("not permitted") || reason.contains("unable to open") {
                        latestStatus = "系统通知：需要完全磁盘访问"
                    } else { latestStatus = "系统通知：读取失败，请检查版本或权限" }
                    retryDelay = min(30, retryDelay * 2)
                    nextAttempt = ProcessInfo.processInfo.systemUptime + retryDelay
                }
            }
            let status = latestStatus
            let baseline = self.database?.takeBaseline() ?? []
            DispatchQueue.main.async {
                self.systemMerger.rememberExisting(baseline)
                for bundleID in Set(baseline.compactMap(\.bundleID)) { self.rememberApplication(bundleID) }
                self.databaseStatus = status
                if status == "系统通知：需要完全磁盘访问", !self.showedPermissionFailure {
                    self.showedPermissionFailure = true
                    self.showSetup()
                }
                for notice in incoming { self.receiveSystem(notice, from: .database) }
                for event in events { self.handle(event) }
                self.updateBadge()
            }
        }
        sourceMonitor?.start()
    }

    private func receiveSystem(_ raw: Notice, from channel: SystemNoticeMerger.Channel) {
        var notice = raw
        if let bundleID = notice.bundleID { rememberApplication(bundleID) }
        if channel == .banner {
            // Feishu's helper is also named Notification. The unique active test title
            // identifies our own test without guessing the source of ordinary banners.
            let ownTest = notice.source == "Notification" && notice.title == systemTestTitle
            guard let bundleID = ownTest ? Bundle.main.bundleIdentifier : bundleForSource(notice.source) else {
                deliveryLog.info("banner skipped: ambiguous source; titleChars=\(notice.title.count) bodyChars=\(notice.body.count)")
                return
            }
            notice.bundleID = bundleID
        }
        if notice.bundleID == Bundle.main.bundleIdentifier, let testID = systemTestID,
           notice.notificationIdentifier == testID || notice.title == systemTestTitle,
           let start = systemTestStartedAt {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
            if channel == .banner, systemTestBannerMS == nil { systemTestBannerMS = elapsed }
            if channel == .database, systemTestDatabaseMS == nil { systemTestDatabaseMS = elapsed }
            let fast = systemTestBannerMS.map { "横幅 \($0) 毫秒" } ?? "横幅未捕获"
            let fallback = systemTestDatabaseMS.map { "数据库 \($0) 毫秒" } ?? "等待读回数据库"
            systemTestStatus = "系统测试：\(fast) · \(fallback)"
        }
        let allowed = preferences.decision(for: notice).show
        let deliver = allowed && systemMerger.shouldDeliver(notice, from: channel)
        let source = notice.bundleID ?? "unknown"
        let origin = channel == .banner ? "banner" : "database"
        // Metadata only: diagnose capture, filtering and queueing without logging message text.
        deliveryLog.info("receipt source=\(source, privacy: .public) channel=\(origin, privacy: .public) allowed=\(allowed) deliver=\(deliver) titleChars=\(notice.title.count) bodyChars=\(notice.body.count) pending=\(self.overlays.pendingCount)")
        if deliver { receive(notice) }
        updateBadge()
    }

    private func rememberApplication(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID), let bundle = Bundle(url: url) else { return }
        var names = [bundleID, url.deletingPathExtension().lastPathComponent,
                     FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")]
        for key in ["CFBundleName", "CFBundleDisplayName"] {
            if let name = bundle.infoDictionary?[key] as? String { names.append(name) }
            if let name = bundle.localizedInfoDictionary?[key] as? String { names.append(name) }
        }
        for name in names { sourceBundles[name.lowercased(), default: []].insert(bundleID) }
    }

    private func bundleForSource(_ source: String) -> String? {
        let key = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if sourceBundles[key] == nil {
            for app in NSWorkspace.shared.runningApplications {
                guard let bundleID = app.bundleIdentifier else { continue }
                rememberApplication(bundleID)
                if let name = app.localizedName { sourceBundles[name.lowercased(), default: []].insert(bundleID) }
            }
        }
        guard let matches = sourceBundles[key], matches.count == 1 else { return nil }
        return matches.first
    }

    private func receive(_ raw: Notice) {
        var notice = raw
        let decision = preferences.decision(for: notice)
        guard decision.show else { return }
        if let bundle = notice.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            notice.source = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        recent.insert(notice, at: 0)
        if recent.count > 50 { recent.removeLast(recent.count - 50) }
        overlays.show(notice, retention: decision.retention)
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
        let hint = "Notification\n\(databaseStatus)\n\(bannerStatus)\n\(hookStatus)"
        if statusItem.button?.title != title { statusItem.button?.title = title }
        if statusItem.button?.toolTip != hint { statusItem.button?.toolTip = hint }
        let health = "\(databaseStatus)\n\(bannerStatus)\n\(hookStatus) · \(NSScreen.screens.count) 个屏幕" + (systemTestStatus.map { "\n" + $0 } ?? "")
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
    @objc private func replay(_ sender: NSMenuItem) {
        if let notice = sender.representedObject as? Notice { overlays.show(notice, retention: preferences.decision(for: notice).retention) }
    }
    @objc func demo() {
        receive(Notice(source: "Notification", title: "每一块屏幕，都能看见", body: "通知会同步显示在所有屏幕上方，不打断当前输入。"))
    }
    @objc private func demoHITL() {
        receive(Notice(source: "Codex CLI · 演示", title: "待审批", body: "这是菜单栏生成的测试提醒。", kind: .approval))
    }

    @objc private func testSystemNotification() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { [weak self] allowed, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard allowed else {
                    self.systemTestStatus = "系统测试：请在系统通知设置中允许 Notification 发送通知"
                    if let error { self.systemTestStatus = "系统测试：\(error.localizedDescription)" }
                    self.updateBadge(); return
                }
                let identifier = "notification-test-" + UUID().uuidString
                self.systemTestID = identifier
                self.systemTestStartedAt = ProcessInfo.processInfo.systemUptime
                self.systemTestBannerMS = nil; self.systemTestDatabaseMS = nil
                self.systemTestTitle = "系统通知链路测试 · \(identifier.suffix(6))"
                self.systemTestStatus = "系统测试：已发送，等待从通知中心读回"
                self.bannerMonitor?.diagnoseNextNotification()
                self.updateBadge()
                let content = UNMutableNotificationContent()
                content.title = self.systemTestTitle!
                content.body = "这条消息由 macOS 通知中心投递，再由 Notification 读取并展示。"
                center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
                    if let error {
                        DispatchQueue.main.async { self.systemTestStatus = "系统测试：\(error.localizedDescription)"; self.updateBadge() }
                    }
                }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 660),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Notification · 设置与接入"; window.isReleasedWhenClosed = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 28, bottom: 28, right: 28)
        let title = NSTextField(labelWithString: "让提醒出现在每一块屏幕")
        title.font = .systemFont(ofSize: 23, weight: .bold); stack.addArrangedSubview(title)
        let health = NSTextField(wrappingLabelWithString: "\(databaseStatus)\n\(hookStatus)")
        health.font = .systemFont(ofSize: 12); health.textColor = .secondaryLabelColor
        stack.addArrangedSubview(health); healthLabel = health
        stack.addArrangedSubview(NSButton(title: "通知策略与过滤规则…", target: self, action: #selector(showPreferences)))
        let copy = NSTextField(wrappingLabelWithString: "1. 即时接收系统横幅\n为 Notification 开启辅助功能，并保留来源应用的系统横幅。横幅出现时即可读取；关闭横幅后，此通道无法接收。\n\n2. 系统通知补漏\n开启完全磁盘访问后退出并重开本应用。未捕获的通知从数据库补收，macOS 可能延后数秒保存。\n\n3. 接收 Codex 人工介入提醒\n按仓库说明安装并信任 hooks，审批和回答仍在 Codex 中完成。\n\n普通通知仅提供「打开应用」。不自动点击或关闭原通知，不重放启动前的历史通知。")
        copy.font = .systemFont(ofSize: 13); copy.preferredMaxLayoutWidth = 490; stack.addArrangedSubview(copy)
        let permissions = NSButton(title: "打开完全磁盘访问设置", target: self, action: #selector(openPermissions))
        stack.addArrangedSubview(permissions)
        stack.addArrangedSubview(NSButton(title: "打开辅助功能设置（即时接收）", target: self, action: #selector(openAccessibility)))
        stack.addArrangedSubview(NSButton(title: "发送系统通知测试", target: self, action: #selector(testSystemNotification)))
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
    @objc private func showPreferences() {
        if let preferencesWindow { preferencesWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Notification · 通知策略"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PreferencesView(preferences: preferences) { [weak self] updated in
            try updated.save(); self?.preferences = updated
        })
        window.contentMinSize = NSSize(width: 700, height: 600)
        window.center(); preferencesWindow = window
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openDocs() { NSWorkspace.shared.open(URL(string: "https://github.com/goosmanlei/notification#使用")!) }
    @objc private func revealApp() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
}
