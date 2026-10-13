import Foundation
import CSQLite

/// Read only client metadata, never transcript contents or task instructions.
/// Codex's local schema is experimental; missing/changed metadata leaves routing unknown.
public enum CodexSessionContext {
    public static let desktopBundleID = "com.openai.codex"

    public static func databaseURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let root: URL
        if let configured = environment["CODEX_HOME"] {
            guard let directory = ProjectContext.directoryURL(configured) else { return nil }
            root = directory
        } else { root = home.appendingPathComponent(".codex") }
        return root.appendingPathComponent("state_5.sqlite")
    }

    public static func client(sessionID: String, databaseURL: URL? = databaseURL()) -> Notice.CodexClient? {
        guard UUID(uuidString: sessionID) != nil, let databaseURL else { return nil }
        var database: OpaquePointer?
        let result = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { if let database { sqlite3_close(database) } }
        guard result == SQLITE_OK, let database else { return nil }
        sqlite3_busy_timeout(database, 100)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT originator, thread_source FROM threads WHERE id = ? LIMIT 1",
                                 -1, &statement, nil) == SQLITE_OK else { return nil }
        _ = sessionID.withCString {
            sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        func field(_ index: Int32) -> String? {
            sqlite3_column_text(statement, index).map { String(cString: $0) }
        }
        // Native automations are handled in the desktop app even if they have no tmux pane.
        if field(1) == "automation" || field(0) == "Codex Desktop" { return .desktop }
        if field(0) == "codex-tui" || field(0) == "codex_cli_rs" { return .cli }
        return nil // A generic "vscode" source alone does not prove a desktop session.
    }

    public static func desktopThreadURL(sessionID: String?) -> URL? {
        guard let sessionID, UUID(uuidString: sessionID) != nil else { return nil }
        return URL(string: "codex://threads/\(sessionID)")
    }

    /// Only file metadata is inspected. A UUID alone does not prove a resumable conversation:
    /// internal title-generation threads can emit Stop without a persisted rollout.
    public static func resumeCommand(sessionID: String, transcriptPath: String? = nil,
                                     databaseURL: URL? = databaseURL(),
                                     environment: [String: String] = ProcessInfo.processInfo.environment,
                                     home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        guard UUID(uuidString: sessionID) != nil else { return nil }
        var paths = [transcriptPath].compactMap { $0 }
        if let databaseURL {
            var database: OpaquePointer?
            let result = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
            defer { if let database { sqlite3_close(database) } }
            if result == SQLITE_OK, let database {
                sqlite3_busy_timeout(database, 100)
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                if sqlite3_prepare_v2(database, "SELECT rollout_path FROM threads WHERE id = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK {
                    _ = sessionID.withCString {
                        sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    }
                    if sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) {
                        paths.append(String(cString: value))
                    }
                }
            }
        }
        guard paths.contains(where: { path in
            guard let url = ProjectContext.directoryURL(path),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return false }
            return FileManager.default.isReadableFile(atPath: url.path)
        }) else { return nil }
        let command = "codex resume \(sessionID)"
        if let configured = environment["CODEX_HOME"] {
            guard let root = ProjectContext.directoryURL(configured) else { return nil }
            if root.standardizedFileURL != home.appendingPathComponent(".codex").standardizedFileURL {
                return "CODEX_HOME=\(TmuxBridge.shellQuote(root.path)) \(command)"
            }
        }
        return command
    }

    public static func route(_ raw: HookEvent, transcriptPath: String? = nil,
                             databaseURL: URL? = databaseURL(),
                             environment: [String: String] = ProcessInfo.processInfo.environment,
                             home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             tmuxResolver: (String) -> TmuxContext? = { _ in nil }) -> HookEvent? {
        var event = raw
        // Lifecycle events must still clear earlier notices even when the rollout has disappeared.
        guard var notice = event.notice else { return event }
        notice.codexClient = client(sessionID: event.sessionID, databaseURL: databaseURL)
        notice.resumeCommand = resumeCommand(sessionID: event.sessionID, transcriptPath: transcriptPath,
                                             databaseURL: databaseURL, environment: environment, home: home)
        if notice.codexClient == .desktop {
            notice.source = "Codex 桌面端"
            notice.tmux = nil
        } else {
            notice.tmux = tmuxResolver(event.sessionID)
        }
        guard notice.hasCodexDestination else {
            // Stop also clears earlier requests, even when its completion cannot be shown.
            guard event.action == .complete else { return nil }
            event.notice = nil
            return event
        }
        event.notice = notice
        return event
    }
}
