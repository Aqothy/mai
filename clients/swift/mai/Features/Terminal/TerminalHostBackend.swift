import Foundation

/// I/O supplied by the daemon attachment or preview backend.
/// Ghostty can invoke these callbacks from any thread.
nonisolated protocol TerminalHostBackend: AnyObject, Sendable {
    /// Keyboard, paste, and mouse-report bytes produced by the terminal.
    func sendInput(_ data: Data)

    /// The measured grid changed. Only called when rows or columns actually
    /// differ from the last reported value.
    func sendResize(columns: UInt16, rows: UInt16)
}
