import Foundation

public struct HookEvent: Codable {
    public enum Action: String, Codable { case show, resolve, clearSession }
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
        let encoded = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data()
        let inputKey = digest(encoded)
        let key = "codex:\(session):\(turn):\(tool):\(inputKey)"
        if ["Stop", "Interrupt", "SessionEnd", "UserPromptSubmit"].contains(event) {
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
        let context = (root["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        let questions = input["questions"] as? [[String: Any]] ?? []
        // Never persist commands, raw tool arguments, tokens, or full transcripts.
        let body = kind == .approval ? "\(tool.isEmpty ? "操作" : tool) 需要你在 Codex 终端中确认。"
            : (questions.first?["question"] as? String ?? questions.first?["title"] as? String ?? "Codex 正在请求你的回答，请回到终端处理。")
        let notice = Notice(id: key, source: "Codex CLI", title: kind == .approval ? "需要你的审批" : "需要你的回答",
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
