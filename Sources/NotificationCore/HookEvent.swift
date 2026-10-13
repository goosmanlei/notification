import Foundation

public struct HookEvent: Codable {
    public enum Action: String, Codable { case show, resolve, clearSession, complete, endSession }
    public var action: Action
    public var key: String
    public var sessionID: String
    public var createdAt: Date
    public var notice: Notice?
}

public enum CodexHook {
    public static func parse(_ data: Data, now: Date = Date()) -> HookEvent? {
        guard data.count <= 1_048_576,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = root["hook_event_name"] as? String,
              let session = root["session_id"] as? String, !session.isEmpty else { return nil }
        let tool = root["tool_name"] as? String ?? ""
        let input = root["tool_input"] as? [String: Any] ?? [:]
        let turn = root["turn_id"] as? String ?? ""
        // Bash approval adds description, but PostToolUse carries only command.
        // Correlate that supported tool by its command, without persisting the command.
        // Other tools retain their arguments: description can be a real MCP input.
        let identityInput: [String: Any]
        if tool == "Bash", let command = input["command"] as? String {
            identityInput = ["command": command]
        } else { identityInput = input }
        let encoded = (try? JSONSerialization.data(withJSONObject: identityInput, options: [.sortedKeys])) ?? Data()
        let inputKey = digest(encoded)
        let key = "codex:\(session):\(turn):\(tool):\(inputKey)"
        if event == "Stop" {
            // Stop reports a finished response, not acceptance of the project's task or successful tests.
            // Deliberately do not persist last_assistant_message or read the transcript.
            let directory = ProjectContext.directoryURL(root["cwd"] as? String)?.path
            let completionKey = "codex:\(session):\(turn.isEmpty ? UUID().uuidString : turn):complete"
            let notice = Notice(id: completionKey, source: "Codex CLI", title: "任务完成",
                                body: "本轮回复已结束，可回到 Codex 查看结果。", kind: .completion,
                                createdAt: now, sessionID: session, context: ProjectContext.label(for: directory),
                                workingDirectory: directory)
            return HookEvent(action: .complete, key: completionKey, sessionID: session, createdAt: now, notice: notice)
        }
        if event == "SessionEnd" {
            return HookEvent(action: .endSession, key: key, sessionID: session, createdAt: now)
        }
        if ["Interrupt", "UserPromptSubmit"].contains(event) {
            return HookEvent(action: .clearSession, key: key, sessionID: session, createdAt: now)
        }
        if event == "PostToolUse" {
            // An async question returns before the user answers; keep that notice until cleared.
            if tool.hasSuffix("request_user_input_async") { return nil }
            return HookEvent(action: .resolve, key: key, sessionID: session, createdAt: now)
        }
        let isInput = tool.split(separator: ".").last.map(String.init).map {
            ["request_user_input", "request_user_input_async"].contains($0)
        } ?? false
        guard event == "PermissionRequest" || (event == "PreToolUse" && isInput) else { return nil }
        let kind: Notice.Kind = event == "PermissionRequest" ? .approval : .input
        let context = ProjectContext.label(for: root["cwd"] as? String)
        let questions = input["questions"] as? [[String: Any]] ?? []
        // Never persist commands, raw tool arguments, tokens, or full transcripts.
        let body = kind == .approval ? (input["description"] as? String ?? input["justification"] as? String ?? tool.split(separator: ".").last.map(String.init) ?? "")
            : questions.compactMap { $0["question"] as? String ?? $0["title"] as? String }.joined(separator: "\n")
        // A request may be decided by automatic review; it does not prove a human is waiting.
        let notice = Notice(id: key, source: "Codex CLI", title: kind == .approval ? "审批请求" : "待回答",
                            body: String(body.prefix(1000)), kind: kind, createdAt: now,
                            sessionID: session, context: context)
        return HookEvent(action: .show, key: key, sessionID: session, createdAt: now, notice: notice)
    }
}

public enum EventInbox {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Notification/inbox")
    }

    public static func write(_ event: HookEvent, to directory: URL = directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent(UUID().uuidString + ".json")
        let data = try JSONEncoder().encode(event)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func drain(from directory: URL = directory, now: Date = Date()) -> [HookEvent] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])) ?? []
        var events: [HookEvent] = []
        for file in files where file.pathExtension == "json" {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) < 32_768 else { continue }
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file), let event = try? JSONDecoder().decode(HookEvent.self, from: data),
                  now.timeIntervalSince(event.createdAt) < 120, event.createdAt.timeIntervalSince(now) < 5 else { continue }
            events.append(event)
        }
        return events.sorted { $0.createdAt < $1.createdAt }
    }
}
