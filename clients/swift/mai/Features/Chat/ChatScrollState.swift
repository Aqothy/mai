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
    private var isUserScrolling = false
    private(set) var bottomScrollRequest = BottomScrollRequest()

    func requestScrollToBottom(animated: Bool = false) {
        bottomScrollRequest = BottomScrollRequest(
            count: bottomScrollRequest.count + 1,
            animated: animated
        )
    }

    func noteEndVisibility(_ isVisible: Bool) {
        isEndZoneVisible = isVisible

        if isUserScrolling {
            isNearBottom = isVisible
        } else if isVisible {
            isNearBottom = true
            shouldFollowBottom = true
        } else if !shouldFollowBottom {
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
        shouldFollowBottom = false
    }

    func noteUserScrollActivity(isActive: Bool) {
        isUserScrolling = isActive
        if isActive {
            shouldFollowBottom = false
        } else if isEndZoneVisible {
            isNearBottom = true
            shouldFollowBottom = true
        }
    }

    func reset() {
        isNearBottom = true
        shouldFollowBottom = true
        isEndZoneVisible = true
        isUserScrolling = false
    }
}
