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
    /// Saved reading place for the transcript for this app run;
    /// nil when following the end and removed when the thread is deleted.
    var savedTranscriptPlace: TranscriptSavedPlace?
    /// Remembered measured row heights keyed by `(columnWidth, styleVersion)`
    /// so reopening a thread starts with exact geometry (zero scrollbar jump).
    var transcriptMeasuredHeights: TranscriptMeasuredHeights?
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
        return EventApplication(change: change, protectionChanged: isProtected != wasProtected)
    }
}
