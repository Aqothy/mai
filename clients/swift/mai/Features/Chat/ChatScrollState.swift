import Observation

@Observable
final class ChatScrollState {
    struct BottomScrollRequest: Equatable {
        var count = 0
        var animated = false
    }

    var isNearBottom = true
    private(set) var shouldFollowBottom = true
    private var resumesWhenEndBecomesVisible = true
    private(set) var isUserScrolling = false
    private(set) var bottomScrollRequest = BottomScrollRequest()

    func requestScrollToBottom(animated: Bool = false) {
        shouldFollowBottom = true
        resumesWhenEndBecomesVisible = true
        bottomScrollRequest = BottomScrollRequest(
            count: bottomScrollRequest.count + 1,
            animated: animated
        )
    }

    func noteEndVisibility(_ isVisible: Bool) {
        if isVisible {
            if !isNearBottom {
                isNearBottom = true
            }
            if resumesWhenEndBecomesVisible, !shouldFollowBottom {
                shouldFollowBottom = true
            }
        } else if !shouldFollowBottom, isNearBottom {
            // While following, the loss is transient — the bottom pin lands
            // next frame — and the jump button must not flash in.
            isNearBottom = false
        }
    }

    /// Expanding a row grows content just like streaming does, but the user
    /// is reading in place: stop following the bottom so the growth cannot
    /// yank the viewport. Following resumes via `noteEndVisibility` if the
    /// end of the timeline is still on screen afterwards.
    func noteContentExpansion() {
        resumesWhenEndBecomesVisible = true
        if shouldFollowBottom {
            shouldFollowBottom = false
        }
    }

    /// Records explicit native input toward older content without leaving the
    /// state stuck in an active-scroll phase. Layout geometry alone must not
    /// call this: row-height correction can move the viewport without intent.
    func noteScrollAwayFromEnd() {
        resumesWhenEndBecomesVisible = false
        if isNearBottom {
            isNearBottom = false
        }
        if shouldFollowBottom {
            shouldFollowBottom = false
        }
    }

    /// Records an explicit keyboard request toward the end without jumping.
    /// Visibility restores following only if the native scroll actually
    /// reaches the end.
    func noteScrollTowardEnd() {
        resumesWhenEndBecomesVisible = true
    }

    func noteUserScrollActivity(isActive: Bool) {
        if isUserScrolling != isActive {
            isUserScrolling = isActive
        }
        if isActive {
            resumesWhenEndBecomesVisible = false
            if shouldFollowBottom {
                shouldFollowBottom = false
            }
        }
    }

    /// Restores automatic following after keyboard or accessibility scrolling
    /// reaches the end without participating in a live-scroll phase.
    func noteScrollReturnedToEnd() {
        resumesWhenEndBecomesVisible = true
        if !isNearBottom {
            isNearBottom = true
        }
        if !shouldFollowBottom {
            shouldFollowBottom = true
        }
    }

    func reset() {
        resumesWhenEndBecomesVisible = true
        if !isNearBottom {
            isNearBottom = true
        }
        if !shouldFollowBottom {
            shouldFollowBottom = true
        }
        if isUserScrolling {
            isUserScrolling = false
        }
    }
}
