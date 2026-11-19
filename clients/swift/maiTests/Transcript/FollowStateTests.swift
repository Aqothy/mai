import CoreGraphics
import Foundation
import Testing

@testable import mai

/// Following the end (PLAN 3.9 rules 1, 6, 7, 10), as `ChatScrollState`
/// did it, minus the delayed geometry reports.
struct FollowStateTests {
    @Test func readerMovesStopAndResumeFollowing() {
        var state = FollowState()
        #expect(state.isFollowing)
        state.note(.awayFromEnd)
        #expect(!state.isFollowing)
        // Seeing the end again after moving away does not resume: only the
        // reader's own move onto it does.
        state.noteEndVisible(true)
        #expect(!state.isFollowing)
        state.note(.reachedEnd)
        #expect(state.isFollowing)
    }

    /// Rule 6: expanding or collapsing stops following, but resumes it if
    /// the end is still visible after.
    @Test func expansionStopsFollowingUntilTheEndShowsAgain() {
        var state = FollowState()
        state.noteExpansion()
        #expect(!state.isFollowing)
        state.noteEndVisible(false)
        #expect(!state.isFollowing)
        state.noteEndVisible(true)
        #expect(state.isFollowing)
    }

    /// Rule 7: a jump sets "resume when the end becomes visible".
    @Test func aJumpFollowsAndResumesOnceTheEndShows() {
        var state = FollowState()
        state.note(.awayFromEnd)
        state.noteJumpToEnd()
        #expect(state.isFollowing)
        state.note(.awayFromEnd)
        state.noteExpansion()
        state.noteEndVisible(true)
        #expect(state.isFollowing)
    }
}
