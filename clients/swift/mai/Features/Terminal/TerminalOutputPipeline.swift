import Foundation
import Synchronization

/// Thread-safe funnel between Ghostty surface callbacks (arbitrary threads)
/// and the host backend.
///
/// It exists for three reasons:
/// - `InMemoryTerminalSession` silently drops bytes received before a surface
///   is attached, so daemon output must be buffered until the surface reports
///   its first viewport;
/// - raw terminal bytes must never pass through SwiftUI observation, so this
///   type keeps the hot path outside any `@Observable` state;
/// - replayed historical output must never make the renderer inject input
///   into the live PTY, so replay is delivered behind an input barrier.
nonisolated final class TerminalOutputPipeline: Sendable {
    struct Grid: Hashable, Sendable {
        var columns: UInt16
        var rows: UInt16
    }

    /// DSR-5 operating-status query appended after replay as a sync barrier.
    /// The renderer processes output in order, so its `ESC[0n` answer proves
    /// every historical byte before it has been handled.
    static let replaySentinelQuery = Data("\u{1B}[5n".utf8)
    static let replaySentinelResponse = Data("\u{1B}[0n".utf8)

    private struct State {
        var sink: (@Sendable (Data) -> Void)?
        var gridObserver: (@Sendable (Grid) -> Void)?
        var isSurfaceReady = false
        var isInputEnabled = true
        var pendingOutput: [Data] = []
        var lastGrid: Grid?

        /// Replay barrier: while positive, input is dropped. Counts the
        /// sentinel responses still owed by the renderer — one per DSR-5
        /// inside the replay bytes plus the barrier's own query.
        var awaitedSentinelResponses = 0
        /// Bytes of `replaySentinelResponse` matched so far across chunks.
        var sentinelMatchLength = 0
        /// Invalidates stale timeout tasks after re-arming or release.
        var barrierGeneration = 0
    }

    private let state = Mutex(State())
    private let input: @Sendable (Data) -> Void
    private let resize: @Sendable (Grid) -> Void
    private let barrierTimeout: Duration

    /// - Parameters:
    ///   - input: receives terminal input bytes while input is enabled.
    ///   - resize: receives deduplicated grid changes.
    ///   - barrierTimeout: releases the replay input barrier if the renderer
    ///     never answers the sentinel, so input cannot stay disabled.
    init(
        input: @escaping @Sendable (Data) -> Void,
        resize: @escaping @Sendable (Grid) -> Void,
        barrierTimeout: Duration = .seconds(2)
    ) {
        self.input = input
        self.resize = resize
        self.barrierTimeout = barrierTimeout
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
            Self.deliverLocked(data, to: &state)
        }
    }

    /// Delivers replayed historical output behind the input barrier: the
    /// renderer may answer device queries and mode changes it re-processes,
    /// and none of those answers belong in the live PTY. Input stays dropped
    /// until the renderer acknowledges the trailing sentinel (or the barrier
    /// times out).
    func deliverReplay(_ data: Data) {
        // The renderer answers every DSR-5 it encounters, including any
        // recorded in the replay itself, so the barrier must consume one
        // response per embedded query before trusting its own.
        let expected = Self.occurrences(of: Self.replaySentinelQuery, in: data) + 1
        let generation = state.withLock { state in
            state.awaitedSentinelResponses = expected
            state.sentinelMatchLength = 0
            state.barrierGeneration += 1
            Self.deliverLocked(data, to: &state)
            Self.deliverLocked(Self.replaySentinelQuery, to: &state)
            return state.barrierGeneration
        }
        let timeout = barrierTimeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.releaseReplayBarrier(generation: generation)
        }
    }

    /// Forwards terminal input to the backend unless input is disabled or the
    /// replay barrier is holding back renderer responses to historical bytes.
    func handleInput(_ data: Data) {
        let forwardable: Data? = state.withLock { state in
            guard state.isInputEnabled else { return nil }
            guard state.awaitedSentinelResponses > 0 else { return data }
            return Self.consumeGatedInput(data, state: &state)
        }
        if let forwardable, !forwardable.isEmpty {
            input(forwardable)
        }
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

    /// Enables or disables forwarding of terminal input across lifecycle
    /// transitions such as disconnect and process exit.
    func setInputEnabled(_ enabled: Bool) {
        state.withLock { $0.isInputEnabled = enabled }
    }

    var currentGrid: Grid? {
        state.withLock { $0.lastGrid }
    }

    private static func deliverLocked(_ data: Data, to state: inout State) {
        guard state.isSurfaceReady, let sink = state.sink else {
            state.pendingOutput.append(data)
            return
        }
        sink(data)
    }

    /// Scans gated input for sentinel responses. Everything up to and
    /// including the final awaited response is a reaction to replayed bytes
    /// and is dropped; anything after it in the same chunk is live input.
    private static func consumeGatedInput(_ data: Data, state: inout State) -> Data? {
        let needle = replaySentinelResponse
        for (offset, byte) in data.enumerated() {
            if byte == needle[needle.startIndex + state.sentinelMatchLength] {
                state.sentinelMatchLength += 1
            } else {
                // The needle's first byte (ESC) never recurs inside it, so a
                // failed match can only restart at a fresh ESC.
                state.sentinelMatchLength = byte == needle[needle.startIndex] ? 1 : 0
            }
            guard state.sentinelMatchLength == needle.count else { continue }
            state.sentinelMatchLength = 0
            state.awaitedSentinelResponses -= 1
            if state.awaitedSentinelResponses == 0 {
                let remainder = data.index(data.startIndex, offsetBy: offset + 1)
                return data[remainder...].isEmpty ? nil : Data(data[remainder...])
            }
        }
        return nil
    }

    private func releaseReplayBarrier(generation: Int) {
        state.withLock { state in
            guard state.barrierGeneration == generation else { return }
            state.awaitedSentinelResponses = 0
            state.sentinelMatchLength = 0
        }
    }

    private static func occurrences(of needle: Data, in data: Data) -> Int {
        var count = 0
        var searchStart = data.startIndex
        while let found = data.range(of: needle, in: searchStart..<data.endIndex) {
            count += 1
            searchStart = found.upperBound
        }
        return count
    }
}
