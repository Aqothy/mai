import Foundation

/// Host backend that forwards surface I/O to the daemon through
/// `TerminalStore`. Surface callbacks can fire on any thread; the store is
/// MainActor-isolated, so calls hop only when needed, preserving order on the
/// common main-thread input path.
nonisolated final class TerminalDaemonBackend: TerminalHostBackend {
    /// Bound once during store construction. Isolating the weak reference
    /// keeps the compiler checking every access even though surface callbacks
    /// enter through this nonisolated bridge.
    @MainActor private weak var store: TerminalStore?

    @MainActor
    func bind(to store: TerminalStore) {
        self.store = store
    }

    func sendInput(_ data: Data) {
        onStore { store in
            store.sendInput(data)
        }
    }

    func sendResize(columns: UInt16, rows: UInt16) {
        onStore { store in
            store.surfaceGridChanged(columns: columns, rows: rows)
        }
    }

    private func onStore(_ body: @escaping @Sendable @MainActor (TerminalStore) -> Void) {
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
    private func forward(_ body: @Sendable @MainActor (TerminalStore) -> Void) {
        if let store {
            body(store)
        }
    }
}
