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
        return thread.timeline.contains { $0.approval?.status == "pending" }
    }
}
