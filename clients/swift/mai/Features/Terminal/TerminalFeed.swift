import Foundation
import GhosttyVT

/// Applies one attachment's stream items to its terminal off the main actor:
/// the attach contract's ordering half. Items wait behind the snapshot, then
/// apply strictly in sequence; output and resizes go to the terminal, and
/// everything that changes the attachment's lifecycle goes to `events`.
actor TerminalFeed {
    enum Event: Sendable {
        /// The snapshot is installed and items above it applied.
        case ready
        /// A lifecycle status item for the run.
        case status(TerminalStreamMessage)
        /// The daemon started a new run; attach to it.
        case replacementRun
        /// The terminal can't follow the stream any more (a sequence gap, or
        /// history that no longer applies after a resize); attach again for
        /// a fresh snapshot.
        case needsSnapshot
    }

    nonisolated let terminal: Terminal
    private let events: @MainActor (Event) -> Void
    private nonisolated let input: AsyncStream<TerminalStreamMessage>.Continuation

    private var terminalID: String?
    private var runID: String?
    private var lastSequence = 0
    private var state = State.awaitingSnapshot
    /// Counts snapshot requests, so an install that a newer request
    /// overtook while it restored leaves the items to the newer one.
    private var snapshotRequest = 0
    private var buffered: [TerminalStreamMessage] = []
    private var history: Task<Void, Never>?

    private enum State {
        /// Items buffer until the snapshot arrives.
        case awaitingSnapshot
        /// The snapshot is restored and the buffered items are applying;
        /// items that arrive meanwhile buffer behind them.
        case draining
        /// Items apply as they arrive.
        case live
    }

    init(terminal: Terminal, events: @escaping @MainActor (Event) -> Void) {
        self.terminal = terminal
        self.events = events
        let (stream, input) = AsyncStream.makeStream(of: TerminalStreamMessage.self)
        self.input = input
        Task { [weak self] in
            for await item in stream {
                await self?.receive(item)
            }
        }
    }

    deinit {
        input.finish()
        history?.cancel()
    }

    /// Takes a stream item from the transport, in arrival order, from any
    /// thread.
    nonisolated func enqueue(_ item: TerminalStreamMessage) {
        input.yield(item)
    }

    /// Waits for the next snapshot: items buffer until `install`.
    func expectSnapshot() {
        snapshotRequest += 1
        state = .awaitingSnapshot
        history?.cancel()
        history = nil
    }

    /// Installs the snapshot (its READY state), applies the buffered items
    /// above it, then restores older history in the background so the
    /// screen shows before history finishes.
    /// Throws `CancellationError` when a newer snapshot request arrived
    /// while it restored.
    func install(_ snapshot: TerminalAttachSnapshot, data: Data) async throws {
        let request = snapshotRequest
        try await terminal.restore(snapshot: data)
        guard request == snapshotRequest else { throw CancellationError() }
        terminalID = snapshot.terminal.terminalID
        runID = snapshot.runID
        lastSequence = snapshot.sequence
        // Applying suspends, and items keep arriving meanwhile; they must
        // apply after the buffered ones, not between them.
        state = .draining
        while state == .draining, !buffered.isEmpty {
            let items = buffered.sorted { ($0.sequence ?? 0) < ($1.sequence ?? 0) }
            buffered.removeAll()
            for item in items where state == .draining {
                await apply(item)
            }
        }
        // A gap or a new run while draining already asked for a snapshot.
        guard state == .draining else { return }
        state = .live
        let terminal = terminal
        history = Task { [weak self] in
            while !Task.isCancelled {
                guard let page = try? await terminal.restoreHistoryPage() else { return }
                switch page {
                case .restored: await Task.yield()
                case .finished: return
                case .dropped:
                    await self?.send(.needsSnapshot)
                    return
                }
            }
        }
        await send(.ready)
    }

    private func receive(_ item: TerminalStreamMessage) async {
        guard state == .live else {
            buffered.append(item)
            return
        }
        await apply(item)
    }

    private func apply(_ item: TerminalStreamMessage) async {
        guard item.terminalID == terminalID else { return }
        let kind = MaidTerminalStreamItemKind(rawValue: item.kind)
        // A relaunch is shared lifecycle state: the daemon announces the
        // fresh run so every listener can attach to it. An old run's exit
        // doesn't.
        if item.runID != runID {
            if kind == .status, item.runID != nil,
               [.starting, .running].contains(MaidTerminalStatus(rawValue: item.status ?? "")) {
                state = .awaitingSnapshot
                buffered = [item]
                await send(.replacementRun)
            }
            return
        }
        let sequence = item.sequence ?? 0
        guard sequence > lastSequence else { return }
        guard sequence == lastSequence + 1 else {
            state = .awaitingSnapshot
            await send(.needsSnapshot)
            return
        }
        lastSequence = sequence

        switch kind {
        case .output:
            if let data = item.data { await terminal.feed(data) }
        case .resized:
            if let columns = item.columns, let rows = item.rows {
                try? await terminal.resize(to: GridSize(columns: UInt16(columns), rows: UInt16(rows)))
            }
        case .status:
            await send(.status(item))
        case nil:
            // Unknown future kinds must not crash the client.
            break
        }
    }

    private func send(_ event: Event) async {
        await events(event)
    }
}
