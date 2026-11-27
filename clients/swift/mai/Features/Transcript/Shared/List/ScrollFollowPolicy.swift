import CoreGraphics
import Foundation

/// How a move of the viewport that the controller did not make reads for
/// following the end (PLAN 3.9 rule 1), whatever the input: a drag, a
/// fling, a trackpad, a wheel, a key, the scroller, a status-bar tap or
/// VoiceOver.
nonisolated enum ScrollFollowPolicy {
    /// Ignores subpixel frame noise while still noticing a one-pixel move on
    /// Retina displays.
    static let minimumMovement: CGFloat = 0.5
    /// How close to the end still counts as showing it: follow hysteresis and
    /// the jump button.
    static let nearEndDistance: CGFloat = 24

    enum ReaderScroll: Equatable, Sendable {
        /// The reader moved and does not show the end, or moved toward older
        /// content: following stops.
        case awayFromEnd
        /// The reader moved toward the end and shows it: following resumes.
        case reachedEnd
    }

    /// What moving the viewport's top from `from` to `to` means. Positions
    /// past the content's start or past `endTop` count as that edge, so an
    /// overscroll settling back, or any pull on content shorter than the
    /// viewport, is no move.
    static func readerScroll(
        from: CGFloat, to: CGFloat, endTop: CGFloat, isNearBottom: Bool
    ) -> ReaderScroll? {
        func clamped(_ top: CGFloat) -> CGFloat { min(max(top, 0), endTop) }
        let start = clamped(from)
        let stop = clamped(to)
        guard abs(stop - start) > minimumMovement else { return nil }
        return stop > start && isNearBottom ? .reachedEnd : .awayFromEnd
    }
}
