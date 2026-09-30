import AppKit
import NotificationCore

enum TmuxNavigator {
    static func open(_ context: TmuxContext, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let bridge = TmuxBridge.installed() else { throw TmuxError.unavailable }
                let current = try bridge.select(context)
                let clients = bridge.attachedClients(for: current)
                let parents = processParents()
                DispatchQueue.main.async {
                    let candidate = clients.compactMap { client -> (TmuxAttachedClient, NSRunningApplication)? in
                        var pid = client.pid
                        var visited: Set<Int32> = []
                        while pid > 1, visited.insert(pid).inserted, visited.count < 32 {
                            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                                return (client, app)
                            }
                            pid = parents[pid] ?? 0
                        }
                        return nil
                    }.first
                    if let (client, terminal) = candidate {
                        DispatchQueue.global(qos: .userInitiated).async {
                            do {
                                try bridge.switchClient(client, to: current)
                                DispatchQueue.main.async {
                                    if terminal.activate(options: [.activateIgnoringOtherApps]) { completion(nil) }
                                    else { launchTerminal(bridge: bridge, context: current, completion: completion) }
                                }
                            } catch {
                                DispatchQueue.main.async { launchTerminal(bridge: bridge, context: current, completion: completion) }
                            }
                        }
                    } else {
                        launchTerminal(bridge: bridge, context: current, completion: completion)
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(error.localizedDescription) }
            }
        }
    }

    private static func processParents() -> [Int32: Int32] {
        guard let output = LocalCommand.run(URL(fileURLWithPath: "/bin/ps"), ["-axo", "pid=,ppid="]) else { return [:] }
        var result: [Int32: Int32] = [:]
        for row in output.split(separator: "\n") {
            let fields = row.split(whereSeparator: \.isWhitespace)
            if fields.count == 2, let pid = Int32(fields[0]), let parent = Int32(fields[1]) { result[pid] = parent }
        }
        return result
    }

    private static func launchTerminal(bridge: TmuxBridge, context: TmuxContext, completion: @escaping (String?) -> Void) {
        guard let command = bridge.attachCommand(for: context),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        else { completion("无法打开终端"); return }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Notification/tmux-launch")
        let script = directory.appendingPathComponent(UUID().uuidString + ".command")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let content = "#!/bin/sh\nunset TMUX TMUX_PANE\ntrap '/bin/rm -f -- \"$0\"' EXIT\n\(command)\n"
            try Data(content.utf8).write(to: script, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: configuration) { _, error in
                if error != nil { try? FileManager.default.removeItem(at: script) }
                DispatchQueue.main.async { completion(error == nil ? nil : "无法打开终端") }
            }
        } catch { completion("无法准备 tmux 跳转") }
    }
}
