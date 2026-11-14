#if os(iOS)
    import UIKit

    /// What the scroll-intent controller needs from the transcript's scroll
    /// view, beyond the reading-position rules every transcript document
    /// follows.
    @MainActor
    protocol ChatIOSScrollDocument: UIScrollView, ChatReadingPositionDocument {
        /// True while the document itself moves the content offset, which
        /// is layout and not the reader's intent.
        var isAdjustingScrollPosition: Bool { get }
        var isNearBottom: Bool { get }
        /// Moves to the exact end of the content, animated for a reader's
        /// request. Returns false until the document has rows and a
        /// viewport.
        @discardableResult
        func scrollToBottom(animated: Bool) -> Bool
        /// The bars and keyboard that cover the transcript's top and bottom.
        func setViewportInsets(_ insets: UIEdgeInsets)
    }
#endif
