import Foundation

/// Host I/O seam between the terminal surface and its byte source.
///
/// Increment 1 wires a fake preview backend behind this protocol; Increment 3
/// replaces it with the daemon RPC transport. Both callbacks can arrive on
/// arbitrary threads because they originate in Ghostty surface callbacks.
nonisolated protocol TerminalHostBackend: AnyObject, Sendable {
    /// Keyboard, paste, and mouse-report bytes produced by the terminal.
    func sendInput(_ data: Data)

    /// The measured grid changed. Only called when rows or columns actually
    /// differ from the last reported value.
    func sendResize(columns: UInt16, rows: UInt16)
}
