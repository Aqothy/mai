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
    }

    extension ChatMacScrollDocument {
        func stableIdentity(forRow row: Int) -> String? { nil }
        func row(forStableIdentity id: String) -> Int? { nil }
    }
    extension NSTableView: ChatMacScrollDocument {}
#endif
