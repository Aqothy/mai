#if os(macOS)
    import AppKit

    /// What the scroll-intent controller needs from the transcript's
    /// document. The document owns row geometry and the clip's position
    /// together, so every change to one adjusts the other in the same
    /// transaction.
    @MainActor
    protocol ChatMacScrollDocument: NSView {
        /// Whether a geometry change should land on the transcript's end.
        var isBottomFollowingEnabled: () -> Bool { get set }
        /// Lands on the transcript's end as soon as there are rows and a
        /// viewport to show them in, then calls `completion` once.
        func beginInitialBottomAlignment(completion: @escaping () -> Void)
        /// Ends a pending alignment where the viewport is; the reader took
        /// over before the first rows arrived.
        func completeInitialBottomAlignment()
        var isNearBottom: Bool { get }
        /// Moves to the exact end of the content. Returns false until the
        /// document has rows and a viewport.
        @discardableResult
        func scrollToBottom() -> Bool

        // Row geometry, for checking where a row ended up.
        var numberOfRows: Int { get }
        func rect(ofRow row: Int) -> NSRect
        func rows(in rect: NSRect) -> NSRange
        func stableIdentity(forRow row: Int) -> String?
        func row(forStableIdentity id: String) -> Int?
    }
#endif
