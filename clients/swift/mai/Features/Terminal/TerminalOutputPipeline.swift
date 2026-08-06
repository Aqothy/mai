import Foundation
import Synchronization

/// Thread-safe funnel between Ghostty surface callbacks (arbitrary threads)
/// and the host backend.
///
/// It exists for two reasons:
/// - `InMemoryTerminalSession` silently drops bytes received before a surface
///   is attached, so daemon output must be buffered until the surface reports
///   its first viewport;
/// - raw terminal bytes must never pass through SwiftUI observation, so this
///   type keeps the hot path outside any `@Observable` state.
nonisolated final class TerminalOutputPipeline: Sendable {
    struct Grid: Hashable, Sendable {
        var columns: UInt16
        var rows: UInt16
    }

    private struct State {
        var sink: (@Sendable (Data) -> Void)?
        var gridObserver: (@Sendable (Grid) -> Void)?
        var isSurfaceReady = false
        var isInputEnabled = true
        var pendingOutput: [Data] = []
        var lastGrid: Grid?
    }

    private let state = Mutex(State())
    private let input: @Sendable (Data) -> Void
    private let resize: @Sendable (Grid) -> Void

    /// - Parameters:
    ///   - input: receives terminal input bytes while input is enabled.
    ///   - resize: receives deduplicated grid changes.
    init(
        input: @escaping @Sendable (Data) -> Void,
        resize: @escaping @Sendable (Grid) -> Void
    ) {
        self.input = input
        self.resize = resize
    }

    /// Connects the renderer sink. Bound once after the terminal session
    /// exists; kept separate from init to break the construction cycle
    /// between the session's callbacks and this pipeline.
    func bindSink(_ sink: @escaping @Sendable (Data) -> Void) {
        state.withLock { $0.sink = sink }
    }

    /// Observes deduplicated grid changes in addition to the resize callback,
    /// letting the owning controller mirror the grid into observable state.
    func bindGridObserver(_ observer: @escaping @Sendable (Grid) -> Void) {
        state.withLock { $0.gridObserver = observer }
    }

    /// Delivers one chunk of host/daemon output to the renderer, buffering
    /// until the surface is ready. Calling the sink while holding the lock
    /// keeps live output ordered relative to the buffered flush.
    func deliver(_ data: Data) {
        state.withLock { state in
            guard state.isSurfaceReady, let sink = state.sink else {
                state.pendingOutput.append(data)
                return
            }
            sink(data)
        }
    }

    /// Forwards terminal input to the backend unless input is disabled.
    func handleInput(_ data: Data) {
        let enabled = state.withLock { $0.isInputEnabled }
        guard enabled else { return }
        input(data)
    }

    /// Handles a viewport report from the surface. The first report marks the
    /// surface live and flushes buffered output in order; subsequent reports
    /// forward only when rows or columns changed.
    func handleViewport(columns: UInt16, rows: UInt16) {
        let (changedGrid, observer): (Grid?, (@Sendable (Grid) -> Void)?) = state.withLock { state in
            if !state.isSurfaceReady {
                state.isSurfaceReady = true
                if let sink = state.sink {
                    for chunk in state.pendingOutput {
                        sink(chunk)
                    }
                }
                state.pendingOutput.removeAll()
            }
            guard columns > 0, rows > 0 else { return (nil, nil) }
            let grid = Grid(columns: columns, rows: rows)
            guard state.lastGrid != grid else { return (nil, nil) }
            state.lastGrid = grid
            return (grid, state.gridObserver)
        }
        if let changedGrid {
            resize(changedGrid)
            observer?(changedGrid)
        }
    }

    /// Enables or disables forwarding of terminal input, e.g. after control
    /// of the remote terminal is revoked.
    func setInputEnabled(_ enabled: Bool) {
        state.withLock { $0.isInputEnabled = enabled }
    }

    var currentGrid: Grid? {
        state.withLock { $0.lastGrid }
    }
}
