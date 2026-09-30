import AppKit
import ApplicationServices
import NotificationCore
import os

private func notificationBannerChanged(_ observer: AXObserver, _ element: AXUIElement,
                                       _ notification: CFString, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<BannerMonitor>.fromOpaque(context).takeUnretainedValue().changed(element)
}

/// Observes Notification Center's banner UI. No presses, window moves, or other UI mutations.
final class BannerMonitor {
    private let queue = DispatchQueue(label: "notification.banners", qos: .userInitiated)
    private let onBanner: (Notice) -> Void
    private let onStatus: (String) -> Void
    private var observer: AXObserver?
    private var application: AXUIElement?
    private var pid: pid_t = 0
    private var timer: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    private var running = false
    private var generation = 0
    private var changedElements: [AXUIElement] = []
    private var diagnosticUntil: TimeInterval = 0
    private let logger = Logger(subsystem: "me.leiguoguo.notification", category: "BannerMonitor")
    private var seen: [Seen] = []
    private struct Seen { let element: AXUIElement; let content: BannerContent }
    private struct Card { let element: AXUIElement; let content: BannerContent }
    private let bannerRoles: Set<String> = ["AXNotificationCenterBanner", "AXNotificationCenterAlert",
        "AXNotificationCenterBannerWindow", "AXNotificationCenterAlertStack"]

    init(onBanner: @escaping (Notice) -> Void, onStatus: @escaping (String) -> Void) {
        self.onBanner = onBanner; self.onStatus = onStatus
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.maintain() }
            self.timer = timer; timer.resume()
        }
    }

    func stop() { queue.sync { running = false; timer?.cancel(); timer = nil; detach() } }

    /// The explicit system test logs structural counts only, never notification text.
    func diagnoseNextNotification() {
        queue.async { self.diagnosticUntil = ProcessInfo.processInfo.systemUptime + 12 }
    }

    private func detach() {
        generation += 1
        pending?.cancel(); pending = nil
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil; application = nil; pid = 0; seen = []; changedElements = []
    }

    private func maintain() {
        guard running else { return }
        guard AXIsProcessTrusted() else {
            if observer != nil { detach() }
            status("横幅即时接收：需要辅助功能权限")
            return
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else {
            detach(); status("横幅即时接收：等待通知中心"); return
        }
        if observer == nil || pid != app.processIdentifier {
            detach()
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.05)
            var result: AXObserver?
            guard AXObserverCreate(app.processIdentifier, notificationBannerChanged, &result) == .success,
                  let result else { status("横幅即时接收：暂不可用，使用数据库"); return }
            let context = Unmanaged.passUnretained(self).toOpaque()
            var attached = false
            for name in [kAXWindowCreatedNotification, kAXCreatedNotification, kAXLayoutChangedNotification] {
                if AXObserverAddNotification(result, root, name as CFString, context) == .success { attached = true }
            }
            guard attached else { status("横幅即时接收：暂不可用，使用数据库"); return }
            observer = result; application = root; pid = app.processIdentifier
            // Baseline existing UI before enabling callbacks; opening the app must not replay old banners.
            scan(emit: false)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(result), .commonModes)
        } else { scan(emit: true) }
        status("横幅即时接收：监听中")
    }

    fileprivate func changed(_ element: AXUIElement) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            if !self.changedElements.contains(where: { CFEqual($0, element) }) {
                self.changedElements.append(element)
                self.changedElements = Array(self.changedElements.suffix(20))
            }
            guard self.pending == nil else { return }
            let generation = self.generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == generation else { return }
                self.pending = nil
                let roots = self.changedElements; self.changedElements = []
                self.scan(emit: true, roots: roots)
            }
            self.pending = work
            self.queue.asyncAfter(deadline: .now() + .milliseconds(15), execute: work)
            // Window creation can precede its text. Bounded retries catch late population/reused windows.
            for delay in [80, 200, 450] {
                self.queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
                    guard let self, self.running, self.generation == generation else { return }
                    self.scan(emit: true, roots: [element])
                }
            }
        }
    }

    private func scan(emit: Bool, roots eventRoots: [AXUIElement]? = nil) {
        guard let application else { return }
        var deadline = ProcessInfo.processInfo.systemUptime + 0.2
        var visited = 0, bannerNodes = 0, fieldCount = 0
        var historyPanel = false
        func walk(_ element: AXUIElement, insideBanner: Bool, depth: Int) -> (cards: [Card], lines: [BannerContent.Line], complete: Bool) {
            guard depth < 16, visited < 250, ProcessInfo.processInfo.systemUptime < deadline else {
                return ([], [], false)
            }
            visited += 1
            let subrole = string(element, kAXSubroleAttribute)
            let role = string(element, kAXRoleAttribute)
            if role == kAXButtonRole,
               BannerContent.isHistoryControl(role: role, labels: [string(element, kAXTitleAttribute),
                   string(element, kAXDescriptionAttribute), string(element, kAXValueAttribute)]) { historyPanel = true }
            let isBanner = insideBanner || bannerRoles.contains(subrole)
            // Notification Center's history cards are not newly arriving banners.
            if subrole == "AXNotificationCenterNotification" { return ([], [], true) }
            if isBanner { bannerNodes += 1 }
            var lines: [BannerContent.Line] = [], cards: [Card] = []
            var complete = true
            if isBanner, role == kAXStaticTextRole {
                let text = string(element, kAXValueAttribute)
                if !text.isEmpty {
                    lines.append(.init(identifier: string(element, kAXIdentifierAttribute), text: text))
                    fieldCount += 1
                }
            }
            for child in children(element) {
                let result = walk(child, insideBanner: isBanner, depth: depth + 1)
                cards += result.cards; lines += result.lines
                complete = complete && result.complete
            }
            if complete, isBanner, cards.isEmpty,
               let content = BannerContent.parse(lines, description: string(element, kAXDescriptionAttribute)) {
                cards.append(Card(element: element, content: content))
            }
            return (cards, lines, complete)
        }
        // Layout events often point at a title/body descendant, not the banner container.
        // Scan its containing window so the banner marker and history controls are visible.
        var windows: [AXUIElement] = []
        func addWindow(_ window: AXUIElement) {
            if !windows.contains(where: { CFEqual($0, window) }) { windows.append(window) }
        }
        for root in eventRoots ?? [] {
            if string(root, kAXRoleAttribute) == kAXWindowRole { addWindow(root) }
            else if let raw = value(root, kAXWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
                addWindow(raw as! AXUIElement)
            } else {
                for window in value(application, kAXWindowsAttribute) as? [AXUIElement] ?? [] { addWindow(window) }
            }
        }
        if eventRoots == nil { windows = value(application, kAXWindowsAttribute) as? [AXUIElement] ?? [] }
        var cards: [Card] = []
        var complete = true
        for window in windows {
            // Desktop widgets share this process but have no notification content.
            if string(window, kAXTitleAttribute).contains("::") { continue }
            deadline = ProcessInfo.processInfo.systemUptime + 0.2
            visited = 0; historyPanel = false
            let result = walk(window, insideBanner: false, depth: 0)
            if result.complete && !historyPanel { cards += result.cards }
            complete = complete && result.complete
        }
        if ProcessInfo.processInfo.systemUptime < diagnosticUntil {
            logger.notice("scan event=\(eventRoots != nil) roots=\(windows.count) nodes=\(visited) bannerNodes=\(bannerNodes) fields=\(fieldCount) cards=\(cards.count) complete=\(complete)")
        }
        for card in cards {
            guard !seen.contains(where: { CFEqual($0.element, card.element) && $0.content == card.content }) else { continue }
            // Event roots can overlap (application, window and card). Remember immediately,
            // including during baseline scans, so one batch cannot emit the same card twice.
            seen.append(Seen(element: card.element, content: card.content))
            if emit {
                let content = card.content
                let notice = Notice(id: "banner:" + UUID().uuidString, source: content.source,
                                    title: content.title, body: content.body)
                DispatchQueue.main.async { [weak self] in self?.onBanner(notice) }
            }
        }
        // Empty/partial AX reads do not prove a card was removed. Keep bounded identities
        // across those reads. Expanded history panels were rejected above.
        seen = Array(seen.suffix(500))
    }

    private func status(_ text: String) { DispatchQueue.main.async { [weak self] in self?.onStatus(text) } }
    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }
    private func string(_ element: AXUIElement, _ attribute: String) -> String { value(element, attribute) as? String ?? "" }
    private func children(_ element: AXUIElement) -> [AXUIElement] { value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
}
