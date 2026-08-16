import Observation

@Observable
final class ChatScrollState {
    struct BottomScrollRequest: Equatable {
        var count = 0
        var animated = false
    }

    var isNearBottom = true
    private(set) var shouldFollowBottom = true
    private var isEndZoneVisible = true
    private(set) var isUserScrolling = false
    private(set) var bottomScrollRequest = BottomScrollRequest()

    func requestScrollToBottom(animated: Bool = false) {
        shouldFollowBottom = true
        bottomScrollRequest = BottomScrollRequest(
            count: bottomScrollRequest.count + 1,
            animated: animated
        )
    }

    func noteEndVisibility(_ isVisible: Bool) {
        if isEndZoneVisible != isVisible {
            isEndZoneVisible = isVisible
        }

        if isUserScrolling {
            if isNearBottom != isVisible {
                isNearBottom = isVisible
            }
        } else if isVisible {
            if !isNearBottom {
                isNearBottom = true
            }
            if !shouldFollowBottom {
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
        if shouldFollowBottom {
            shouldFollowBottom = false
        }
    }

    /// Keyboard and accessibility scrolling do not always enter a user-driven
    /// `ScrollPhase`. Geometry can still prove that the viewport moved toward
    /// older content, so record the same user intent without leaving the state
    /// stuck in an active-scroll phase.
    func noteScrollAwayFromEnd() {
        if isNearBottom {
            isNearBottom = false
        }
        if shouldFollowBottom {
            shouldFollowBottom = false
        }
    }

    func noteUserScrollActivity(isActive: Bool) {
        if isUserScrolling != isActive {
            isUserScrolling = isActive
        }
        if isActive {
            if shouldFollowBottom {
                shouldFollowBottom = false
            }
        } else if isEndZoneVisible {
            if !isNearBottom {
                isNearBottom = true
            }
            if !shouldFollowBottom {
                shouldFollowBottom = true
            }
        }
    }

    func reset() {
        if !isNearBottom {
            isNearBottom = true
        }
        if !shouldFollowBottom {
            shouldFollowBottom = true
        }
        if !isEndZoneVisible {
            isEndZoneVisible = true
        }
        if isUserScrolling {
            isUserScrolling = false
        }
    }
}
