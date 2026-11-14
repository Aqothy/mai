#if os(iOS)
    import UIKit

    /// What the scroll-intent controller needs from the transcript's scroll
    /// view. The document owns row geometry and the content offset together,
    /// so every change to one adjusts the other before the frame is drawn.
    @MainActor
    protocol ChatIOSScrollDocument: UIScrollView {
        /// Whether a geometry change should land on the transcript's end.
        var isBottomFollowingEnabled: () -> Bool { get set }
        /// Lands on the transcript's end as soon as there are rows and a
        /// viewport to show them in, then calls `completion` once.
        func beginInitialBottomAlignment(completion: @escaping () -> Void)
        /// Ends a pending alignment where the viewport is; the reader took
        /// over before the first rows arrived.
        func completeInitialBottomAlignment()
        /// True while the document itself moves the content offset, which
        /// is layout and not the reader's intent.
        var isAdjustingScrollPosition: Bool { get }
        var isNearBottom: Bool { get }
        /// Moves to the exact end of the content. Returns false until the
        /// document has rows and a viewport.
        @discardableResult
        func scrollToBottom(animated: Bool) -> Bool
    }
#endif
