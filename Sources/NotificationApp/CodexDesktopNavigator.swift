import AppKit
import NotificationCore

enum CodexDesktopNavigator {
    static func open(sessionID: String?, completion: @escaping (String?) -> Void) {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CodexSessionContext.desktopBundleID) else {
            completion("未找到 Codex 桌面端应用"); return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let finished: (NSRunningApplication?, Error?) -> Void = { _, error in
            DispatchQueue.main.async {
                completion(error.map { "无法打开桌面端：\($0.localizedDescription)" })
            }
        }
        if let url = CodexSessionContext.desktopThreadURL(sessionID: sessionID) {
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration, completionHandler: finished)
        } else {
            NSWorkspace.shared.openApplication(at: application, configuration: configuration, completionHandler: finished)
        }
    }
}
