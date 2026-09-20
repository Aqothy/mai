#if os(macOS)
    import AppKit

    /// Geometry needed by the shared native scroll-intent and anchor controller.
    /// A SwiftUI List's NSTableView and an explicit virtual document both provide it.
    @MainActor
    protocol ChatMacScrollDocument: AnyObject where Self: NSView {
        var numberOfRows: Int { get }
        func rect(ofRow row: Int) -> NSRect
        func rows(in rect: NSRect) -> NSRange
        func stableIdentity(forRow row: Int) -> String?
        func row(forStableIdentity id: String) -> Int?
        /// Custom documents can publish complete geometry before the current
        /// render transaction commits. Return false for AppKit-managed layout.
        @discardableResult
        func setGeometryCommitHandler(_ handler: (() -> Void)?) -> Bool
    }

    extension ChatMacScrollDocument {
        func stableIdentity(forRow row: Int) -> String? { nil }
        func row(forStableIdentity id: String) -> Int? { nil }
        @discardableResult
        func setGeometryCommitHandler(_ handler: (() -> Void)?) -> Bool { false }
    }
    extension NSTableView: ChatMacScrollDocument {}
#endif
