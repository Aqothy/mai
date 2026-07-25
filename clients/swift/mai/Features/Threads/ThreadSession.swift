import Foundation

struct ThreadSession {
    enum SubscriptionState: Equatable {
        case unsubscribed
        case subscribing(UUID)
        case visible
        case inactive
        case protected

        var isSubscribed: Bool {
            switch self {
            case .visible, .inactive, .protected:
                true
            case .unsubscribed, .subscribing:
                false
            }
        }
    }

    var thread: Thread?
    var lastSequence = 0
    var subscriptionState: SubscriptionState = .unsubscribed
    var inactiveSince: Date?
    var bufferedItems: [ThreadStreamItem] = []
    var shouldRestoreAfterReconnect = false

    var isProtected: Bool {
        guard let thread else { return false }
        if let turn = thread.latestTurn, turn.completedAt == nil {
            return true
        }
        if thread.session?.activeTurnID != nil {
            return true
        }
        return thread.timeline.contains { $0.approval?.approvalStatus == .pending }
    }

    /// Outcome of `apply`, so the caller need not re-read the session.
    struct EventApplication {
        var applied = false
        var protectionChanged = false
    }

    /// Applies `event` in place, dropping stale sequences.
    ///
    /// Mutating rather than read-modify-write in ThreadStore keeps the whole
    /// update inside one `_modify` window: a local `var session` would leave a
    /// second reference to the timeline array and force a full copy.
    mutating func apply(_ event: Event) -> EventApplication {
        guard thread != nil, event.sequence > lastSequence else { return EventApplication() }
        let wasProtected = isProtected
        thread?.apply(event)
        lastSequence = event.sequence
        return EventApplication(applied: true, protectionChanged: isProtected != wasProtected)
    }
}
