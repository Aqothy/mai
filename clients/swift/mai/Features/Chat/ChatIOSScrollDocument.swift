#if os(iOS)
    import UIKit

    /// What the scroll-intent controller needs from the transcript's scroll
    /// view, beyond the reading-position rules every transcript document
    /// follows.
    @MainActor
    protocol ChatIOSScrollDocument: UIScrollView, ChatReadingPositionDocument {
        /// Called for every content offset change; reports the reader's
        /// moves through `onReaderScroll`.
        func noteOffsetChange()
        /// Moves to the exact end of the content, animated for a reader's
        /// request. Returns false until the document has rows and a
        /// viewport. The scroll-intent controller ends any fling or UIKit
        /// scroll animation first.
        @discardableResult
        func scrollToBottom(animated: Bool) -> Bool
        /// The bars and keyboard that cover the transcript's top and bottom.
        func setViewportInsets(_ insets: UIEdgeInsets)
    }
#endif
