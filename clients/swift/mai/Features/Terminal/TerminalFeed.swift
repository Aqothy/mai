import Foundation
import GhosttyVT

/// Applies one view's stream records to its terminal, off the main actor and
/// in stream order. A snapshot replaces the terminal once all its data has
/// arrived; output and resizes apply on top of it; what the view must act on
/// goes to `events`. The daemon registers the stream atomically with its
/// snapshot, so there is nothing to order, buffer or deduplicate here.
actor TerminalFeed {
    enum Event: Sendable {
        /// A snapshot is installed; `title` is the program's at that point.
        case snapshot(title: String)
        /// History no longer applies after a resize; attach again for a
        /// fresh snapshot.
        case needsSnapshot
    }

    nonisolated let terminal: Terminal
    private let events: @MainActor (Event) -> Void

    private enum State {
        /// The stream begins with a snapshot.
        case awaitingSnapshot
        /// A snapshot's data is arriving.
        case receiving(TerminalStreamSnapshot, Data)
        /// Records apply to the installed snapshot.
        case live
    }

    private var state = State.awaitingSnapshot
    private var history: Task<Void, Never>?

    init(terminal: Terminal, events: @escaping @MainActor (Event) -> Void) {
        self.terminal = terminal
        self.events = events
    }

    deinit {
        history?.cancel()
    }

    /// Waits for the snapshot a new stream begins with.
    func expectSnapshot() {
        state = .awaitingSnapshot
    }

    /// Applies the next record. Throws when the stream breaks its contract
    /// or a snapshot can't be installed; the stream is then unusable.
    func apply(_ record: TerminalStreamConnection.Record) async throws {
        switch (record, state) {
        case (.snapshot(let header), _):
            // A new snapshot abandons a partial one and replaces the terminal.
            guard header.snapshotFormat == Self.snapshotFormat else {
                throw TerminalStreamError(
                    String(localized: "The app and daemon use incompatible terminal snapshot versions."))
            }
            guard header.size > 0 else {
                throw TerminalStreamError(String(localized: "The daemon returned an invalid terminal snapshot."))
            }
            state = .receiving(header, Data(capacity: header.size))
        case (.snapshotData(let part), .receiving(let header, var data)):
            data.append(part)
            guard data.count <= header.size else {
                throw TerminalStreamError(String(localized: "The daemon returned an invalid terminal snapshot."))
            }
            if data.count == header.size {
                try await install(header, data: data)
            } else {
                state = .receiving(header, data)
            }
        case (.output(let data), .live):
            await terminal.feed(data)
        case (.resized(let size), .live):
            try await terminal.resize(to: GridSize(columns: UInt16(size.columns), rows: UInt16(size.rows)))
        case (.snapshotData, _), (.output, _), (.resized, _):
            throw TerminalStreamError(String(localized: "maiD sent a terminal record out of order."))
        }
    }

    /// Installs the snapshot's screen, then restores older history in the
    /// background so the screen shows before history finishes.
    private func install(_ header: TerminalStreamSnapshot, data: Data) async throws {
        history?.cancel()
        history = nil
        try await terminal.restore(snapshot: data)
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
        let title = await terminal.title
        await send(.snapshot(title: title))
    }

    private func send(_ event: Event) async {
        await events(event)
    }

    /// GHOSTSNP v1 isn't stable across Ghostty commits, so the daemon and
    /// this app must link libghostty-vt from the same one (the daemon's
    /// `vtscreen.SnapshotFormat`).
    private static let snapshotFormat = "ghostty-gsn-v1-" + BuildInfo.commit
}
