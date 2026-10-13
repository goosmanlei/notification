import Foundation
import Darwin
import CSQLite
import NotificationCore

final class NotificationCoreTests {
    private let codexTmux = TmuxContext(socketPath: "/tmp/test.sock", serverPID: 1, sessionID: "$1", windowID: "@1",
                                        paneID: "%1", sessionName: "test", windowName: "test", paneIndex: 0)
    private func payload(title: String = "Test", body: String = "hello", response: Int = 0) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "app": "com.example.test", "date": 123.0, "resp": ["act": response],
            "req": ["titl": title, "subt": "subtitle", "body": body, "iden": "n-1"]
        ], format: .binary, options: 0)
    }

    func testPayloadChangesAndDismissalDeduplication() throws {
        let a = try unwrap(PayloadParser.parse(payload(), recordID: 1))
        let dismissed = try unwrap(PayloadParser.parse(payload(response: 1), recordID: 1))
        let updated = try unwrap(PayloadParser.parse(payload(body: "updated"), recordID: 1))
        checkEqual(a.title, "Test"); checkEqual(a.body, "subtitle\nhello")
        checkEqual(a.id, dismissed.id)
        checkNotEqual(a.id, updated.id)
        checkNil(PayloadParser.parse(Data("invalid".utf8), recordID: 1))
    }

    func testDatabaseSkipsHistoryButReceivesInsertsAndUpdates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("db")
        var writer: OpaquePointer?
        checkEqual(sqlite3_open(path.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        checkEqual(sqlite3_exec(writer, "CREATE TABLE record (rec_id INTEGER PRIMARY KEY, data BLOB, delivered_date REAL)", nil, nil, nil), SQLITE_OK)
        let deliveredAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func put(_ id: Int64, _ data: Data) {
            var statement: OpaquePointer?
            checkEqual(sqlite3_prepare_v2(writer, "INSERT OR REPLACE INTO record VALUES (?, ?, ?)", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, id)
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            sqlite3_bind_double(statement, 3, deliveredAt.timeIntervalSinceReferenceDate)
            checkEqual(sqlite3_step(statement), SQLITE_DONE)
        }
        put(1, try payload())
        let reader = NotificationDatabase(path: path)
        checkEqual(try reader.poll().count, 0)
        checkEqual(reader.takeBaseline().map(\.title), ["Test"])
        checkTrue(reader.takeBaseline().isEmpty)
        put(2, try payload(title: "new"))
        let inserted = try reader.poll()
        checkEqual(inserted.map(\.title), ["new"])
        checkEqual(inserted.first?.createdAt, deliveredAt)
        checkTrue(reader.takeBaseline().isEmpty)
        checkEqual(try reader.poll().count, 0)
        put(2, try payload(title: "new", response: 2))
        checkEqual(try reader.poll().count, 0)
        put(2, try payload(title: "changed"))
        checkEqual(try reader.poll().map(\.title), ["changed"])
    }

    func testMissingDatabaseIsNotCreated() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        checkThrows(try NotificationDatabase(path: path).poll())
        checkFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testBannerFieldsDoNotMixCardsOrControls() throws {
        let fields: [BannerContent.Line] = [
            .init(identifier: "header", text: "Feishu"), .init(identifier: "title", text: "Team"),
            .init(identifier: "subtitle", text: "Alice"), .init(identifier: "body", text: "Ready"),
            .init(identifier: "close", text: "Close"), .init(identifier: "", text: "now")
        ]
        let banner = try unwrap(BannerContent.parse(fields))
        checkEqual(banner.source, "Feishu"); checkEqual(banner.title, "Team")
        checkEqual(banner.body, "Alice\nReady")
        checkNil(BannerContent.parse(fields + [.init(identifier: "title", text: "Another card")]))
        checkNil(BannerContent.parse([.init(identifier: "body", text: "Unrelated widget")]))
        checkNil(BannerContent.parse([.init(identifier: "title", text: "Clock")]))
        let fallback = try unwrap(BannerContent.parse([.init(identifier: "title", text: "Test"),
                                                       .init(identifier: "body", text: "hello")],
                                                      description: "Notification, Test, hello, now"))
        checkEqual(fallback.source, "Notification")
        checkTrue(BannerContent.isHistoryControl(role: "AXButton", labels: ["", "Edit Widgets"]))
        checkTrue(BannerContent.isHistoryControl(role: "AXButton", labels: ["编辑小组件"]))
        checkFalse(BannerContent.isHistoryControl(role: "AXStaticText", labels: ["Edit Widgets"]))
        checkFalse(BannerContent.isHistoryControl(role: "AXButton", labels: ["Close"]))
    }

    func testSystemReceiptPairsPreserveRepeatedMessages() {
        let merger = SystemNoticeMerger()
        var notice = Notice(source: "Feishu", title: "Team", body: "Alice\nReady", bundleID: "example.chat")
        checkTrue(merger.shouldDeliver(notice, from: .banner, at: 0))
        notice.id = "different-banner"
        checkTrue(merger.shouldDeliver(notice, from: .banner, at: 1))
        // New same-text banners remain immediate. Each DB identity pairs only once.
        notice.id = "database-1"; notice.body = "Alice Ready"
        checkFalse(merger.shouldDeliver(notice, from: .database, at: 5))
        notice.id = "database-2"
        checkFalse(merger.shouldDeliver(notice, from: .database, at: 6))
        notice.id = "database-3"
        checkTrue(merger.shouldDeliver(notice, from: .database, at: 7))
        checkFalse(merger.shouldDeliver(notice, from: .banner, at: 8))
        notice.body = "Changed"
        checkTrue(merger.shouldDeliver(notice, from: .banner, at: 9))
        notice.bundleID = "example.other"; notice.id = "other-database-1"
        checkTrue(merger.shouldDeliver(notice, from: .database, at: 10))
        notice.bundleID = "example.chat"; notice.id = "database-4"
        checkTrue(merger.shouldDeliver(notice, from: .database, at: 40))
        checkFalse(merger.shouldDeliver(notice, from: .database, at: 80))
    }

    func testDatabaseBaselineAndRepeatedIdentitiesDoNotReplay() {
        let merger = SystemNoticeMerger()
        var old = Notice(id: "old-record", source: "Feishu", title: "Team", body: "Old message", bundleID: "example.chat")
        merger.rememberExisting([old])
        checkFalse(merger.shouldDeliver(old, from: .database, at: 0))
        // An explicitly new banner is not delayed because old text exists in history.
        old.id = "new-banner-same-text"
        checkTrue(merger.shouldDeliver(old, from: .banner, at: 1))
        var fresh = old; fresh.id = "new-banner"; fresh.body = "New message"
        checkTrue(merger.shouldDeliver(fresh, from: .banner, at: 2))
        fresh.id = "new-record"
        checkFalse(merger.shouldDeliver(fresh, from: .database, at: 7))
        checkFalse(merger.shouldDeliver(fresh, from: .database, at: 8))
        old.id = "genuinely-new-identical-record"
        checkFalse(merger.shouldDeliver(old, from: .database, at: 9))
        checkFalse(merger.shouldDeliver(old, from: .database, at: 300))
        fresh.id = "newest-record"; fresh.body = "Newest message"
        checkTrue(merger.shouldDeliver(fresh, from: .database, at: 301))
        checkFalse(merger.shouldDeliver(fresh, from: .banner, at: 302))
    }

    func testPreferencesDefaultsPersistenceAndValidation() throws {
        let name = "notification-tests-" + UUID().uuidString
        let defaults = try unwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var preferences = NotificationPreferences.load(from: defaults)
        let codex = Notice(source: "Codex CLI", title: "待回答", body: "Choose", kind: .input)
        checkNil(preferences.decision(for: codex).retention.duration)
        preferences.codex = RetentionPolicy(seconds: 7)
        preferences.feishu.message = RetentionPolicy(mode: .untilHandled)
        preferences.feishu.conditions = [.init(kind: .contains, keyword: "发布")]
        preferences.feishu.filterMessages = true
        try preferences.save(to: defaults)
        checkEqual(NotificationPreferences.load(from: defaults), preferences)
        // Removing the meeting category must not reset an older saved configuration.
        var legacy = try unwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        var feishu = try unwrap(legacy["feishu"] as? [String: Any])
        feishu["meeting"] = ["mode": "timed", "seconds": 9999]
        feishu["meetingKeywords"] = "旧会议规则"
        legacy["feishu"] = feishu
        legacy.removeValue(forKey: "codexCompletion")
        legacy.removeValue(forKey: "otherApps")
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: NotificationPreferences.defaultsKey)
        checkEqual(NotificationPreferences.load(from: defaults), preferences)
        checkEqual(preferences.decision(for: codex).retention.duration, 7)
        preferences.codex.seconds = 0
        checkThrows(try preferences.save(to: defaults))
        checkEqual(NotificationPreferences.load(from: defaults).codex.seconds, 7)
        defaults.set(Data("invalid".utf8), forKey: NotificationPreferences.defaultsKey)
        checkEqual(NotificationPreferences.load(from: defaults), NotificationPreferences())
    }

    func testFeishuClassificationAndIndependentRetention() {
        var preferences = NotificationPreferences()
        preferences.feishu.calendar = RetentionPolicy(seconds: 30)
        preferences.feishu.other = RetentionPolicy(seconds: 5)
        var notice = Notice(source: "Feishu", title: "日程提醒", body: "Upcoming", bundleID: "com.electron.lark")
        checkEqual(preferences.decision(for: notice).feishuType, .calendar)
        checkEqual(preferences.decision(for: notice).retention.duration, 30)
        notice.title = "日历助手"; notice.body = "[提醒] 即将开始日程“测试日程”"
        preferences.feishu.filterMessages = true
        preferences.feishu.conditions = [.init(keyword: "不匹配的消息条件")]
        checkEqual(preferences.decision(for: notice).feishuType, .calendar)
        checkEqual(preferences.decision(for: notice).retention.duration, 30)
        checkTrue(preferences.decision(for: notice).show)
        notice.body = "会议即将开始"
        checkEqual(preferences.decision(for: notice).feishuType, .calendar)
        notice.title = "新通知"
        checkEqual(preferences.decision(for: notice).feishuType, .message)
        checkEqual(FeishuNoticeType.allCases, [.message, .calendar, .other])
        notice.title = "任务助手"; notice.body = "Task"
        checkEqual(preferences.decision(for: notice).feishuType, .other)
        checkEqual(preferences.decision(for: notice).retention.duration, 5)
        notice.title = "团队"; notice.body = "hello"
        checkEqual(preferences.decision(for: notice).feishuType, .message)
        preferences.feishu.calendarKeywords = "\ncustom calendar\n"
        notice.body = "CUSTOM CALENDAR"
        checkEqual(preferences.decision(for: notice).feishuType, .calendar)
        notice.bundleID = "example.other"
        checkNil(preferences.decision(for: notice).feishuType)
        checkFalse(preferences.decision(for: notice).show)
        checkEqual(preferences.decision(for: notice).retention.mode, .disabled)
    }

    func testFeishuMessageFiltersAndClassificationBoundary() {
        var preferences = NotificationPreferences()
        preferences.feishu.filterMessages = true
        preferences.feishu.conditions = [.init(keyword: "Release"), .init(kind: .mentionsMe)]
        var notice = Notice(source: "飞书", title: "项目群", body: "release ready", bundleID: "com.electron.lark")
        checkTrue(preferences.decision(for: notice).show)
        preferences.feishu.matchMode = .all
        checkFalse(preferences.decision(for: notice).show)
        preferences.feishu.mentionKeywords = "@Test User"
        notice.body = "@Test User release ready"
        checkTrue(preferences.decision(for: notice).show)
        preferences.feishu.conditions.append(.init(kind: .urgent))
        checkFalse(preferences.decision(for: notice).show)
        notice.body = "[加急] @Test User release ready"
        checkTrue(preferences.decision(for: notice).show)
        preferences.feishu.conditions[2].enabled = false
        notice.body = "@Test User release ready"
        checkTrue(preferences.decision(for: notice).show)
        notice.body = "日程提醒：下午三点"
        checkTrue(preferences.decision(for: notice).show) // Message filters never suppress a calendar notice.
        notice.body = "ordinary"; notice.bundleID = "example.other"
        checkFalse(preferences.decision(for: notice).show)
        notice.bundleID = "com.electron.lark"
        preferences.feishu.conditions = [.init(keyword: "   ")]
        checkFalse(preferences.decision(for: notice).show)
        checkNotEqual(preferences.validationError, nil)
        preferences.feishu.filterMessages = false
        checkTrue(preferences.decision(for: notice).show)
        preferences.feishu.filterMessages = true
        preferences.feishu.conditions = [.init(kind: .urgent)]
        notice.body = "[⚡加急⚡] 请确认发布计划。"
        checkTrue(preferences.decision(for: notice).show)
        notice.body = "[ ⚡\u{FE0F} 加急 ⚡\u{FE0F} ] 请确认发布计划。"
        checkTrue(preferences.decision(for: notice).show)
        notice.body = "普通讨论：什么是加急消息？"
        checkFalse(preferences.decision(for: notice).show)
        preferences.feishu.conditions = [.init(kind: .mentionsMe)]
        preferences.feishu.mentionKeywords = FeishuPreferences().mentionKeywords
        notice.body = "提醒机器人@你: @测试用户 请确认今天的计划。"
        checkTrue(preferences.decision(for: notice).show)
        notice.body = "提醒机器人: @其他人 请确认今天的计划。"
        checkFalse(preferences.decision(for: notice).show)
    }

    func testOnlyConfiguredApplicationsAreAllowed() {
        var preferences = NotificationPreferences()
        preferences.codex = RetentionPolicy(seconds: 17)
        for bundleID in ["com.electron.lark", "com.bytedance.lark", "com.larksuite.lark"] {
            let notice = Notice(source: "飞书", title: "通知", body: "内容", bundleID: bundleID)
            checkTrue(preferences.acceptsSource(notice))
            checkTrue(preferences.decision(for: notice).show)
        }
        for kind in [Notice.Kind.approval, .input] {
            let notice = Notice(source: "Codex CLI", title: "提醒", body: "内容", kind: kind, tmux: codexTmux)
            checkTrue(preferences.acceptsSource(notice))
            checkTrue(preferences.decision(for: notice).show)
            checkEqual(preferences.decision(for: notice).retention.duration, 17)
        }
        for source in ["Safari", "Mail", "Notification", "未知应用", "飞书", "Codex CLI"] {
            for kind in [Notice.Kind.notification, .approval, .input] {
                let notice = Notice(source: source, title: "@你 ⚡加急⚡", body: "日历助手", kind: kind, bundleID: "example.other")
                checkFalse(preferences.acceptsSource(notice))
                checkFalse(preferences.decision(for: notice).show)
                preferences.otherApps = RetentionPolicy(seconds: 23)
                checkTrue(preferences.acceptsSource(notice))
                checkTrue(preferences.decision(for: notice).show)
                checkEqual(preferences.decision(for: notice).retention.duration, 23)
                checkNil(preferences.decision(for: notice).feishuType)
                preferences.otherApps.mode = .disabled
            }
        }
        checkFalse(preferences.decision(for: Notice(source: "未知应用", title: "提醒", body: "内容", kind: .approval)).show)
        checkFalse(preferences.decision(for: Notice(source: "Codex CLI", title: "提醒", body: "内容")).show)
        checkTrue(preferences.decision(for: Notice(source: "飞书", title: "提醒", body: "内容")).show)
        preferences.feishu.filterMessages = true
        preferences.feishu.conditions = [.init(keyword: "发布")]
        let filtered = Notice(source: "飞书", title: "提醒", body: "内容", bundleID: "com.electron.lark")
        checkTrue(preferences.acceptsSource(filtered))
        checkFalse(preferences.decision(for: filtered).show)
    }

    func testDisabledPoliciesOverrideFiltersAndPersistIndependently() throws {
        let name = "notification-tests-" + UUID().uuidString
        let defaults = try unwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var preferences = NotificationPreferences()
        let completed = Notice(source: "Codex CLI", title: "任务完成", body: "", kind: .completion)
        checkFalse(completed.requiresAction)
        checkFalse(preferences.decision(for: completed).show)
        checkEqual(preferences.otherApps.mode, .disabled)
        let codex = Notice(source: "Codex CLI", title: "待回答", body: "", kind: .input)
        let message = Notice(source: "飞书", title: "项目群", body: "@你", bundleID: "com.electron.lark")
        let calendar = Notice(source: "飞书", title: "日历助手", body: "", bundleID: "com.electron.lark")
        let other = Notice(source: "飞书", title: "任务助手", body: "", bundleID: "com.electron.lark")
        preferences.codex.mode = .disabled
        checkFalse(preferences.decision(for: codex).show)
        checkTrue(preferences.decision(for: message).show)
        preferences.feishu.message.mode = .disabled
        checkFalse(preferences.decision(for: message).show)
        checkTrue(preferences.decision(for: calendar).show)
        preferences.feishu.calendar.mode = .disabled
        checkFalse(preferences.decision(for: calendar).show)
        checkTrue(preferences.decision(for: other).show)
        preferences.feishu.other.mode = .disabled
        checkFalse(preferences.decision(for: other).show)
        // Incomplete inactive rules must never stop the user from turning a category off.
        preferences.feishu.filterMessages = true
        preferences.codexCompletion.filterDirectories = true
        checkNil(preferences.validationError)
        preferences.codexCompletion.retention = RetentionPolicy(seconds: 8)
        checkNotEqual(preferences.validationError, nil)
        preferences.codexCompletion.directories = [.init(path: "~/codex-path/learning")]
        preferences.otherApps = RetentionPolicy(mode: .untilHandled)
        try preferences.save(to: defaults)
        checkEqual(NotificationPreferences.load(from: defaults), preferences)
        preferences.otherApps = RetentionPolicy(seconds: 3601)
        checkThrows(try preferences.save(to: defaults))
        preferences.otherApps.mode = .disabled
        preferences.codexCompletion.retention.seconds = 0
        checkThrows(try preferences.save(to: defaults))
        preferences.codexCompletion.retention.mode = .disabled
        checkNil(preferences.validationError)
    }

    func testForegroundTmuxPreferenceAndLegacySettings() throws {
        let name = "notification-foreground-tests-" + UUID().uuidString
        let defaults = try unwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var preferences = try JSONDecoder().decode(NotificationPreferences.self, from: Data("{}".utf8))
        checkFalse(preferences.suppressForegroundTmuxWindow)
        preferences.codexDesktop.mode = .untilHandled
        preferences.codexCompletion.retention.mode = .untilHandled
        let context = TmuxContext(socketPath: "/tmp/test.sock", serverPID: 1, sessionID: "$1", windowID: "@1",
                                  paneID: "%1", sessionName: "session", windowName: "window", paneIndex: 1)
        for kind in [Notice.Kind.approval, .input, .completion] {
            var notice = Notice(source: "Codex CLI", title: "提醒", body: "", kind: kind, tmux: context)
            checkTrue(preferences.decision(for: notice, isForegroundTmuxWindow: true).show)
            preferences.suppressForegroundTmuxWindow = true
            checkFalse(preferences.decision(for: notice, isForegroundTmuxWindow: true).show)
            checkTrue(preferences.decision(for: notice, isForegroundTmuxWindow: false).show)
            notice.tmux = nil
            checkFalse(preferences.decision(for: notice, isForegroundTmuxWindow: true).show)
            notice.source = "Codex 桌面端"; notice.codexClient = .desktop; notice.tmux = context
            checkTrue(preferences.decision(for: notice, isForegroundTmuxWindow: true).show)
            preferences.suppressForegroundTmuxWindow = false
        }
        preferences.suppressForegroundTmuxWindow = true
        let feishu = Notice(source: "飞书", title: "消息", body: "", bundleID: "com.electron.lark", tmux: context)
        checkTrue(preferences.decision(for: feishu, isForegroundTmuxWindow: true).show)
        try preferences.save(to: defaults)
        checkEqual(NotificationPreferences.load(from: defaults), preferences)
    }

    func testCompletionDirectoryFiltersRespectBoundariesAndAliases() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var preferences = NotificationPreferences()
        preferences.codexCompletion.retention = RetentionPolicy(seconds: 12)
        var notice = Notice(source: "Codex CLI", title: "任务完成", body: "", kind: .completion, tmux: codexTmux)
        checkTrue(preferences.decision(for: notice).show) // Explicitly enabled, all projects.
        preferences.codexCompletion.filterDirectories = true
        checkFalse(preferences.decision(for: notice).show)
        preferences.codexCompletion.directories = [.init(path: "~/codex-path/learning/"), .init(path: "/work/Other Project")]
        for path in [home.appendingPathComponent("codex-path/learning").path,
                     home.appendingPathComponent("codex-path/learning/A/Sources").path,
                     "/work/Other Project/nested", "/work/Other Project/./a/../b/"] {
            notice.workingDirectory = path
            checkTrue(preferences.decision(for: notice).show)
        }
        for path in [home.appendingPathComponent("codex-path/learning-other/A").path,
                     home.appendingPathComponent("codex-path/learning/../tool/A").path,
                     "/work/Other Project-extra", "relative/path", "", "/work/Other Project\0bad"] {
            notice.workingDirectory = path
            checkFalse(preferences.decision(for: notice).show)
        }
        notice.workingDirectory = "/work/Other Project"
        preferences.codexCompletion.directories[1].enabled = false
        checkFalse(preferences.decision(for: notice).show)
        notice.kind = .approval
        checkTrue(preferences.decision(for: notice).show) // Completion filters do not affect HITL.
        preferences.codexCompletion.directories = [.init(path: "relative/path")]
        checkNotEqual(preferences.validationError, nil)
        preferences.codexCompletion.directories = []
        checkNotEqual(preferences.validationError, nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("real/project")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory.appendingPathComponent("real"))
        preferences.codexCompletion.directories = [.init(path: alias.path)]
        checkTrue(preferences.codexCompletion.allows(target.path))
        preferences.codexCompletion.directories = [.init(path: directory.appendingPathComponent("real").path)]
        checkTrue(preferences.codexCompletion.allows(alias.appendingPathComponent("project").path))
    }

    func testCompletionHookLifecycleAndPayloadMinimization() throws {
        var payload: [String: Any] = ["hook_event_name": "Stop", "session_id": "session-test", "turn_id": "turn-1",
                                     "cwd": "/work/project/nested", "last_assistant_message": "private-result", "transcript_path": "/private/transcript"]
        func event() throws -> HookEvent {
            try unwrap(CodexHook.parse(JSONSerialization.data(withJSONObject: payload)))
        }
        let completion = try event()
        checkEqual(completion.action, .complete)
        checkEqual(completion.notice?.kind, .completion)
        checkEqual(completion.notice?.workingDirectory, "/work/project/nested")
        checkEqual(completion.key, try event().key)
        let encoded = String(decoding: try JSONEncoder().encode(completion), as: UTF8.self)
        checkFalse(encoded.contains("private-result")); checkFalse(encoded.contains("/private/transcript"))
        payload["turn_id"] = "turn-2"
        checkNotEqual(completion.key, try event().key)
        payload["stop_hook_active"] = true // A continued turn may still finish normally.
        checkEqual(try event().action, .complete)
        for name in ["Interrupt", "UserPromptSubmit", "SessionEnd"] {
            payload["hook_event_name"] = name
            let clear = try event()
            checkNil(clear.notice)
            checkEqual(clear.action, name == "SessionEnd" ? .endSession : .clearSession)
        }
        payload["hook_event_name"] = "SubagentStop"
        checkNil(CodexHook.parse(try JSONSerialization.data(withJSONObject: payload)))
    }

    private func hook(_ event: String, tool: String = "Bash", input: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["hook_event_name": event, "session_id": "session-test",
            "turn_id": "turn-test", "tool_name": tool, "cwd": "/example/project", "tool_input": input])
    }

    func testApprovalLifecycleDoesNotStoreCommand() throws {
        let input = ["command": "echo secret-value"]
        let show = try unwrap(CodexHook.parse(hook("PermissionRequest", input: input)))
        let resolve = try unwrap(CodexHook.parse(hook("PostToolUse", input: input)))
        checkEqual(show.action, .show); checkEqual(show.notice?.kind, .approval)
        checkEqual(show.key, resolve.key); checkEqual(resolve.action, .resolve)
        checkEqual(show.notice?.context, "project")
        checkFalse(String(decoding: try JSONEncoder().encode(show), as: UTF8.self).contains("secret-value"))
        checkNil(CodexHook.parse(try hook("PreToolUse", tool: "Bash")))
        checkEqual(CodexHook.parse(try hook("Stop"))?.action, .complete)
    }

    func testBashApprovalDescriptionDoesNotBreakResolution() throws {
        // Real desktop hooks add an approval description only to PermissionRequest.
        let command = "echo private-value"
        let show = try unwrap(CodexHook.parse(hook("PermissionRequest", input: [
            "command": command, "description": "允许运行这项检查吗？"])))
        let resolve = try unwrap(CodexHook.parse(hook("PostToolUse", input: ["command": command])))
        checkEqual(show.key, resolve.key)
        checkEqual(show.notice?.body, "允许运行这项检查吗？")
        let compatible = try unwrap(CodexHook.parse(hook("PermissionRequest", input: [
            "command": command, "justification": "旧版审批说明"])))
        checkEqual(compatible.key, resolve.key)
        let other = try unwrap(CodexHook.parse(hook("PostToolUse", input: ["command": "echo other"])))
        checkFalse(other.key == show.key)
        checkFalse(String(decoding: try JSONEncoder().encode(show), as: UTF8.self).contains("private-value"))

        // MCP description can be a business argument; keep it in the identity.
        let first = try unwrap(CodexHook.parse(hook("PermissionRequest", tool: "mcp__test__write",
            input: ["description": "first"])))
        let second = try unwrap(CodexHook.parse(hook("PostToolUse", tool: "mcp__test__write",
            input: ["description": "second"])))
        checkFalse(first.key == second.key)
    }

    func testDelayedDesktopApprovalCancellationAndScope() throws {
        var event = try unwrap(CodexHook.parse(hook("PermissionRequest", input: ["command": "echo one"])))
        event.notice?.codexClient = .desktop
        var pending = PendingApprovalNotices()
        checkTrue(pending.hold(event, now: 100))
        checkEqual(pending.count, 1)
        checkTrue(pending.takeReady(now: 104.999).isEmpty)
        pending.resolve(key: "another-key")
        checkEqual(pending.count, 1)
        pending.resolve(key: event.key)
        checkTrue(pending.takeReady(now: 110).isEmpty)

        checkTrue(pending.hold(event, now: 200))
        pending.clear(session: "another-session")
        checkEqual(pending.count, 1)
        pending.clear(session: event.sessionID) // Stop, Interrupt, end and user continuation.
        checkTrue(pending.takeReady(now: 205).isEmpty)
        checkTrue(pending.hold(event, now: 300))
        pending.clear() // Pause, lock, sleep and explicit clear must not replay later.
        checkTrue(pending.takeReady(now: 310).isEmpty)

        event.notice?.codexClient = .cli
        checkFalse(pending.hold(event, now: 400))
        event.notice?.codexClient = .desktop
        event.notice?.kind = .input
        checkFalse(pending.hold(event, now: 400))
        event.notice?.kind = .completion
        checkFalse(pending.hold(event, now: 400))
        event.notice?.kind = .notification
        checkFalse(pending.hold(event, now: 400))
        checkEqual(pending.count, 0)
    }

    func testDelayedApprovalDeadlineDuplicatesAndCapacity() throws {
        var event = try unwrap(CodexHook.parse(hook("PermissionRequest", input: ["command": "echo one"])))
        event.notice?.codexClient = .desktop
        var pending = PendingApprovalNotices(capacity: 2)
        checkTrue(pending.hold(event, now: 100))
        checkTrue(pending.hold(event, now: 104))
        let ready = pending.takeReady(now: 105)
        checkEqual(ready.map(\.key), [event.key])
        checkEqual(ready.first?.createdAt, event.createdAt)
        checkEqual(ready.first?.notice, event.notice)
        checkTrue(pending.takeReady(now: 106).isEmpty)

        checkTrue(pending.hold(event, now: 200))
        var second = event; second.key = "second"; second.notice?.id = second.key
        var third = event; third.key = "third"; third.notice?.id = third.key
        checkTrue(pending.hold(second, now: 201))
        checkTrue(pending.hold(third, now: 202))
        checkEqual(pending.count, 2)
        checkTrue(pending.takeReady(now: 205).isEmpty)
        checkEqual(pending.takeReady(now: 206).map(\.key), ["second"])
        pending.resolve(key: "third") // A cancellation in the deadline's inbox batch wins.
        checkTrue(pending.takeReady(now: 207).isEmpty)
    }

    func testInputAndAsyncInputLifecycle() throws {
        let input: [String: Any] = ["questions": [["question": "Choose a target"]]]
        let show = try unwrap(CodexHook.parse(hook("PreToolUse", tool: "request_user_input", input: input)))
        checkEqual(show.notice?.body, "Choose a target")
        checkEqual(show.notice?.kind, .input)
        checkEqual(CodexHook.parse(try hook("PostToolUse", tool: "request_user_input", input: input))?.key, show.key)
        checkNil(CodexHook.parse(try hook("PostToolUse", tool: "request_user_input_async", input: input)))
    }

    func testInboxDiscardsExpiredEventsAndConsumesOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let fresh = try unwrap(CodexHook.parse(hook("PermissionRequest"), now: now))
        let stale = try unwrap(CodexHook.parse(hook("PermissionRequest"), now: now.addingTimeInterval(-180)))
        try EventInbox.write(fresh, to: directory); try EventInbox.write(stale, to: directory)
        let events = EventInbox.drain(from: directory, now: now)
        checkEqual(events.count, 1); checkEqual(events.first?.createdAt, fresh.createdAt)
        checkTrue(EventInbox.drain(from: directory, now: now).isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        checkEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testProjectLabelsRespectManagedBoundaryAndRepositoryRoots() throws {
        let home = URL(fileURLWithPath: "/Users/example")
        checkEqual(ProjectContext.label(for: "/Users/example/codex-path/tool/notification", home: home), "tool/notification")
        checkEqual(ProjectContext.label(for: "/Users/example/codex-path/tool/notification/Sources/Core", home: home), "tool/notification")
        checkEqual(ProjectContext.label(for: "/Users/example/codex-path-other/tool/notification", home: home), "notification")
        checkEqual(ProjectContext.label(for: "/Users/example/codex-path/tool", home: home), "tool")
        checkEqual(ProjectContext.label(for: "/work/My Project", home: home), "My Project")
        checkNil(ProjectContext.label(for: nil, home: home))
        checkNil(ProjectContext.label(for: "relative/path", home: home))
        let repository = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: repository) }
        try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        checkEqual(ProjectContext.label(for: repository.appendingPathComponent("nested/source").path, home: home), repository.lastPathComponent)
    }

    func testCompactHookContentAndBackwardCompatibility() throws {
        let approval = try unwrap(CodexHook.parse(hook("PermissionRequest", input: ["justification": "运行构建检查", "command": "secret"])))
        checkEqual(approval.notice?.title, "审批请求")
        checkEqual(approval.notice?.body, "运行构建检查")
        let described = try unwrap(CodexHook.parse(hook("PermissionRequest", input: ["description": "发布备份", "command": "secret"])))
        checkEqual(described.notice?.body, "发布备份")
        checkFalse(String(decoding: try JSONEncoder().encode(described), as: UTF8.self).contains("secret"))
        let generic = try unwrap(CodexHook.parse(hook("PermissionRequest", tool: "functions.exec_command")))
        checkEqual(generic.notice?.body, "exec_command")
        let question = try unwrap(CodexHook.parse(hook("PreToolUse", tool: "request_user_input_async", input: ["questions": [["title": "选择环境"], ["title": "选择区域"]]])))
        checkEqual(question.notice?.body, "选择环境\n选择区域")
        var legacy = try unwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(approval.notice)) as? [String: Any])
        legacy.removeValue(forKey: "tmux")
        legacy.removeValue(forKey: "workingDirectory")
        legacy.removeValue(forKey: "codexClient")
        let decoded = try JSONDecoder().decode(Notice.self, from: JSONSerialization.data(withJSONObject: legacy))
        checkNil(decoded.tmux)
        checkNil(decoded.workingDirectory)
        checkNil(decoded.codexClient)
        checkEqual(decoded.context, "project")
    }

    func testDesktopSessionMetadataIsReadOnlyAndFailsSafely() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state_5.sqlite")
        let session = "01a00000-0000-7000-8000-000000000001"
        checkNil(CodexSessionContext.client(sessionID: session, databaseURL: path))
        checkFalse(FileManager.default.fileExists(atPath: path.path))
        var writer: OpaquePointer?
        checkEqual(sqlite3_open(path.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        func sql(_ query: String) {
            checkEqual(sqlite3_exec(writer, query, nil, nil, nil), SQLITE_OK)
        }
        sql("CREATE TABLE threads (id TEXT PRIMARY KEY, source TEXT, originator TEXT, thread_source TEXT)")
        sql("INSERT INTO threads VALUES ('\(session)', 'vscode', 'Codex Desktop', 'user')")
        let before = try Data(contentsOf: path)
        checkEqual(CodexSessionContext.client(sessionID: session, databaseURL: path), .desktop)
        checkEqual(try Data(contentsOf: path), before)
        sql("UPDATE threads SET originator = 'codex-tui'")
        // Both CLI and desktop can have source=vscode; originator separates them.
        checkEqual(CodexSessionContext.client(sessionID: session, databaseURL: path), .cli)
        sql("UPDATE threads SET originator = NULL, thread_source = 'automation'")
        checkEqual(CodexSessionContext.client(sessionID: session, databaseURL: path), .desktop)
        sql("UPDATE threads SET thread_source = 'user'")
        checkNil(CodexSessionContext.client(sessionID: session, databaseURL: path))
        checkNil(CodexSessionContext.client(sessionID: UUID().uuidString, databaseURL: path))
        checkNil(CodexSessionContext.client(sessionID: "' OR 1=1 --", databaseURL: path))
        sql("ALTER TABLE threads RENAME COLUMN originator TO old_originator")
        checkNil(CodexSessionContext.client(sessionID: session, databaseURL: path))
        checkEqual(CodexSessionContext.databaseURL(environment: [:], home: directory)?.path,
                   directory.appendingPathComponent(".codex/state_5.sqlite").path)
        checkEqual(CodexSessionContext.databaseURL(environment: ["CODEX_HOME": directory.path])?.path, path.path)
        checkNil(CodexSessionContext.databaseURL(environment: ["CODEX_HOME": "relative/path"]))
    }

    func testCodexActionableRouting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state_5.sqlite")
        let session = "01a00000-0000-7000-8000-000000000001"
        let rollout = directory.appendingPathComponent("rollout-\(session).jsonl")
        let payload: [String: Any] = ["hook_event_name": "Stop", "session_id": session,
                                      "turn_id": "turn-1", "cwd": directory.path]
        let raw = try unwrap(CodexHook.parse(JSONSerialization.data(withJSONObject: payload)))
        // Title-generation Stop has no persisted thread, transcript or terminal destination.
        checkNil(try unwrap(CodexSessionContext.route(raw, databaseURL: path, environment: [:])).notice)
        checkFalse(FileManager.default.fileExists(atPath: path.path))
        try Data().write(to: rollout)
        checkNil(try unwrap(CodexSessionContext.route(raw, transcriptPath: rollout.path, databaseURL: path, environment: [:])).notice)
        try Data("fixture transcript".utf8).write(to: rollout)
        let fromHook = try unwrap(CodexSessionContext.route(raw, transcriptPath: rollout.path,
                                                          databaseURL: path, environment: [:]))
        checkEqual(fromHook.action, .complete)
        checkNil(fromHook.notice)
        checkEqual(fromHook.sessionID, session) // Completion still clears this session's earlier requests.
        checkEqual(CodexSessionContext.resumeCommand(sessionID: session, transcriptPath: rollout.path,
                                                     databaseURL: path, environment: [:]), "codex resume \(session)")
        let customHome = directory.appendingPathComponent("account 'quoted'; $(literal)").path
        checkEqual(CodexSessionContext.resumeCommand(sessionID: session, transcriptPath: rollout.path,
                   databaseURL: nil, environment: ["CODEX_HOME": customHome]),
                   "CODEX_HOME=\(TmuxBridge.shellQuote(customHome)) codex resume \(session)")
        checkNil(CodexSessionContext.resumeCommand(sessionID: "'bad", transcriptPath: rollout.path, databaseURL: nil))
        var writer: OpaquePointer?
        checkEqual(sqlite3_open(path.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        func sql(_ query: String) { checkEqual(sqlite3_exec(writer, query, nil, nil, nil), SQLITE_OK) }
        sql("CREATE TABLE threads (id TEXT PRIMARY KEY, originator TEXT, thread_source TEXT, rollout_path TEXT)")
        sql("INSERT INTO threads VALUES ('\(session)', 'codex-tui', 'user', '\(rollout.path)')")
        let before = try Data(contentsOf: path)
        let fromIndex = try unwrap(CodexSessionContext.route(raw, databaseURL: path, environment: [:]))
        checkEqual(fromIndex.action, .complete)
        checkNil(fromIndex.notice)
        checkEqual(try Data(contentsOf: path), before)
        var preferences = NotificationPreferences()
        preferences.codexCompletion.retention.mode = .untilHandled
        for kind in [Notice.Kind.approval, .input, .completion] {
            // Older serialized inbox events must also be rejected even if every CLI policy is enabled.
            var oldNotice = Notice(source: "Codex CLI", title: "提醒", body: "", kind: kind,
                                   sessionID: session, codexClient: .cli, resumeCommand: "codex resume \(session)")
            oldNotice = try JSONDecoder().decode(Notice.self, from: JSONEncoder().encode(oldNotice))
            checkFalse(oldNotice.hasCodexDestination)
            checkFalse(preferences.decision(for: oldNotice).show)
            oldNotice.tmux = codexTmux
            checkTrue(oldNotice.hasCodexDestination)
            checkTrue(preferences.decision(for: oldNotice).show)
        }
        for (eventName, tool) in [("PermissionRequest", "Bash"), ("PreToolUse", "request_user_input")] {
            let request = try unwrap(CodexHook.parse(JSONSerialization.data(withJSONObject:
                ["hook_event_name": eventName, "session_id": session, "tool_name": tool])))
            checkNil(CodexSessionContext.route(request, transcriptPath: rollout.path, databaseURL: path, environment: [:]))
            checkTrue(CodexSessionContext.route(request, databaseURL: path, environment: [:], tmuxResolver: { _ in self.codexTmux }) != nil)
        }
        try FileManager.default.removeItem(at: rollout)
        checkNil(try unwrap(CodexSessionContext.route(raw, databaseURL: path, environment: [:])).notice)
        let tmux = TmuxContext(socketPath: "/tmp/test.sock", serverPID: 1, sessionID: "$1", windowID: "@1",
                               paneID: "%1", sessionName: "test", windowName: "test", paneIndex: 0)
        let live = try unwrap(CodexSessionContext.route(raw, databaseURL: path, environment: [:], tmuxResolver: { _ in tmux }))
        checkEqual(live.notice?.tmux, tmux)
        checkNil(live.notice?.resumeCommand)
        try Data("fixture transcript".utf8).write(to: rollout)
        let withFallback = try unwrap(CodexSessionContext.route(raw, databaseURL: path, environment: [:], tmuxResolver: { _ in tmux }))
        checkEqual(withFallback.notice?.resumeCommand, "codex resume \(session)")
        checkTrue(try unwrap(withFallback.notice).hasCodexDestination)
        sql("UPDATE threads SET originator = 'Codex Desktop'")
        let desktop = try unwrap(CodexSessionContext.route(raw, databaseURL: path, environment: [:], tmuxResolver: { _ in
            checkTrue(false); return tmux
        }))
        checkEqual(desktop.notice?.codexClient, .desktop)
        checkNil(desktop.notice?.tmux)
        for action in [HookEvent.Action.resolve, .clearSession, .endSession] {
            var end = raw; end.action = action; end.notice = nil
            checkEqual(CodexSessionContext.route(end, databaseURL: nil)?.action, action)
        }
        sql("ALTER TABLE threads RENAME COLUMN originator TO old_originator")
        // Unknown client metadata and a readable transcript are insufficient without direct navigation.
        checkNil(try unwrap(CodexSessionContext.route(raw, transcriptPath: rollout.path, databaseURL: path, environment: [:])).notice)
    }

    func testDesktopThreadLinkAndNoticeRoundTrip() throws {
        let session = "01a00000-0000-7000-8000-000000000001"
        checkEqual(CodexSessionContext.desktopThreadURL(sessionID: session)?.absoluteString, "codex://threads/\(session)")
        for invalid: String? in [nil, "", "new?prompt=run", "../settings", session + "?hostId=other"] {
            checkNil(CodexSessionContext.desktopThreadURL(sessionID: invalid))
        }
        let notice = Notice(source: "Codex 桌面端", title: "审批请求", body: "发布备份", kind: .approval,
                            sessionID: session, codexClient: .desktop)
        checkEqual(try JSONDecoder().decode(Notice.self, from: JSONEncoder().encode(notice)), notice)
        var preferences = NotificationPreferences()
        checkFalse(preferences.decision(for: notice).show)
        preferences.otherApps.mode = .untilHandled
        let system = Notice(source: "ChatGPT", title: "提醒", body: "", bundleID: CodexSessionContext.desktopBundleID)
        checkTrue(preferences.acceptsSource(system))
        checkFalse(preferences.decision(for: system).show) // Other-app policy cannot re-enable desktop.
        for kind in [Notice.Kind.approval, .input, .completion] {
            var desktop = notice; desktop.kind = kind
            checkFalse(preferences.decision(for: desktop).show)
            preferences.codexDesktop = RetentionPolicy(seconds: 19)
            checkTrue(preferences.decision(for: desktop).show)
            checkEqual(preferences.decision(for: desktop).retention.duration, 19)
            preferences.codexDesktop.mode = .disabled
        }
        preferences.codexDesktop.mode = .untilHandled
        checkNil(preferences.decision(for: system).retention.duration)
        checkTrue(preferences.decision(for: system).show)
        preferences.codex.mode = .disabled
        checkTrue(preferences.decision(for: notice).show)
        var completion = notice; completion.kind = .completion
        checkTrue(preferences.decision(for: completion).show)
        preferences.codexCompletion.retention.mode = .untilHandled
        preferences.codexCompletion.filterDirectories = true
        preferences.codexCompletion.directories = [.init(path: "/work/learning")]
        completion.workingDirectory = "/work/routine/AutoBackup"
        checkTrue(preferences.decision(for: completion).show) // CLI directory filters are independent.
        completion.workingDirectory = "/work/learning/project"
        checkTrue(preferences.decision(for: completion).show)
        completion.bundleID = "other.app"
        preferences.otherApps.mode = .disabled
        checkFalse(preferences.decision(for: completion).show)

        let name = "notification-desktop-tests-" + UUID().uuidString
        let defaults = try unwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try preferences.save(to: defaults)
        checkEqual(NotificationPreferences.load(from: defaults), preferences)
        var legacy = try unwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        legacy.removeValue(forKey: "codexDesktop")
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: NotificationPreferences.defaultsKey)
        let migrated = NotificationPreferences.load(from: defaults)
        checkEqual(migrated.codexDesktop.mode, .disabled)
        preferences.codexDesktop = RetentionPolicy(mode: .disabled)
        checkEqual(migrated, preferences) // All existing fields survive an upgrade.
        preferences.codexDesktop = RetentionPolicy(seconds: 0)
        checkThrows(try preferences.save(to: defaults))
        preferences.codexDesktop.seconds = 3601
        checkThrows(try preferences.save(to: defaults))
        preferences.codexDesktop.mode = .disabled
        checkNil(preferences.validationError)
    }

    func testCommandTimeoutAndLiteralArguments() {
        let before = ProcessInfo.processInfo.systemUptime
        checkNil(LocalCommand.run(URL(fileURLWithPath: "/bin/sleep"), ["2"], timeout: 0.05))
        checkTrue(ProcessInfo.processInfo.systemUptime - before < 1)
        checkEqual(LocalCommand.run(URL(fileURLWithPath: "/usr/bin/printf"), ["%s", "literal; $(printf injected)"]), "literal; $(printf injected)")
    }

    func testSourceMonitorWakesOnWALCommitsWithoutWaitingForFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("db")
        var writer: OpaquePointer?
        checkEqual(sqlite3_open(path.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        checkEqual(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; CREATE TABLE record(rec_id INTEGER PRIMARY KEY, data BLOB)", nil, nil, nil), SQLITE_OK)
        let data = try payload()
        func insert(_ id: Int) {
            var statement: OpaquePointer?
            checkEqual(sqlite3_prepare_v2(writer, "INSERT INTO record VALUES (?, ?)", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(id))
            _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            checkEqual(sqlite3_step(statement), SQLITE_DONE)
        }
        insert(1)
        let ready = DispatchSemaphore(value: 0), received = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "test.notification.wal")
        let reader = NotificationDatabase(path: path)
        var reasons: [SourceMonitor.Reason] = [], failuresToRead = 0
        let monitor = SourceMonitor(paths: [path, URL(fileURLWithPath: path.path + "-wal"), directory],
                                    queue: queue, fallbackInterval: 60) { reason in
            do {
                for _ in try reader.poll() { reasons.append(reason); received.signal() }
            } catch { failuresToRead += 1 }
            if reason == .initial { ready.signal() }
        }
        monitor.start()
        defer { monitor.stop(); queue.sync {} }
        checkEqual(ready.wait(timeout: .now() + 2), .success)
        var samples: [Double] = []
        for id in 2...9 {
            let start = ProcessInfo.processInfo.systemUptime
            insert(id)
            checkEqual(received.wait(timeout: .now() + 2), .success)
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        queue.sync {
            checkEqual(failuresToRead, 0); checkEqual(reasons.count, 8)
            checkTrue(reasons.allSatisfy { $0 == .fileChange })
        }
        let sorted = samples.sorted()
        let median = (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
        print(String(format: "WAL commit-to-read: n=%d, median=%.1f ms, max=%.1f ms (60 s fallback not used)", sorted.count, median, sorted.last!))
    }

    func testSourceMonitorHandlesLateFilesReplacementAndFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("events")
        let ready = DispatchSemaphore(value: 0), received = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "test.notification.files")
        var latest = ""
        let monitor = SourceMonitor(paths: [path, directory], queue: queue, fallbackInterval: 60) { reason in
            if let text = try? String(contentsOf: path), text != latest { latest = text; received.signal() }
            if reason == .initial { ready.signal() }
        }
        monitor.start()
        checkEqual(ready.wait(timeout: .now() + 2), .success)
        // The watched file does not exist at startup, then is atomically replaced twice.
        for text in ["first", "replacement"] {
            try text.write(to: path, atomically: true, encoding: .utf8)
            checkEqual(received.wait(timeout: .now() + 2), .success)
        }
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("-append".utf8)); try handle.close()
        checkEqual(received.wait(timeout: .now() + 2), .success)
        queue.sync { checkEqual(latest, "replacement-append") }
        monitor.stop(); queue.sync {}

        // Missing vnode coverage must still poll on every healthy fallback tick.
        let fallback = SourceMonitor(paths: [], queue: queue, fallbackInterval: 0.1) { reason in
            if reason == .initial { ready.signal() }
            if reason == .fallback { received.signal() }
        }
        fallback.start()
        defer { fallback.stop(); queue.sync {} }
        checkEqual(ready.wait(timeout: .now() + 2), .success)
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<3 { checkEqual(received.wait(timeout: .now() + 1), .success) }
        checkTrue(ProcessInfo.processInfo.systemUptime - start < 0.6)
    }

    func testTmuxNavigationWithSuspendedPreferredClient() throws {
        guard let bridge = TmuxBridge.installed() else { print("SKIP tmux client integration: tmux unavailable"); return }
        let directory = URL(fileURLWithPath: "/tmp/notification-clients-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socket = directory.appendingPathComponent("socket").path
        defer {
            _ = LocalCommand.run(bridge.executable, ["-S", socket, "kill-server"])
            try? FileManager.default.removeItem(at: directory)
        }
        func run(_ arguments: [String]) throws -> String {
            try unwrap(LocalCommand.run(bridge.executable, ["-u", "-S", socket] + arguments, timeout: 1))
        }
        _ = try run(["-f", "/dev/null", "new-session", "-d", "-s", "visible", "/bin/sleep 60"])
        let identity = try run(["display-message", "-p", "#{pid}|#{session_id}|#{pane_pid}"]).trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        guard identity.count == 3 else { throw TmuxError.unavailable }
        let panePID = try unwrap(Int32(identity[2]))
        let context = try unwrap(bridge.capture(environment: ["TMUX": "\(socket),\(identity[0]),0"], processID: panePID))
        var terminals: [(Int32, Int32)] = []
        var clients: [Process] = []
        defer {
            for client in clients {
                if client.isRunning { _ = Darwin.kill(client.processIdentifier, SIGKILL) }
                client.waitUntilExit()
            }
            for (master, slave) in terminals { Darwin.close(master); Darwin.close(slave) }
        }
        func attach(_ session: String, command: String? = nil) throws -> TmuxAttachedClient {
            var master: Int32 = -1; var slave: Int32 = -1
            var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw TmuxError.unavailable }
            terminals.append((master, slave))
            let handle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
            let process = Process(); process.executableURL = bridge.executable
            process.arguments = ["-S", socket, "attach-session", "-t", session]
            if let command {
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "exec \(command)"]
            }
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "TMUX"); environment.removeValue(forKey: "TMUX_PANE")
            environment["TERM"] = "xterm-256color"; process.environment = environment
            process.standardInput = handle; process.standardOutput = handle; process.standardError = handle
            try process.run(); clients.append(process)
            for _ in 0..<25 {
                if let client = bridge.attachedClients(for: context).first(where: { $0.pid == process.processIdentifier }) { return client }
                usleep(20_000)
            }
            throw TmuxError.clientChanged
        }
        let visible = try attach("visible", command: try unwrap(bridge.attachCommand(for: context)))
        _ = try run(["set-option", "-g", "focus-events", "on"])
        _ = try run(["set-option", "-as", "terminal-features", ",xterm*:focus"])
        // Real PTY focus reports, isolated from the user's terminal and tmux server.
        func focus(_ sequence: String, terminal: Int) throws {
            let data = Data(sequence.utf8)
            let written = data.withUnsafeBytes { Darwin.write(terminals[terminal].0, $0.baseAddress, $0.count) }
            checkEqual(written, data.count)
            usleep(50_000)
        }
        try focus("\u{1b}[I", terminal: 0)
        checkTrue(bridge.isInForegroundWindow(context, foregroundProcessID: visible.pid))
        checkFalse(bridge.isInForegroundWindow(context, foregroundProcessID: panePID))
        let sibling = try run(["split-window", "-d", "-t", context.paneID, "-P", "-F", "#{pane_pid}", "/bin/sleep 60"])
        let siblingPID = try unwrap(Int32(sibling.trimmingCharacters(in: .whitespacesAndNewlines)))
        let siblingContext = try unwrap(bridge.capture(environment: ["TMUX": "\(socket),\(identity[0]),0"], processID: siblingPID))
        checkNotEqual(siblingContext.paneID, context.paneID)
        checkTrue(bridge.isInForegroundWindow(siblingContext, foregroundProcessID: visible.pid))
        _ = try run(["new-window", "-t", context.sessionID, "/bin/sleep 60"])
        checkFalse(bridge.isInForegroundWindow(context, foregroundProcessID: visible.pid))
        _ = try run(["select-window", "-t", context.windowID])
        try focus("\u{1b}[O", terminal: 0)
        checkFalse(bridge.isInForegroundWindow(context, foregroundProcessID: visible.pid))
        try focus("\u{1b}[I", terminal: 0)
        _ = try run(["set-option", "-g", "focus-events", "off"])
        checkFalse(bridge.isInForegroundWindow(context, foregroundProcessID: visible.pid))
        _ = try run(["set-option", "-g", "focus-events", "on"])
        _ = try run(["new-session", "-d", "-s", "suspended", "/bin/sleep 60"])
        let hidden = try attach("suspended")
        checkFalse(bridge.isInForegroundWindow(context, foregroundProcessID: getpid())) // Ambiguous focused clients.
        try focus("\u{1b}[O", terminal: 1)
        checkTrue(bridge.isInForegroundWindow(context, foregroundProcessID: getpid()))
        checkFalse(bridge.isInForegroundWindow(context, foregroundProcessID: hidden.pid))
        _ = try run(["suspend-client", "-t", hidden.name])
        usleep(50_000)
        checkFalse(bridge.attachedClients(for: context).contains { $0.pid == hidden.pid })
        checkFalse(bridge.isInForegroundWindow(context, foregroundProcessID: hidden.pid))
        // The implicit current client can be hidden, even with a usable visible client.
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TMUX"); environment.removeValue(forKey: "TMUX_PANE")
        let implicit = LocalCommand.run(bridge.executable, ["-u", "-S", socket, "display-message", "-p", "#{client_pid}"], environment: environment)?.trimmingCharacters(in: .whitespacesAndNewlines)
        checkEqual(implicit, String(hidden.pid))
        try bridge.switchClient(visible, to: context)
        checkEqual(bridge.attachedClients(for: context).first { $0.pid == visible.pid }?.sessionID, context.sessionID)
        checkThrows(try bridge.switchClient(hidden, to: context))
    }

    func testTmuxCaptureNavigationAndStaleTargetsOnIsolatedServer() throws {
        guard let bridge = TmuxBridge.installed() else { print("SKIP isolated tmux integration: tmux unavailable"); return }
        // Match a menu-bar app's non-UTF-8 launch environment, including client parsing.
        let localeKeys = ["LANG", "LC_CTYPE", "LC_ALL"]
        let savedLocale = ProcessInfo.processInfo.environment
        for key in localeKeys { unsetenv(key) }
        setenv("LC_ALL", "C", 1)
        defer {
            for key in localeKeys {
                if let value = savedLocale[key] { setenv(key, value, 1) }
                else { unsetenv(key) }
            }
        }
        let directory = URL(fileURLWithPath: "/tmp/notification tests,'\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let socket = directory.appendingPathComponent("socket").path
        defer {
            _ = LocalCommand.run(bridge.executable, ["-S", socket, "kill-server"])
            try? FileManager.default.removeItem(at: directory)
        }
        func run(_ arguments: [String]) throws -> String {
            guard let output = LocalCommand.run(bridge.executable, ["-u", "-S", socket] + arguments, timeout: 1) else {
                throw NSError(domain: "CoreChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "tmux failed: \(arguments)"])
            }
            return output
        }
        _ = try run(["-f", "/dev/null", "new-session", "-d", "-s", "unit-session", "-n", "work 'quoted'; literal", "/bin/sleep 60"])
        let identity = try run(["display-message", "-p", "#{pid}\n#{session_id}\n#{pane_id}"]).split(separator: "\n").map(String.init)
        checkEqual(identity.count, 3)
        guard identity.count == 3 else { throw TmuxError.unavailable }
        let environment = ["TMUX": "\(socket),\(identity[0]),\(identity[1].dropFirst())", "TMUX_PANE": identity[2]]
        let panePID = try unwrap(Int32(try run(["display-message", "-p", "-t", identity[2], "#{pane_pid}"]).trimmingCharacters(in: .whitespacesAndNewlines)))
        let original = try unwrap(bridge.capture(environment: environment, processID: panePID))
        checkEqual(original.sessionName, "unit-session")
        checkEqual(original.windowName, "work 'quoted'; literal")
        checkEqual(original.label, "unit-session/work 'quoted'; literal/pane-0")
        checkEqual(original.socketPath, socket)
        checkEqual(try JSONDecoder().decode(TmuxContext.self, from: JSONEncoder().encode(original)), original)
        checkNil(bridge.capture(environment: [:]))
        // A daemon outside the pane must never inherit a false origin from TMUX_PANE.
        checkNil(bridge.capture(environment: environment, processID: 1))
        _ = try run(["rename-window", "-t", original.windowID, "renamed 中文"])
        let other = try run(["split-window", "-d", "-t", original.paneID, "-P", "-F", "#{pane_id}", "/bin/sleep 60"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try run(["select-pane", "-t", other])
        _ = try run(["new-window", "-t", original.sessionID, "-n", "other-window", "/bin/sleep 60"])
        let selected = try bridge.select(original)
        checkEqual(selected.windowName, "renamed 中文")
        checkEqual(try run(["display-message", "-p", "-t", original.sessionID, "#{pane_id}"]).trimmingCharacters(in: .whitespacesAndNewlines), original.paneID)
        checkTrue(bridge.attachedClients(for: selected).isEmpty)
        let command = try unwrap(bridge.attachCommand(for: selected))
        checkFalse(command.contains(original.windowName))
        checkEqual(LocalCommand.run(URL(fileURLWithPath: "/bin/sh"), ["-n", "-c", command]), "")
        // Attach a real client on an isolated pseudo-terminal, then switch only that client.
        _ = try run(["new-session", "-d", "-s", "other-session", "/bin/sleep 60"])
        var master: Int32 = -1; var slave: Int32 = -1
        var terminalSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        checkEqual(openpty(&master, &slave, nil, nil, &terminalSize), 0)
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        let clientProcess = Process()
        clientProcess.executableURL = bridge.executable
        clientProcess.arguments = ["-S", socket, "attach-session", "-t", "other-session"]
        var clientEnvironment = ProcessInfo.processInfo.environment
        clientEnvironment.removeValue(forKey: "TMUX"); clientEnvironment.removeValue(forKey: "TMUX_PANE")
        clientEnvironment["TERM"] = "xterm-256color"
        clientProcess.environment = clientEnvironment
        clientProcess.standardInput = terminal; clientProcess.standardOutput = terminal; clientProcess.standardError = terminal
        try clientProcess.run()
        defer {
            if clientProcess.isRunning { _ = Darwin.kill(clientProcess.processIdentifier, SIGKILL) }
            clientProcess.waitUntilExit()
            Darwin.close(master); Darwin.close(slave)
        }
        var client: TmuxAttachedClient?
        for _ in 0..<25 {
            client = bridge.attachedClients(for: selected).first { $0.pid == clientProcess.processIdentifier }
            if client != nil { break }
            usleep(20_000)
        }
        let attached = try unwrap(client)
        checkNotEqual(attached.sessionID, selected.sessionID)
        try bridge.switchClient(attached, to: selected)
        checkEqual(bridge.attachedClients(for: selected).first { $0.pid == attached.pid }?.sessionID, selected.sessionID)

        // A suspended old attachment and its replacement share the same tty. Explicit
        // switch-client -c resolves the hidden old client and reports success, leaving
        // the visible replacement unchanged. This is the real notification regression.
        _ = try run(["suspend-client", "-t", attached.name])
        usleep(50_000)
        checkEqual(Darwin.kill(clientProcess.processIdentifier, SIGSTOP), 0)
        let replacementProcess = Process()
        replacementProcess.executableURL = bridge.executable
        replacementProcess.arguments = ["-S", socket, "attach-session", "-t", "other-session"]
        replacementProcess.environment = clientEnvironment
        replacementProcess.standardInput = terminal
        replacementProcess.standardOutput = terminal
        replacementProcess.standardError = terminal
        try replacementProcess.run()
        defer {
            if replacementProcess.isRunning { _ = Darwin.kill(replacementProcess.processIdentifier, SIGKILL) }
            replacementProcess.waitUntilExit()
        }
        var replacement: TmuxAttachedClient?
        for _ in 0..<25 {
            replacement = bridge.attachedClients(for: selected).first { $0.pid == replacementProcess.processIdentifier }
            if replacement != nil { break }
            usleep(20_000)
        }
        let foreground = try unwrap(replacement)
        checkEqual(foreground.name, attached.name)
        checkNotEqual(foreground.sessionID, selected.sessionID)
        _ = try run(["switch-client", "-c", foreground.name, "-t", selected.sessionID])
        checkEqual(bridge.attachedClients(for: selected).first { $0.pid == foreground.pid }?.sessionID, foreground.sessionID)
        checkEqual(bridge.attachedClients(for: selected).first?.pid, foreground.pid)
        checkThrows(try bridge.switchClient(attached, to: selected))
        try bridge.switchClient(foreground, to: selected)
        checkEqual(bridge.attachedClients(for: selected).first { $0.pid == foreground.pid }?.sessionID, selected.sessionID)
        let destinations = try run(["list-clients", "-F", "#{client_pid}|#{session_id}|#{window_id}|#{pane_id}"])
        checkTrue(destinations.contains("\(foreground.pid)|\(selected.sessionID)|\(selected.windowID)|\(selected.paneID)"))
        var invalid = original; invalid.paneID = "%0; display-message injected"
        checkNil(bridge.attachCommand(for: invalid))
        var stale = original; stale.serverPID += 1
        checkNil(bridge.refreshed(stale))
        checkThrows(try bridge.select(stale))

        // A second CLI connected to a shared server has its own current session in the pane title.
        let fakeCLI = directory.appendingPathComponent("codex")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: fakeCLI)
        _ = try unwrap(LocalCommand.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", fakeCLI.path], timeout: 2))
        let remote = try run(["new-window", "-d", "-t", original.sessionID, "-n", "remote", "-P", "-F", "#{pane_id}", "\(TmuxBridge.shellQuote(fakeCLI.path)) 60"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let thread = "12345678-1234-5678-90ab-cdef12345678"
        _ = try run(["select-pane", "-t", remote, "-T", "project | Test | \(thread.prefix(26))... | Context 77% left"])
        let remoteContext = try unwrap(bridge.capture(sessionID: thread, environment: environment, processID: 1))
        checkEqual(remoteContext.paneID, remote)
        checkNotEqual(remoteContext.paneID, original.paneID)
        checkNil(bridge.capture(sessionID: UUID().uuidString, environment: environment, processID: 1))
        _ = try run(["select-pane", "-t", remote, "-T", "project | \(thread.prefix(8))..."])
        checkNil(bridge.capture(sessionID: thread, environment: environment, processID: 1))
        _ = try run(["select-pane", "-t", remote, "-T", "project | \(thread)"])
        checkEqual(bridge.capture(sessionID: thread, environment: environment, processID: 1)?.paneID, remote)
        let duplicate = try run(["new-window", "-d", "-t", original.sessionID, "-n", "duplicate", "-P", "-F", "#{pane_id}", "\(TmuxBridge.shellQuote(fakeCLI.path)) 60"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try run(["select-pane", "-t", duplicate, "-T", "project | \(thread)"])
        checkNil(bridge.capture(sessionID: thread, environment: environment, processID: 1))
        _ = try run(["kill-pane", "-t", duplicate])
        _ = try run(["kill-pane", "-t", remote])

        // A task launcher stays in the foreground while its Codex child owns the session title.
        let launcher = directory.appendingPathComponent("launcher.sh")
        try Data("#!/bin/sh\n\(TmuxBridge.shellQuote(fakeCLI.path)) 60 &\nwait\n".utf8).write(to: launcher)
        let wrapped = try run(["new-window", "-d", "-t", original.sessionID, "-n", "wrapped", "-P", "-F", "#{pane_id}", "/bin/sh \(TmuxBridge.shellQuote(launcher.path))"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try run(["select-pane", "-t", wrapped, "-T", "project | \(thread.prefix(26))..."])
        var wrappedContext: TmuxContext?
        for _ in 0..<25 {
            wrappedContext = bridge.capture(sessionID: thread, environment: environment, processID: 1)
            if wrappedContext != nil { break }
            usleep(20_000)
        }
        checkNotEqual(try run(["display-message", "-p", "-t", wrapped, "#{pane_current_command}"]).trimmingCharacters(in: .whitespacesAndNewlines), "codex")
        checkEqual(wrappedContext?.paneID, wrapped)
        checkNil(bridge.capture(sessionID: UUID().uuidString, environment: environment, processID: 1))
        // Stale matching titles on panes with no Codex process must not become navigation targets.
        _ = try run(["select-pane", "-t", other, "-T", "project | \(thread)"])
        checkEqual(bridge.capture(sessionID: thread, environment: environment, processID: 1)?.paneID, wrapped)
        _ = try run(["kill-pane", "-t", wrapped])
        checkNil(bridge.capture(sessionID: thread, environment: environment, processID: 1))
        _ = try run(["kill-pane", "-t", original.paneID])
        checkNil(bridge.refreshed(original))
        checkThrows(try bridge.select(original))

        // Restart the same socket, reuse old pane IDs, and resume the Codex thread
        // in a different pane. An inherited TMUX value still names the old PID.
        _ = try run(["kill-server"])
        _ = try run(["-f", "/dev/null", "new-session", "-d", "-s", "after-restart", "/bin/sleep 60"])
        let resumed = try run(["new-window", "-d", "-n", "resumed", "-P", "-F", "#{pane_id}", "\(TmuxBridge.shellQuote(fakeCLI.path)) 60"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try run(["select-pane", "-t", resumed, "-T", "project | \(thread)"])
        let recovered = try unwrap(bridge.capture(sessionID: thread, environment: environment, processID: 1))
        checkEqual(recovered.paneID, resumed)
        checkNotEqual(recovered.serverPID, original.serverPID)
        checkEqual(bridge.refreshed(remoteContext)?.paneID, resumed)
        checkNil(bridge.refreshed(original)) // A recycled %0 is not the original shell.
        _ = try run(["kill-pane", "-t", resumed])
        checkNil(bridge.refreshed(remoteContext)) // Never fall back to a recycled ID.
    }
}


private var failures = 0
private func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    failures += 1
    print("FAIL \(file):\(line): \(message)")
}
private func checkEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) {
    if a != b { fail("Expected \(a) == \(b)", file: file, line: line) }
}
private func checkNotEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) {
    if a == b { fail("Expected different values", file: file, line: line) }
}
private func checkTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !value { fail("Expected true", file: file, line: line) }
}
private func checkFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    checkTrue(!value, file: file, line: line)
}
private func checkNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    checkTrue(value == nil, file: file, line: line)
}
private func checkThrows<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression(); fail("Expected error", file: file, line: line) } catch { }
}
private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { throw NSError(domain: "CoreChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing value at \(file):\(line)"]) }
    return value
}

@main struct RunChecks {
    static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--locate-tmux" {
            print(TmuxBridge.installed()?.capture(sessionID: CommandLine.arguments[2])?.label ?? "unresolved")
            return
        }
        let suite = NotificationCoreTests()
        let tests: [(String, () throws -> Void)] = [
            ("payload parsing and dismissal deduplication", suite.testPayloadChangesAndDismissalDeduplication),
            ("live database inserts, updates, startup baseline", suite.testDatabaseSkipsHistoryButReceivesInsertsAndUpdates),
            ("missing database does not create a file", suite.testMissingDatabaseIsNotCreated),
            ("banner fields reject mixed cards and unrelated UI", suite.testBannerFieldsDoNotMixCardsOrControls),
            ("cross-source pairing preserves repeated messages", suite.testSystemReceiptPairsPreserveRepeatedMessages),
            ("database baseline and repeated identities do not replay", suite.testDatabaseBaselineAndRepeatedIdentitiesDoNotReplay),
            ("preferences defaults, persistence and validation", suite.testPreferencesDefaultsPersistenceAndValidation),
            ("foreground tmux preference and legacy settings", suite.testForegroundTmuxPreferenceAndLegacySettings),
            ("Feishu classification and independent retention", suite.testFeishuClassificationAndIndependentRetention),
            ("Feishu message filters and category boundary", suite.testFeishuMessageFiltersAndClassificationBoundary),
            ("other applications are opt-in and retain source boundaries", suite.testOnlyConfiguredApplicationsAreAllowed),
            ("disabled policies and independent configuration persistence", suite.testDisabledPoliciesOverrideFiltersAndPersistIndependently),
            ("completion directory boundaries, multiple roots and symlinks", suite.testCompletionDirectoryFiltersRespectBoundariesAndAliases),
            ("completion hook lifecycle and payload minimization", suite.testCompletionHookLifecycleAndPayloadMinimization),
            ("approval lifecycle and payload minimization", suite.testApprovalLifecycleDoesNotStoreCommand),
            ("Bash approval description and execution resolution", suite.testBashApprovalDescriptionDoesNotBreakResolution),
            ("desktop approval delay, cancellation and source boundaries", suite.testDelayedDesktopApprovalCancellationAndScope),
            ("desktop approval deadline, duplicate receipts and bounded capacity", suite.testDelayedApprovalDeadlineDuplicatesAndCapacity),
            ("sync and async input lifecycle", suite.testInputAndAsyncInputLifecycle),
            ("inbox expiry, permissions, consume once", suite.testInboxDiscardsExpiredEventsAndConsumesOnce),
            ("project labels and managed path boundaries", suite.testProjectLabelsRespectManagedBoundaryAndRepositoryRoots),
            ("compact content and legacy event decoding", suite.testCompactHookContentAndBackwardCompatibility),
            ("read-only desktop metadata, client boundaries and schema fallback", suite.testDesktopSessionMetadataIsReadOnlyAndFailsSafely),
            ("desktop thread links and event round trip", suite.testDesktopThreadLinkAndNoticeRoundTrip),
            ("Codex actionable routing and persisted resume commands", suite.testCodexActionableRouting),
            ("local command timeout and literal arguments", suite.testCommandTimeoutAndLiteralArguments),
            ("WAL writes wake source reads without fallback", suite.testSourceMonitorWakesOnWALCommitsWithoutWaitingForFallback),
            ("source monitor late creation, replacement and fallback", suite.testSourceMonitorHandlesLateFilesReplacementAndFallback),
            ("isolated tmux capture, navigation, rename and stale pane", suite.testTmuxCaptureNavigationAndStaleTargetsOnIsolatedServer),
            ("tmux navigation with suspended preferred client", suite.testTmuxNavigationWithSuspendedPreferredClient)
        ]
        for (name, test) in tests {
            let before = failures
            do { try test() } catch { fail("\(name): \(error)") }
            if failures == before { print("PASS \(name)") }
        }
        print("\(tests.count) checks; \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
