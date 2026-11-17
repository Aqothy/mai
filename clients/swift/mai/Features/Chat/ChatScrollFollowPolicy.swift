import Foundation

/// How both platforms read a move of the transcript's viewport the reader
/// made, whatever the input: a drag, a fling, a trackpad, a wheel, a key,
/// the scroller, a status-bar tap or VoiceOver.
nonisolated enum ChatScrollFollowPolicy {
    /// Ignore subpixel frame noise while still noticing a one-pixel movement
    /// on Retina displays.
    static let minimumMovement: CGFloat = 0.5

    enum ReaderScroll: Equatable {
        /// The reader moved and does not show the end, or moved toward
        /// older content: following stops.
        case awayFromEnd
        /// The reader moved toward the end and shows it: following resumes.
        case reachedEnd
    }

    /// What the reader moving the viewport's top from `from` to `to` means
    /// for following. Positions past the content's start or past `endTop`,
    /// where the viewport shows the end, count as that edge, so an
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
