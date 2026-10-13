import Foundation

public struct RetentionPolicy: Codable, Equatable {
    public enum Mode: String, Codable, CaseIterable { case disabled, timed, untilHandled }
    public var mode: Mode
    public var seconds: Int
    public init(mode: Mode = .timed, seconds: Int = 10) { self.mode = mode; self.seconds = seconds }
    public var isEnabled: Bool { mode != .disabled }
    public var duration: TimeInterval? {
        switch mode {
        case .disabled: return 0
        case .untilHandled: return nil
        case .timed: return TimeInterval(min(3600, max(1, seconds)))
        }
    }
}

public struct CompletionDirectory: Codable, Equatable, Identifiable {
    public var id: UUID
    public var enabled: Bool
    public var path: String
    public init(id: UUID = UUID(), enabled: Bool = true, path: String = "") {
        self.id = id; self.enabled = enabled; self.path = path
    }
}

public struct CodexCompletionPreferences: Codable, Equatable {
    public var retention = RetentionPolicy(mode: .disabled)
    public var filterDirectories = false
    public var directories: [CompletionDirectory] = []
    public init() {}

    public func allows(_ directory: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard filterDirectories else { return true }
        guard let current = ProjectContext.directoryURL(directory, home: home) else { return false }
        return directories.filter(\.enabled).contains { rule in
            guard let root = ProjectContext.directoryURL(rule.path, home: home) else { return false }
            return current.pathComponents.starts(with: root.pathComponents)
                || current.resolvingSymlinksInPath().pathComponents.starts(with: root.resolvingSymlinksInPath().pathComponents)
        }
    }

    public var validationError: String? {
        guard retention.isEnabled, filterDirectories else { return nil }
        let active = directories.filter(\.enabled)
        if active.isEmpty { return "开启完成通知的目录过滤后，请至少启用一个目录。" }
        if active.contains(where: { ProjectContext.directoryURL($0.path) == nil }) {
            return "完成通知的目录请填写绝对路径或 ~/ 开头的路径。"
        }
        return nil
    }
}

public enum FeishuNoticeType: String, Codable, CaseIterable, Identifiable {
    case message, calendar, other
    public var id: String { rawValue }
    public var title: String {
        switch self { case .message: return "飞书消息"; case .calendar: return "飞书日历"
        case .other: return "飞书其他通知" }
    }
}

public struct MessageCondition: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable, CaseIterable { case contains, mentionsMe, urgent }
    public var id: UUID
    public var enabled: Bool
    public var kind: Kind
    public var keyword: String
    public init(id: UUID = UUID(), enabled: Bool = true, kind: Kind = .contains, keyword: String = "") {
        self.id = id; self.enabled = enabled; self.kind = kind; self.keyword = keyword
    }
}

public struct FeishuPreferences: Codable, Equatable {
    public enum MatchMode: String, Codable, CaseIterable { case any, all }
    public var message = RetentionPolicy()
    public var calendar = RetentionPolicy()
    public var other = RetentionPolicy()
    public var filterMessages = false
    public var matchMode = MatchMode.any
    public var conditions: [MessageCondition] = []
    // These are editable text heuristics, not claims about Feishu's internal message attributes.
    public static let defaultCalendarKeywords = "日历助手\n即将开始日程\n日程提醒\n日程邀请\n日程变更\n日程取消\nCalendar reminder"
    public var calendarKeywords = FeishuPreferences.defaultCalendarKeywords
    public var otherKeywords = "审批提醒\n任务助手\n邮箱助手\n文档助手"
    public var mentionKeywords = "@你\n@我\n提到了你\nmentioned you"
    public static let defaultUrgentKeywords = "⚡加急⚡\n[加急]\n【加急】\n[Urgent]"
    public var urgentKeywords = FeishuPreferences.defaultUrgentKeywords

    public init() {}

    public static func isFeishu(_ notice: Notice) -> Bool {
        if let bundle = notice.bundleID {
            return ["com.electron.lark", "com.bytedance.lark", "com.larksuite.lark"].contains(bundle.lowercased())
        }
        return ["飞书", "feishu", "lark"].contains(notice.source.lowercased())
    }

    public static func keywords(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func containsAny(_ keywords: String, in text: String, emojiMarker: Bool = false) -> Bool {
        func normalize(_ value: String, compact: Bool) -> String {
            let value = emojiMarker ? value.replacingOccurrences(of: "\u{FE0F}", with: "").replacingOccurrences(of: "\u{FE0E}", with: "") : value
            return compact ? value.components(separatedBy: .whitespacesAndNewlines).joined() : value
        }
        return Self.keywords(keywords).contains { keyword in
            let compact = emojiMarker && keyword.contains("⚡")
            return normalize(text, compact: compact).range(of: normalize(keyword, compact: compact), options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    public func classify(_ notice: Notice) -> FeishuNoticeType {
        func type(in text: String) -> FeishuNoticeType? {
            if containsAny(calendarKeywords, in: text) { return .calendar }
            if containsAny(otherKeywords, in: text) { return .other }
            return nil
        }
        // A calendar assistant's reminder can itself mention a meeting; prefer its explicit title.
        return type(in: notice.title) ?? type(in: notice.body) ?? .message
    }

    public func retention(for type: FeishuNoticeType) -> RetentionPolicy {
        switch type { case .message: return message; case .calendar: return calendar
        case .other: return other }
    }

    public func allowsMessage(_ notice: Notice) -> Bool {
        guard filterMessages else { return true }
        let active = conditions.filter(\.enabled)
        guard !active.isEmpty else { return false }
        let text = notice.title + "\n" + notice.body
        func matches(_ condition: MessageCondition) -> Bool {
            switch condition.kind {
            case .contains:
                let keyword = condition.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                return !keyword.isEmpty && text.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            case .mentionsMe: return containsAny(mentionKeywords, in: text)
            case .urgent: return containsAny(urgentKeywords, in: text, emojiMarker: true)
            }
        }
        return matchMode == .all ? active.allSatisfy(matches) : active.contains(where: matches)
    }
}

public struct NotificationPreferences: Codable, Equatable {
    public var codex = RetentionPolicy(mode: .untilHandled)
    public var codexDesktop = RetentionPolicy(mode: .disabled)
    public var suppressForegroundTmuxWindow = false
    public var codexCompletion = CodexCompletionPreferences()
    public var feishu = FeishuPreferences()
    public var otherApps = RetentionPolicy(mode: .disabled)
    public init() {}

    private enum CodingKeys: String, CodingKey { case codex, codexDesktop, codexCompletion, feishu, otherApps, suppressForegroundTmuxWindow }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        codex = try values.decodeIfPresent(RetentionPolicy.self, forKey: .codex) ?? codex
        codexDesktop = try values.decodeIfPresent(RetentionPolicy.self, forKey: .codexDesktop) ?? codexDesktop
        suppressForegroundTmuxWindow = try values.decodeIfPresent(Bool.self, forKey: .suppressForegroundTmuxWindow) ?? false
        codexCompletion = try values.decodeIfPresent(CodexCompletionPreferences.self, forKey: .codexCompletion) ?? codexCompletion
        feishu = try values.decodeIfPresent(FeishuPreferences.self, forKey: .feishu) ?? feishu
        otherApps = try values.decodeIfPresent(RetentionPolicy.self, forKey: .otherApps) ?? otherApps
    }

    public struct Decision {
        public let show: Bool
        public let retention: RetentionPolicy
        public let feishuType: FeishuNoticeType?
    }

    public func acceptsSource(_ notice: Notice) -> Bool {
        FeishuPreferences.isFeishu(notice) || Self.isCodexDesktop(notice) || Self.isCodexHook(notice) || otherApps.isEnabled
    }

    private static func isCodexDesktop(_ notice: Notice) -> Bool {
        if let bundleID = notice.bundleID { return bundleID == CodexSessionContext.desktopBundleID }
        return notice.codexClient == .desktop && isCodexHook(notice)
    }

    private static func isCodexHook(_ notice: Notice) -> Bool {
        let codexSource = notice.source == "Codex CLI" || (notice.codexClient == .desktop && notice.source == "Codex 桌面端")
        return notice.bundleID == nil && codexSource && (notice.requiresAction || notice.kind == .completion)
    }

    public func decision(for notice: Notice, isForegroundTmuxWindow: Bool = false) -> Decision {
        // Also reject older inbox events with only a recovery command, before queues/recent notices.
        if Self.isCodexHook(notice) && !notice.hasCodexDestination {
            let retention = notice.kind == .completion ? codexCompletion.retention : codex
            return Decision(show: false, retention: retention, feishuType: nil)
        }
        if Self.isCodexDesktop(notice) {
            return Decision(show: codexDesktop.isEnabled, retention: codexDesktop, feishuType: nil)
        }
        if Self.isCodexHook(notice) {
            let completion = notice.kind == .completion
            let retention = completion ? codexCompletion.retention : codex
            let suppressed = suppressForegroundTmuxWindow && isForegroundTmuxWindow && notice.tmux != nil && notice.codexClient != .desktop
            return Decision(show: !suppressed && retention.isEnabled && (!completion || codexCompletion.allows(notice.workingDirectory)),
                            retention: retention, feishuType: nil)
        }
        guard FeishuPreferences.isFeishu(notice) else { return Decision(show: otherApps.isEnabled, retention: otherApps, feishuType: nil) }
        let type = feishu.classify(notice)
        let retention = feishu.retention(for: type)
        return Decision(show: retention.isEnabled && (type != .message || feishu.allowsMessage(notice)), retention: retention, feishuType: type)
    }

    public var validationError: String? {
        if ([codex, codexDesktop, codexCompletion.retention, otherApps] + FeishuNoticeType.allCases.map { feishu.retention(for: $0) }).contains(where: { $0.mode == .timed && !(1...3600).contains($0.seconds) }) {
            return "停留时间请填写 1–3600 秒。"
        }
        if let error = codexCompletion.validationError { return error }
        if feishu.message.isEnabled && feishu.filterMessages {
            let active = feishu.conditions.filter(\.enabled)
            if active.isEmpty { return "开启消息过滤后，请至少启用一条条件。" }
            if active.contains(where: { $0.kind == .contains && $0.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return "请填写启用条件的内容关键词。"
            }
            if active.contains(where: { $0.kind == .mentionsMe }), FeishuPreferences.keywords(feishu.mentionKeywords).isEmpty {
                return "请在文字识别中填写 @我 的匹配词。"
            }
            if active.contains(where: { $0.kind == .urgent }), FeishuPreferences.keywords(feishu.urgentKeywords).isEmpty {
                return "请在文字识别中填写加急消息的匹配词。"
            }
        }
        return nil
    }

    public static let defaultsKey = "notificationPreferences.v1"
    public static func load(from defaults: UserDefaults = .standard) -> NotificationPreferences {
        guard let data = defaults.data(forKey: defaultsKey),
              var preferences = try? JSONDecoder().decode(Self.self, from: data), preferences.validationError == nil else { return Self() }
        // Replace only the previous stock list; retain any user-edited recognition keywords.
        if preferences.feishu.urgentKeywords == "[加急]\n【加急】\n加急消息\nUrgent" {
            preferences.feishu.urgentKeywords = FeishuPreferences.defaultUrgentKeywords
        }
        if preferences.feishu.calendarKeywords == "日程提醒\n日程邀请\n日程变更\n日程取消\nCalendar reminder" {
            preferences.feishu.calendarKeywords = FeishuPreferences.defaultCalendarKeywords
        }
        return preferences
    }
    public func save(to defaults: UserDefaults = .standard) throws {
        if let validationError { throw NSError(domain: "Notification.Preferences", code: 1, userInfo: [NSLocalizedDescriptionKey: validationError]) }
        defaults.set(try JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}
