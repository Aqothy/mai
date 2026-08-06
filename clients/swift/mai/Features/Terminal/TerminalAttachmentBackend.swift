import Foundation

/// Host backend that forwards surface I/O to one `TerminalAttachment`.
/// Surface callbacks can fire on any thread; the attachment is
/// MainActor-isolated, so calls hop only when needed, preserving order on the
/// common main-thread input path.
nonisolated final class TerminalAttachmentBackend: TerminalHostBackend {
    /// Bound once during attachment construction. Isolating the weak
    /// reference keeps the compiler checking every access even though surface
    /// callbacks enter through this nonisolated bridge.
    @MainActor private weak var attachment: TerminalAttachment?

    @MainActor
    func bind(to attachment: TerminalAttachment) {
        self.attachment = attachment
    }

    func sendInput(_ data: Data) {
        onAttachment { attachment in
            attachment.sendInput(data)
        }
    }

    func sendResize(columns: UInt16, rows: UInt16) {
        onAttachment { attachment in
            attachment.gridChanged(columns: columns, rows: rows)
        }
    }

    private func onAttachment(
        _ body: @escaping @Sendable @MainActor (TerminalAttachment) -> Void
    ) {
        // Foundation.Thread spelled out: the generated wire model `Thread`
        // shadows it in this module.
        if Foundation.Thread.isMainThread {
            MainActor.assumeIsolated {
                forward(body)
            }
        } else {
            Task { @MainActor [weak self] in
                self?.forward(body)
            }
        }
    }

    @MainActor
    private func forward(_ body: @Sendable @MainActor (TerminalAttachment) -> Void) {
        if let attachment {
            body(attachment)
        }
    }
}
