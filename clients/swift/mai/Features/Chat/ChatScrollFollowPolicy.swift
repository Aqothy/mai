import Foundation

/// How both platforms read a move of the transcript's viewport the reader
/// made, whatever the input: a drag, a fling, a trackpad, a wheel, a key,
/// the scroller, a status-bar tap or VoiceOver.
nonisolated enum ChatScrollFollowPolicy {
    /// Ignore subpixel frame noise while still noticing a one-pixel movement
    /// on Retina displays.
    static let minimumMovement: CGFloat = 0.5

    enum ReaderScroll: Equatable {
        /// Toward older content: the reader stops following the end.
        case leftEnd
        /// Toward the end, arriving where it shows: following resumes.
        case reachedEnd
    }

    /// What the reader moving the viewport's top from `from` to `to` means
    /// for following. Positions past `endTop`, where the viewport shows the
    /// end, count as the end, so an overscroll settling back is no move.
    static func readerScroll(
        from: CGFloat, to: CGFloat, endTop: CGFloat, isNearBottom: Bool
    ) -> ReaderScroll? {
        let start = min(from, endTop)
        let stop = min(to, endTop)
        if stop < start - minimumMovement { return .leftEnd }
        if stop > start + minimumMovement, isNearBottom { return .reachedEnd }
        return nil
    }
}
