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

    var detail: ThreadDetail?
    /// Presentation caches survive short navigation round trips and are
    /// discarded when subscription maintenance evicts this session.
    var markdownSegmentCache = ChatMarkdownSegmentCache()
    var textLayoutStore = ChatTextLayoutStore()
    /// Incremental section projection for the chat timeline. Every turn
    /// change below invalidates it; the chat projects lazily in `body`.
    var timelineProjection = ChatTimelineProjection()
    var subscriptionState: SubscriptionState = .unsubscribed
    var inactiveSince: Date?
    /// Events that arrived while the snapshot was on its way.
    var bufferedEvents: [ThreadEvent] = []
    var shouldRestoreAfterReconnect = false

    /// A chat that runs or waits on the user stays subscribed when hidden.
    var isProtected: Bool {
        guard let detail else { return false }
        return detail.status != .idle || !detail.queue.isEmpty || detail.needsUser
    }

    /// Outcome of `apply`, so the caller need not re-read the session.
    struct EventApplication {
        var change: ThreadDetail.Change = .none
        var protectionChanged = false
    }

    /// Applies `event` in place, dropping stale sequences.
    ///
    /// Mutating rather than read-modify-write in ThreadStore keeps the whole
    /// update inside one `_modify` window: a local `var session` would leave a
    /// second reference to the turns and force a full copy.
    mutating func apply(_ event: ThreadEvent) -> EventApplication {
        guard detail != nil else { return EventApplication() }
        let wasProtected = isProtected
        let change = detail?.apply(event) ?? .none
        switch change {
        case .turns(let index):
            timelineProjection.invalidate(fromTurn: index)
        case .text(let turnID, _, _):
            if let index = detail?.turns.lastIndex(where: { $0.id == turnID }) {
                timelineProjection.invalidate(fromTurn: index)
            }
        case .none, .thread, .refresh, .removed:
            break
        }
        return EventApplication(change: change, protectionChanged: isProtected != wasProtected)
    }
}
