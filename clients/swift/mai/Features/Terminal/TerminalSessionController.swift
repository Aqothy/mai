import Foundation
import GhosttyTerminal

/// Owns the stable Ghostty integration objects for one terminal view's
/// lifetime and routes bytes between the surface and a host backend.
///
/// Observable properties change only on low-frequency lifecycle events (grid
/// change, process end, input control). Raw output goes straight to
/// `InMemoryTerminalSession.receive(_:)` through the pipeline and never
/// touches observation or SwiftUI `body`.
@Observable
final class TerminalSessionController {
    /// Package integration object. It is an `ObservableObject` by package
    /// design; that is acceptable only inside this wrapper.
    @ObservationIgnored let viewState: TerminalViewState

    /// Exposed for tests; application code outside this feature must not
    /// talk to the session directly.
    @ObservationIgnored let session: InMemoryTerminalSession

    @ObservationIgnored private let pipeline: TerminalOutputPipeline
    @ObservationIgnored private let backend: any TerminalHostBackend
    @ObservationIgnored private var fontSize: Float
    /// Last grid the surface reported. Updated only when rows/columns change.
    private(set) var grid: TerminalOutputPipeline.Grid?

    /// True after the remote process ended and the exit was delivered.
    private(set) var hasEnded = false

    /// Terminal input forwarding; disabled when disconnected or the run ends.
    private(set) var isInputEnabled = true

    init(
        backend: any TerminalHostBackend,
        fontSize: Float = TerminalSettings.defaultFontSize
    ) {
        self.backend = backend
        self.fontSize = fontSize
        viewState = TerminalViewState(theme: MaidTerminalAppearance.theme)

        let pipeline = TerminalOutputPipeline(
            input: { [backend] data in
                backend.sendInput(data)
            },
            resize: { [backend] grid in
                backend.sendResize(columns: grid.columns, rows: grid.rows)
            }
        )
        self.pipeline = pipeline

        let session = InMemoryTerminalSession(
            write: { [pipeline] data in
                pipeline.handleInput(data)
            },
            resize: { [pipeline] viewport in
                pipeline.handleViewport(columns: viewport.columns, rows: viewport.rows)
            }
        )
        self.session = session
        viewState.configuration = TerminalSurfaceOptions(
            backend: .inMemory(session),
            fontSize: fontSize
        )

        // Weak capture: the session's callbacks retain the pipeline, so a
        // strong sink reference back to the session would leak both.
        pipeline.bindSink { [weak session] data in
            session?.receive(data)
        }
        pipeline.bindGridObserver { [weak self] grid in
            Task { @MainActor in
                self?.grid = grid
            }
        }

        viewState.onClose = { [weak self] _ in
            self?.markEnded()
        }
    }

    /// Routes one chunk of remote terminal output to the renderer. Safe to
    /// call from any thread; does not invalidate SwiftUI observation.
    nonisolated func receive(_ data: Data) {
        pipeline.deliver(data)
    }

    /// Routes an attach snapshot's replay to the renderer behind the input
    /// barrier: anything the renderer emits while re-processing historical
    /// bytes (query answers, mode side effects) is dropped instead of being
    /// written into the live PTY.
    nonisolated func receiveReplay(_ data: Data) {
        pipeline.deliverReplay(data)
    }

    /// Delivers remote process exit to the surface after all previously
    /// received output.
    func processDidEnd(exitCode: Int?, runtimeMilliseconds: UInt64 = 0) {
        session.finish(
            exitCode: UInt32(clamping: exitCode ?? 0),
            runtimeMilliseconds: runtimeMilliseconds
        )
        markEnded()
    }

    /// Applies a changed terminal font size to the surface configuration.
    /// The surface reports the resulting grid change through the normal
    /// resize path.
    func setFontSize(_ size: Float) {
        guard fontSize != size else { return }
        fontSize = size
        viewState.configuration = TerminalSurfaceOptions(
            backend: .inMemory(session),
            fontSize: size
        )
    }

    /// Enables or disables terminal input forwarding.
    func setInputEnabled(_ enabled: Bool) {
        guard isInputEnabled != enabled else { return }
        isInputEnabled = enabled
        pipeline.setInputEnabled(enabled)
    }

    private func markEnded() {
        guard !hasEnded else { return }
        hasEnded = true
        setInputEnabled(false)
    }
}
