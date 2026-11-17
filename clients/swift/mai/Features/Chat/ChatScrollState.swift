import Observation

@Observable
final class ChatScrollState {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    struct BottomScrollRequest: Equatable {
        var count = 0
        var animated = false
    }

    var isNearBottom = true
    private(set) var shouldFollowBottom = true
    private var resumesWhenEndBecomesVisible = true
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

    /// The reader moved toward older content. Layout must not call this:
    /// row-height correction can move the viewport without intent. Whether
    /// the end is still in view comes from the next geometry report.
    func noteScrollAwayFromEnd() {
        resumesWhenEndBecomesVisible = false
        if shouldFollowBottom {
            shouldFollowBottom = false
        }
    }

    /// The reader's scroll toward the end arrived where it shows.
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
        noteScrollReturnedToEnd()
    }
}
