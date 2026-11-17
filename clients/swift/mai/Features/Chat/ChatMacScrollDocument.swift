#if os(macOS)
    import AppKit

    /// The transcript's document as the scroll-intent controller sees it.
    @MainActor
    protocol ChatMacScrollDocument: NSView, ChatReadingPositionDocument {}
#endif
