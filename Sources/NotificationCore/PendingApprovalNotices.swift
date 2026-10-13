import Foundation

/// Briefly holds desktop approval requests so completed requests never flash a card.
/// This is a presentation delay, not a determination that human approval is required.
public struct PendingApprovalNotices {
    private struct Pending {
        let event: HookEvent
        let deadline: TimeInterval
    }
    private var pending: [String: Pending] = [:]
    private let delay: TimeInterval
    private let capacity: Int

    public init(delay: TimeInterval = 5, capacity: Int = 100) {
        self.delay = max(0, delay)
        self.capacity = max(1, capacity)
    }

    public var count: Int { pending.count }

    /// Call with monotonic uptime; duplicate receipts do not postpone the deadline.
    @discardableResult
    public mutating func hold(_ event: HookEvent, now: TimeInterval) -> Bool {
        guard event.action == .show, event.notice?.kind == .approval,
              event.notice?.codexClient == .desktop else { return false }
        if pending[event.key] != nil { return true }
        if pending.count >= capacity, let oldest = ordered().first {
            pending.removeValue(forKey: oldest.event.key)
        }
        pending[event.key] = Pending(event: event, deadline: now + delay)
        return true
    }

    public mutating func resolve(key: String) {
        pending.removeValue(forKey: key)
    }

    public mutating func clear(session: String? = nil) {
        if let session { pending = pending.filter { $0.value.event.sessionID != session } }
        else { pending.removeAll() }
    }

    /// Flush after processing the entire inbox batch, so cancellation wins at the deadline.
    public mutating func takeReady(now: TimeInterval) -> [HookEvent] {
        let ready = ordered().filter { $0.deadline <= now }
        for item in ready { pending.removeValue(forKey: item.event.key) }
        return ready.map(\.event)
    }

    private func ordered() -> [Pending] {
        pending.values.sorted {
            $0.deadline == $1.deadline ? $0.event.key < $1.event.key : $0.deadline < $1.deadline
        }
    }
}
