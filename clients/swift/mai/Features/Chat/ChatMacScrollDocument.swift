#if os(macOS)
    import AppKit

    /// What the scroll-intent controller needs from the transcript's
    /// document, beyond the reading-position rules every transcript
    /// document follows.
    @MainActor
    protocol ChatMacScrollDocument: NSView, ChatReadingPositionDocument {
        var isNearBottom: Bool { get }
        /// Set while the reader scrolls. A resize then leaves the clip
        /// where the reader's scroll put it.
        var isReaderScrolling: Bool { get set }
    }
#endif
