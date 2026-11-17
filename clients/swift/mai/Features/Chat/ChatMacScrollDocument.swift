#if os(macOS)
    import AppKit

    /// What the scroll-intent controller needs from the transcript's
    /// document, beyond the reading-position rules every transcript
    /// document follows.
    @MainActor
    protocol ChatMacScrollDocument: NSView, ChatReadingPositionDocument {
        /// Called with the viewport top a move began at when the clip moves
        /// and neither the document nor a viewport change moved it: the
        /// reader did, by whatever input.
        var onReaderScroll: ((_ fromTop: CGFloat) -> Void)? { get set }
    }
#endif
