import Foundation

public struct RetentionPolicy: Codable, Equatable {
    public enum Mode: String, Codable, CaseIterable { case timed, untilHandled }
    public var mode: Mode
    public var seconds: Int
    public init(mode: Mode = .timed, seconds: Int = 10) { self.mode = mode; self.seconds = seconds }
    public var duration: TimeInterval? { mode == .untilHandled ? nil : TimeInterval(min(3600, max(1, seconds))) }
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
    public var feishu = FeishuPreferences()
    public init() {}

    public struct Decision {
        public let show: Bool
        public let retention: RetentionPolicy
        public let feishuType: FeishuNoticeType?
    }

    public func decision(for notice: Notice) -> Decision {
        if notice.requiresAction { return Decision(show: true, retention: codex, feishuType: nil) }
        guard FeishuPreferences.isFeishu(notice) else { return Decision(show: true, retention: RetentionPolicy(), feishuType: nil) }
        let type = feishu.classify(notice)
        return Decision(show: type != .message || feishu.allowsMessage(notice), retention: feishu.retention(for: type), feishuType: type)
    }

    public var validationError: String? {
        if ([codex] + FeishuNoticeType.allCases.map { feishu.retention(for: $0) }).contains(where: { $0.mode == .timed && !(1...3600).contains($0.seconds) }) {
            return "停留时间请填写 1–3600 秒。"
        }
        if feishu.filterMessages {
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
