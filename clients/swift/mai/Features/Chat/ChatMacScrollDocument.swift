#if os(macOS)
    import AppKit

    /// Geometry the native scroll-intent and anchor controller reads from the
    /// transcript's virtual document.
    @MainActor
    protocol ChatMacScrollDocument: AnyObject where Self: NSView {
        var numberOfRows: Int { get }
        func rect(ofRow row: Int) -> NSRect
        func rows(in rect: NSRect) -> NSRange
        func stableIdentity(forRow row: Int) -> String?
        func row(forStableIdentity id: String) -> Int?
        /// Called after complete row geometry is published, before the
        /// current render transaction commits.
        func setGeometryCommitHandler(_ handler: (() -> Void)?)
    }
#endif
