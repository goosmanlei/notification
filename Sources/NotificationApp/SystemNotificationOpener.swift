import AppKit
import ApplicationServices
import NotificationCore

/// Reuses the original notification's default UI action; never reconstructs application URLs.
enum SystemNotificationOpener {
    private static let queue = DispatchQueue(label: "notification.original-action", qos: .userInitiated)

    static func open(_ notice: Notice, completion: @escaping (String?) -> Void) {
        guard AXIsProcessTrusted() else {
            completion("需在设置中开启辅助功能，才能点击原通知。也可直接打开应用。")
            return
        }
        queue.async {
            let result = activate(notice)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func activate(_ notice: Notice) -> String? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else {
            return "通知中心未运行，请直接打开应用。"
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        let deadline = Date().addingTimeInterval(4)
        var openedList = hasNotificationList(root, deadline: deadline)
        var expandedGroup = false
        for _ in 0..<12 where Date() < deadline {
            let matches = candidates(in: root, for: notice, deadline: deadline)
            if matches.count > 1 { return "找到多条相同通知，未自动选择。请在通知中心打开。" }
            if let match = matches.first {
                if !match.isStack { return press(match.element) }
                // Pressing a collapsed stack only expands it. Find the individual card before reporting success.
                if !expandedGroup {
                    if let error = press(match.element) { return error }
                    expandedGroup = true; openedList = true
                }
            } else if !openedList {
                // The clock menu extra is a toggle. Never close an already open notification list.
                guard openNotificationCenter(deadline: deadline) else { break }
                openedList = true
            }
            usleep(150_000)
        }
        return "未找到可点击的原通知；它可能已清除或折叠。请在通知中心打开。"
    }

    private static func press(_ element: AXUIElement) -> String? {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
            ? nil : "系统未能执行原通知的打开动作，请直接打开应用。"
    }

    private static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func actions(_ element: AXUIElement) -> [String] {
        var result: CFArray?
        return AXUIElementCopyActionNames(element, &result) == .success ? result as? [String] ?? [] : []
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private struct Candidate {
        let element: AXUIElement
        let isStack: Bool
    }

    private static func candidates(in root: AXUIElement, for notice: Notice, deadline: Date) -> [Candidate] {
        guard let bundle = notice.bundleID else { return [] }
        let title = normalized(notice.title); let body = normalized(notice.body)
        guard !title.isEmpty, !body.isEmpty else { return [] }
        var visited = 0; var complete = true
        func walk(_ element: AXUIElement, depth: Int) -> [Candidate] {
            guard depth < 16, visited < 400, Date() < deadline else { complete = false; return [] }
            visited += 1
            var matches: [Candidate] = []
            for child in children(element) {
                matches += walk(child, depth: depth + 1)
            }
            // Match the card's own description, not text aggregated from unrelated descendants.
            let description = normalized(value(element, kAXDescriptionAttribute) as? String ?? "")
            if matches.isEmpty, actions(element).contains(kAXPressAction as String),
               description.contains(title + ","), description.contains(body),
               description.hasPrefix(notice.source + ",") || description.hasPrefix(bundle + ",") {
                matches.append(Candidate(element: element, isStack: description.hasSuffix(", stacked")))
            }
            return matches
        }
        let matches = walk(root, depth: 0)
        return complete ? matches : []
    }

    private static func hasNotificationList(_ root: AXUIElement, deadline: Date) -> Bool {
        let windows = value(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.contains { window in
            guard Date() < deadline else { return false }
            let title = value(window, kAXTitleAttribute) as? String ?? ""
            return title == "Notification Center" || title == "通知中心"
        }
    }

    private static func openNotificationCenter(deadline: Date) -> Bool {
        for bundle in ["com.apple.controlcenter", "com.apple.systemuiserver"] {
            guard Date() < deadline,
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { continue }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.15)
            var pending = [root]; var visited = 0
            if let bar = value(root, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() {
                pending.append(unsafeBitCast(bar, to: AXUIElement.self))
            }
            while let element = pending.popLast(), visited < 120, Date() < deadline {
                visited += 1
                if value(element, kAXIdentifierAttribute) as? String == "com.apple.menuextra.clock" {
                    return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
                }
                pending.append(contentsOf: children(element))
            }
        }
        return false
    }
}
