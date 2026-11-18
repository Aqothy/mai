import CoreGraphics
import Foundation

/// Whether the transcript follows its end, and whether seeing the end again
/// resumes following. Only `TranscriptController` changes it, in the same
/// pass that moves the viewport, so nothing reads a delayed copy.
nonisolated struct FollowState: Equatable, Sendable {
    private(set) var isFollowing = true
    /// Set by a jump to the end, an expansion and reaching the end; cleared by
    /// the reader leaving it. An expansion that leaves the end on screen
    /// therefore keeps following, and a reader who scrolled away is not
    /// pulled back because the end came into view.
    private(set) var resumesWhenEndBecomesVisible = true

    mutating func note(_ scroll: ScrollFollowPolicy.ReaderScroll) {
        switch scroll {
        case .awayFromEnd:
            isFollowing = false
            resumesWhenEndBecomesVisible = false
        case .reachedEnd:
            isFollowing = true
            resumesWhenEndBecomesVisible = true
        }
    }

    mutating func noteEndVisible(_ isVisible: Bool) {
        if isVisible, resumesWhenEndBecomesVisible { isFollowing = true }
    }

    /// The reader opened or closed a row in place: its growth must not move
    /// the viewport (PLAN 3.9 rule 6).
    mutating func noteExpansion() {
        isFollowing = false
        resumesWhenEndBecomesVisible = true
    }

    mutating func noteJumpToEnd() {
        isFollowing = true
        resumesWhenEndBecomesVisible = true
    }

    /// Content must not move under a selection being made (Q1).
    mutating func noteSelectionStarted() {
        note(.awayFromEnd)
    }
}
