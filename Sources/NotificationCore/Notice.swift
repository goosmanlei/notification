import Foundation
import CryptoKit

public struct Notice: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable { case notification, approval, input }
    public var id: String
    public var source: String
    public var title: String
    public var body: String
    public var kind: Kind
    public var createdAt: Date
    public var bundleID: String?
    public var sessionID: String?
    public var context: String?
    public var requiresAction: Bool { kind != .notification }

    public init(id: String = UUID().uuidString, source: String, title: String, body: String,
                kind: Kind = .notification, createdAt: Date = Date(), bundleID: String? = nil,
                sessionID: String? = nil, context: String? = nil) {
        self.id = id; self.source = source; self.title = title; self.body = body
        self.kind = kind; self.createdAt = createdAt; self.bundleID = bundleID
        self.sessionID = sessionID; self.context = context
    }
}

public func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public enum PayloadParser {
    /// Parse the experimental Notification Center binary plist without retaining its raw payload.
    public static func parse(_ data: Data, recordID: Int64) -> Notice? {
        guard data.count <= 1_048_576,
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let request = root["req"] as? [String: Any] ?? root
        let bundleID = root["app"] as? String
        let title = request["titl"] as? String ?? "新通知"
        let subtitle = request["subt"] as? String ?? ""
        let body = request["body"] as? String ?? ""
        let text = [subtitle, body].filter { !$0.isEmpty }.joined(separator: "\n")
        // Ignore response/dismissal bookkeeping changes to avoid replaying a notification on close.
        let fields: [String] = [bundleID ?? "", title, subtitle, body,
                                request["iden"] as? String ?? "",
                                String(describing: root["date"] ?? "")]
        let signature = digest((try? JSONEncoder().encode(fields)) ?? Data())
        return Notice(id: "system:\(recordID):\(signature)", source: bundleID ?? "系统通知",
                      title: String(title.prefix(200)),
                      body: text.isEmpty ? "该应用未提供可显示的通知内容" : String(text.prefix(2000)),
                      bundleID: bundleID)
    }
}
