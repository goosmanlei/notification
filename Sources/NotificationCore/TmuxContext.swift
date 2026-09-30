import Foundation
import Darwin

public struct TmuxContext: Codable, Equatable {
    public var socketPath: String
    public var serverPID: Int
    public var sessionID: String
    public var windowID: String
    public var paneID: String
    public var sessionName: String
    public var windowName: String
    public var paneIndex: Int

    public init(socketPath: String, serverPID: Int, sessionID: String, windowID: String, paneID: String,
                sessionName: String, windowName: String, paneIndex: Int) {
        self.socketPath = socketPath; self.serverPID = serverPID; self.sessionID = sessionID
        self.windowID = windowID; self.paneID = paneID; self.sessionName = sessionName
        self.windowName = windowName; self.paneIndex = paneIndex
    }

    public var label: String { "\(sessionName)/\(windowName)/pane-\(paneIndex)" }
    public var isValid: Bool {
        socketPath.hasPrefix("/") && !socketPath.contains("\0") && socketPath.utf8.count < 4096 && serverPID > 0 &&
        Self.validID(sessionID, prefix: "$") && Self.validID(windowID, prefix: "@") &&
        Self.validID(paneID, prefix: "%") && paneIndex >= 0
    }

    static func validID(_ value: String, prefix: Character) -> Bool {
        value.first == prefix && value.count > 1 && value.dropFirst().utf8.allSatisfy { (48...57).contains($0) }
    }
}

public struct TmuxAttachedClient {
    public var name: String
    public var pid: Int32
    public var sessionID: String
    public var activity: Int
}

public enum TmuxError: LocalizedError {
    case unavailable, paneGone, selectionFailed
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "找不到 tmux"
        case .paneGone: return "原 tmux 窗格已关闭或服务已重启"
        case .selectionFailed: return "无法切换到该 tmux 窗格"
        }
    }
}

public struct TmuxBridge {
    public let executable: URL
    private static let separator = "\u{1f}"
    private static let paneFormat = ["#{pid}", "#{session_id}", "#{window_id}", "#{pane_id}",
                                     "#{session_name}", "#{window_name}", "#{pane_index}", "#{pane_pid}",
                                     "#{pane_current_command}", "#{pane_title}"].joined(separator: separator)
    private struct Pane {
        var context: TmuxContext
        var pid: Int
        var command: String
        var title: String
    }

    public init(executable: URL) { self.executable = executable }

    public static func installed(environment: [String: String] = ProcessInfo.processInfo.environment) -> TmuxBridge? {
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init) +
            ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for path in paths where path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path).appendingPathComponent("tmux")
            if FileManager.default.isExecutableFile(atPath: url.path) { return TmuxBridge(executable: url) }
        }
        return nil
    }

    public func capture(sessionID: String? = nil,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        processID: Int32 = getpid()) -> TmuxContext? {
        guard let raw = environment["TMUX"] else { return nil }
        let fields = raw.components(separatedBy: ",")
        guard fields.count >= 3, let pid = Int(fields[fields.count - 2]), pid > 0,
              let session = Int(fields[fields.count - 1]), session >= 0 else { return nil }
        let socket = fields.dropLast(2).joined(separator: ",")
        let panes = listPanes(socket: socket, serverPID: pid)
        let processes = Self.processes()
        // A shared app-server inherits the pane that launched it, not the requesting CLI's pane.
        // The CLI's current terminal title can identify the actual session, including /resume switches.
        if let sessionID, UUID(uuidString: sessionID) != nil {
            let matching = panes.filter { pane in
                guard Self.title(pane.title, identifies: sessionID) else { return false }
                if pane.command == "codex" { return true }
                // Task launchers may be the foreground command while Codex runs below them.
                // A leftover title on an idle pane is not sufficient evidence.
                guard let processes else { return false }
                return processes.contains { process in
                    URL(fileURLWithPath: process.value.command).lastPathComponent == "codex" &&
                    Self.ancestors(of: process.key, processes: processes).contains(pane.pid)
                }
            }
            let ids = Set(matching.map { $0.context.paneID })
            if ids.count == 1 {
                return matching.first { $0.context.sessionID == "$\(session)" }?.context ?? matching.first?.context
            }
            if ids.count > 1 { return nil }
        }
        // Direct CLI hooks can be proven by ancestry. Never trust TMUX_PANE by itself.
        guard let processes else { return nil }
        let ancestors = Self.ancestors(of: Int(processID), processes: processes)
        let matching = panes.filter { ancestors.contains($0.pid) }
        guard Set(matching.map { $0.context.paneID }).count == 1 else { return nil }
        return matching.first { $0.context.sessionID == "$\(session)" }?.context ?? matching.first?.context
    }

    private static func title(_ title: String, identifies sessionID: String) -> Bool {
        // Codex may truncate the UUID in its terminal title. Require at least 24 UUID characters,
        // an explicit ellipsis for truncation, and a whole title field rather than substring guessing.
        let expected = sessionID.lowercased()
        return title.components(separatedBy: "|").contains { field in
            let value = field.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value == expected { return true }
            let suffix = value.hasSuffix("...") ? 3 : (value.hasSuffix("…") ? 1 : 0)
            guard suffix > 0 else { return false }
            let prefix = String(value.dropLast(suffix))
            return prefix.count >= 24 && prefix.count < expected.count && expected.hasPrefix(prefix)
        }
    }

    private struct ProcessEntry {
        var parent: Int
        var command: String
    }

    private static func processes() -> [Int: ProcessEntry]? {
        guard let output = LocalCommand.run(URL(fileURLWithPath: "/bin/ps"), ["-axo", "pid=,ppid=,comm="]) else { return nil }
        var processes: [Int: ProcessEntry] = [:]
        for row in output.split(separator: "\n") {
            let values = row.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            if values.count == 3, let pid = Int(values[0]), let parent = Int(values[1]) {
                processes[pid] = ProcessEntry(parent: parent, command: String(values[2]))
            }
        }
        return processes
    }

    private static func ancestors(of pid: Int, processes: [Int: ProcessEntry]) -> Set<Int> {
        var result: Set<Int> = []; var current = pid
        while current > 1, result.count < 64, result.insert(current).inserted {
            guard let process = processes[current] else { break }
            current = process.parent
        }
        return result
    }

    public func refreshed(_ context: TmuxContext) -> TmuxContext? {
        guard context.isValid else { return nil }
        return lookup(socket: context.socketPath, serverPID: context.serverPID,
                      paneID: context.paneID, preferredSession: context.sessionID)
    }

    private func lookup(socket: String, serverPID: Int, paneID: String, preferredSession: String) -> TmuxContext? {
        let matches = listPanes(socket: socket, serverPID: serverPID).map(\.context).filter { $0.paneID == paneID }
        return matches.first { $0.sessionID == preferredSession } ?? matches.first
    }

    private func listPanes(socket: String, serverPID: Int) -> [Pane] {
        guard socket.hasPrefix("/"), !socket.contains("\0"),
              let output = LocalCommand.run(executable, ["-S", socket, "list-panes", "-a", "-F", Self.paneFormat]) else { return [] }
        return output.split(separator: "\n").compactMap { row -> Pane? in
            let fields = row.components(separatedBy: Self.separator)
            guard fields.count == 10, Int(fields[0]) == serverPID,
                  let index = Int(fields[6]), let panePID = Int(fields[7]) else { return nil }
            let context = TmuxContext(socketPath: socket, serverPID: serverPID, sessionID: fields[1],
                windowID: fields[2], paneID: fields[3], sessionName: fields[4], windowName: fields[5], paneIndex: index)
            return context.isValid ? Pane(context: context, pid: panePID, command: fields[8], title: fields[9]) : nil
        }
    }

    public func select(_ context: TmuxContext) throws -> TmuxContext {
        guard let current = refreshed(context) else { throw TmuxError.paneGone }
        guard LocalCommand.run(executable, ["-S", current.socketPath, "select-window", "-t", "\(current.sessionID):\(current.windowID)"]) != nil,
              LocalCommand.run(executable, ["-S", current.socketPath, "select-pane", "-t", current.paneID]) != nil
        else { throw TmuxError.selectionFailed }
        return current
    }

    public func attachedClients(for context: TmuxContext) -> [TmuxAttachedClient] {
        let format = ["#{client_name}", "#{client_pid}", "#{session_id}", "#{client_activity}", "#{client_control_mode}"].joined(separator: Self.separator)
        guard let output = LocalCommand.run(executable, ["-S", context.socketPath, "list-clients", "-F", format]) else { return [] }
        return output.split(separator: "\n").compactMap { row -> TmuxAttachedClient? in
            let fields = row.components(separatedBy: Self.separator)
            guard fields.count == 5, let pid = Int32(fields[1]), pid > 0, fields[4] == "0" else { return nil }
            return TmuxAttachedClient(name: fields[0], pid: pid, sessionID: fields[2], activity: Int(fields[3]) ?? 0)
        }.sorted {
            if ($0.sessionID == context.sessionID) != ($1.sessionID == context.sessionID) {
                return $0.sessionID == context.sessionID
            }
            return $0.activity > $1.activity
        }
    }

    public func switchClient(_ client: TmuxAttachedClient, to context: TmuxContext) throws {
        guard LocalCommand.run(executable, ["-S", context.socketPath, "switch-client", "-c", client.name, "-t", context.sessionID]) != nil
        else { throw TmuxError.selectionFailed }
    }

    /// Only validated identifiers enter tmux arguments; human-readable names are never executable input.
    public func attachCommand(for context: TmuxContext) -> String? {
        guard context.isValid else { return nil }
        let prefix = [executable.path, "-S", context.socketPath]
        let commands = [prefix + ["select-window", "-t", "\(context.sessionID):\(context.windowID)"],
                        prefix + ["select-pane", "-t", context.paneID],
                        prefix + ["attach-session", "-t", context.sessionID]]
        return commands.map { $0.map(Self.shellQuote).joined(separator: " ") }.joined(separator: " && ")
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
