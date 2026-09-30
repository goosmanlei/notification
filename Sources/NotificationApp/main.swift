import AppKit
import NotificationCore

if CommandLine.arguments.contains("--codex-hook") {
    // Hooks never return a policy decision or fail the user's Codex operation.
    var data = Data()
    while data.count <= 1_048_576 {
        guard let part = try? FileHandle.standardInput.read(upToCount: min(65_536, 1_048_577 - data.count)), !part.isEmpty else { break }
        data.append(part)
    }
    if var event = CodexHook.parse(data) {
        if event.action == .show { event.notice?.tmux = TmuxBridge.installed()?.capture() }
        try? EventInbox.write(event)
    }
    exit(0)
}

let app = NSApplication.shared
if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > index + 1 {
    do {
        try OverlayController.renderPreview(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Preview failed: \(error)\n".utf8))
        exit(1)
    }
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()
