import Foundation

/// Pair one banner receipt with one database receipt. Identical new messages stay distinct.
/// Call on one serial queue; only hashes and receipt metadata are retained, in memory.
public final class SystemNoticeMerger {
    public enum Channel { case banner, database }
    private struct Receipt {
        let key: String
        let channel: Channel
        let time: TimeInterval
    }
    private var receipts: [Receipt] = []
    private var databaseIDs: Set<String> = []
    private var databaseOrder: [String] = []
    private let lifetime: TimeInterval

    public init(lifetime: TimeInterval = 30) { self.lifetime = lifetime }

    public func rememberExisting(_ notices: [Notice]) {
        for notice in notices {
            Self.remember(notice.id, in: &databaseIDs, order: &databaseOrder)
        }
    }

    public func shouldDeliver(_ notice: Notice, from channel: Channel,
                              at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        receipts.removeAll { time - $0.time > lifetime }
        let key = contentKey(notice)
        if channel == .database {
            guard !databaseIDs.contains(notice.id) else { return false }
            Self.remember(notice.id, in: &databaseIDs, order: &databaseOrder)
        }
        if let index = receipts.firstIndex(where: { $0.key == key && $0.channel != channel }) {
            receipts.remove(at: index)
            return false
        }
        receipts.append(Receipt(key: key, channel: channel, time: time))
        if receipts.count > 500 { receipts.removeFirst(receipts.count - 500) }
        return true
    }

    private func contentKey(_ notice: Notice) -> String {
        func normalize(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let fields = [notice.bundleID ?? notice.source.lowercased(), normalize(notice.title), normalize(notice.body)]
        return digest((try? JSONEncoder().encode(fields)) ?? Data())
    }

    private static func remember(_ key: String, in keys: inout Set<String>, order: inout [String]) {
        guard keys.insert(key).inserted else { return }
        order.append(key)
        if order.count > 4096 { keys.remove(order.removeFirst()) }
    }
}
