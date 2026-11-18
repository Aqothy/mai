import CoreGraphics
import Foundation
import Testing

@testable import mai

/// PLAN 3.9 rule 1: only a move toward the end that shows it follows; any
/// other move stops following, even inside the end zone. Overscroll past
/// either edge, and any pull on content shorter than the viewport, is no move.
struct ScrollFollowPolicyTests {
    @Test func readerScrollsFollowOnlyWhenTheyReachTheEnd() {
        typealias Move = ScrollFollowPolicy.ReaderScroll
        let cases: [(name: String, from: CGFloat, to: CGFloat, endTop: CGFloat, isNearBottom: Bool, expected: Move?)] = [
            ("up inside the end zone", 1_000, 990, 1_000, true, .awayFromEnd),
            ("up far from the end", 500, 200, 1_000, false, .awayFromEnd),
            ("down onto the end", 900, 1_000, 1_000, true, .reachedEnd),
            ("down short of the end", 200, 500, 1_000, false, .awayFromEnd),
            ("overscroll settling back on the end", 1_040, 1_000, 1_000, true, nil),
            ("overscroll settling back on the start", -60, 0, 1_000, false, nil),
            ("pull on short content", 0, -60, 0, true, nil),
            ("subpixel noise", 1_000, 999.8, 1_000, true, nil),
        ]
        for testCase in cases {
            #expect(
                ScrollFollowPolicy.readerScroll(
                    from: testCase.from, to: testCase.to, endTop: testCase.endTop,
                    isNearBottom: testCase.isNearBottom) == testCase.expected,
                "\(testCase.name)")
        }
    }
}
