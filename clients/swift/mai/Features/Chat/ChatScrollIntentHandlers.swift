import Foundation

/// Where both platforms' scroll-intent controllers report what the reader
/// did with the transcript. Only how each platform sees a move differs.
struct ChatScrollIntentHandlers {
    var isBottomFollowingEnabled: () -> Bool = { false }
    var noteReaderLeftEnd: () -> Void = {}
    var noteReaderReachedEnd: () -> Void = {}

    /// The reader moved `document`'s viewport, by any input, from the
    /// viewport top `top` to where it is now.
    func noteReaderScroll(from top: CGFloat, in document: any ChatReadingPositionDocument) {
        // Bouncing a transcript that has no rows yet means nothing; its
        // first rows land on the end.
        guard let now = document.viewportTop, let endTop = document.bottomViewportTop
        else { return }
        switch ChatScrollFollowPolicy.readerScroll(
            from: top, to: now, endTop: endTop, isNearBottom: document.isNearBottom)
        {
        case .leftEnd: noteReaderLeftEnd()
        case .reachedEnd: noteReaderReachedEnd()
        case nil: break
        }
    }
}
