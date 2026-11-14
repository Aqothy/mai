#if os(iOS)
    import UIKit

    /// What the scroll-intent controller needs from the transcript's scroll
    /// view, beyond the reading-position rules every transcript document
    /// follows.
    @MainActor
    protocol ChatIOSScrollDocument: UIScrollView, ChatReadingPositionDocument {
        /// True while the document itself moves the content offset, or
        /// while its animated jump to the end flies: layout, not the
        /// reader's intent.
        var isAdjustingScrollPosition: Bool { get }
        var isNearBottom: Bool { get }
        /// Moves to the exact end of the content, animated for a reader's
        /// request. Returns false until the document has rows and a
        /// viewport.
        @discardableResult
        func scrollToBottom(animated: Bool) -> Bool
        /// The animated jump to the end stopped: it arrived, or the reader
        /// took over.
        func endScrollAnimation()
        /// The bars and keyboard that cover the transcript's top and bottom.
        func setViewportInsets(_ insets: UIEdgeInsets)
    }
#endif
