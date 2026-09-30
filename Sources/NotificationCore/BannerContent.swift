import Foundation

/// Semantic text fields from one Accessibility notification card, never a whole window/list.
public struct BannerContent: Equatable {
    public struct Line {
        public let identifier: String
        public let text: String
        public init(identifier: String, text: String) { self.identifier = identifier; self.text = text }
    }
    public let source: String
    public let title: String
    public let body: String

    /// The expanded history panel exposes this control; transient banners do not.
    public static func isHistoryControl(role: String, labels: [String]) -> Bool {
        guard role == "AXButton" else { return false }
        let historyLabels: Set<String> = ["edit widgets", "编辑小组件", "編輯小工具", "编辑小部件"]
        return labels.contains { historyLabels.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
    }

    public static func parse(_ lines: [Line], description: String = "") -> BannerContent? {
        func values(_ tag: String) -> [String] {
            lines.filter { $0.identifier.lowercased() == tag }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        let headers = values("header"), titles = values("title")
        // Multiple titles/headers belong to different cards; do not blend their messages.
        guard titles.count == 1, headers.count <= 1 else { return nil }
        let source = headers.first ?? description.components(separatedBy: ",").first ?? ""
        guard !source.isEmpty, source != description || description.contains(",") || !headers.isEmpty else { return nil }
        let body = (values("subtitle") + values("body")).joined(separator: "\n")
        return BannerContent(source: String(source.prefix(200)), title: String(titles[0].prefix(200)),
                             body: body.isEmpty ? "该应用未提供可显示的通知内容" : String(body.prefix(2000)))
    }
}
