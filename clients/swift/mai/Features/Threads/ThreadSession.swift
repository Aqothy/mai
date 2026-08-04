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
    /// Parsed Markdown boundaries belong to the cached thread session, not to
    /// the disposable navigation destination. This retains no SwiftUI views.
    let markdownSegmentCache = ChatMarkdownSegmentCache()
    var lastSequence = 0
    var subscriptionState: SubscriptionState = .unsubscribed
    var inactiveSince: Date?
    var bufferedItems: [ThreadStreamItem] = []
    var shouldRestoreAfterReconnect = false
    var hasQueuedPrompts = false
    var historyRestorePending = false

    var isRestoringHistory: Bool {
        historyRestorePending && historyRestoreErrorMessage == nil
    }

    var historyRestoreErrorMessage: String? {
        guard historyRestorePending, let session = thread?.session else { return nil }
        return switch session.sessionStatus {
        case .error:
            session.lastError ?? "The agent could not restore this chat."
        case .stopped:
            "The agent stopped before this chat was restored."
        default:
            nil
        }
    }

    var canPrepareHistoryRestore: Bool {
        historyRestorePending
            && (thread?.session == nil || historyRestoreErrorMessage != nil)
    }

    var isProtected: Bool {
        if hasQueuedPrompts { return true }
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
        // isProtected scans the timeline for pending approvals, so evaluate it
        // only around events that can change turn, session, or approval state —
        // not per streamed message/item chunk.
        let tracksProtection = Self.canChangeProtection(event.eventType)
        let wasProtected = tracksProtection && isProtected
        thread?.apply(event)
        lastSequence = event.sequence
        if event.eventType == .threadHistoryReplayCompleted {
            historyRestorePending = false
        }
        return EventApplication(
            applied: true,
            protectionChanged: tracksProtection && isProtected != wasProtected
        )
    }

    /// High-frequency streamed content events cannot change `isProtected`:
    /// they never touch `latestTurn`, `session.activeTurnID`, or approvals.
    /// Anything else (turn, session, approval, meta, unknown) is re-evaluated.
    private static func canChangeProtection(_ eventType: MaidEventType?) -> Bool {
        switch eventType {
        case .threadMessageSent,
             .threadItemUpserted,
             .threadPlanUpdated,
             .threadTokenUsageUpdated,
             .threadSlashCommandsUpdated:
            false
        default:
            true
        }
    }
}
