import Foundation

/// Owns terminal transport state on its own RPC connection, separate from
/// ThreadStore, so terminal bytes and reconnect behavior never affect
/// agent-thread streaming.
///
/// The store manages the connection and this window's active attachment. Raw output
/// bytes flow straight from the transport to the attachment's session
/// controller and never enter observation.
@Observable
final class TerminalStore {
    struct Timing: Sendable {
        let resizeSettleDelay: Duration
        let reconnectDelay: Duration

        static let standard = Timing(
            resizeSettleDelay: .milliseconds(40),
            reconnectDelay: .seconds(2)
        )

        static let immediate = Timing(
            resizeSettleDelay: .zero,
            reconnectDelay: .zero
        )
    }

    enum ConnectionPhase: Equatable {
        case idle
        case connecting
        case connected
        case disconnected
    }

    private(set) var connectionPhase: ConnectionPhase = .idle

    /// Terminal summaries ordered by updatedAt descending, then id — the
    /// same deterministic order the daemon persists.
    private(set) var terminals: [TerminalSummary] = []
    private(set) var hasLoadedTerminalList = false

    /// The one attachment currently rendering a terminal, if any.
    private(set) var activeAttachment: TerminalAttachment?

    @ObservationIgnored let rpc: any TerminalRPCClient
    @ObservationIgnored let timing: Timing
    @ObservationIgnored private var started = false
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var isAwaitingListSnapshot = false
    @ObservationIgnored private var bufferedListItems: [TerminalListStreamItem] = []
    @ObservationIgnored private var listSubscriptionGeneration = 0

    init(
        rpc: any TerminalRPCClient = RPCClient(),
        timing: Timing = .standard
    ) {
        self.rpc = rpc
        self.timing = timing
    }

    /// Connects the transport and subscribes to the terminal list.
    /// Attachments start when their Ghostty surface reports its real grid.
    func start() {
        guard !started else { return }
        started = true
        connectionPhase = .connecting
        rpc.onTerminalStreamItem = { [weak self] item in
            self?.receiveStreamItem(item)
        }
        rpc.onTerminalListItem = { [weak self] item in
            self?.receiveListItem(item)
        }
        rpc.onDisconnect = { [weak self] _ in
            self?.handleDisconnect()
        }
        rpc.connect()
        subscribeList()
    }

    func stop() {
        started = false
        reconnectTask?.cancel()
        reconnectTask = nil
        closeActiveAttachment()
        listSubscriptionGeneration += 1
        isAwaitingListSnapshot = false
        bufferedListItems.removeAll(keepingCapacity: true)
        connectionPhase = .idle
        rpc.disconnect()
    }

    // MARK: - Terminal list

    func summary(for terminalID: String) -> TerminalSummary? {
        terminals.first { $0.terminalID == terminalID }
    }

    private func subscribeList() {
        listSubscriptionGeneration += 1
        let generation = listSubscriptionGeneration
        isAwaitingListSnapshot = true
        bufferedListItems.removeAll(keepingCapacity: true)
        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await rpc.subscribeTerminalList()
                guard started, generation == listSubscriptionGeneration else { return }
                applyListItem(snapshot)
                let buffered = bufferedListItems
                bufferedListItems.removeAll(keepingCapacity: true)
                isAwaitingListSnapshot = false
                for item in buffered {
                    applyListItem(item)
                }
                hasLoadedTerminalList = true
                connectionPhase = .connected
            } catch {
                guard generation == listSubscriptionGeneration else { return }
                isAwaitingListSnapshot = false
                bufferedListItems.removeAll(keepingCapacity: true)
                // Connection loss is handled by the reconnect path; a failed
                // subscribe on a live connection retries on the next connect.
            }
        }
    }

    private func receiveListItem(_ item: TerminalListStreamItem) {
        if isAwaitingListSnapshot {
            bufferedListItems.append(item)
        } else {
            applyListItem(item)
        }
    }

    func applyListItem(_ item: TerminalListStreamItem) {
        switch MaidTerminalListStreamItemKind(rawValue: item.kind) {
        case .snapshot:
            terminals = Self.sorted(item.terminals ?? [])
        case .terminalUpserted:
            guard let summary = item.terminal else { return }
            var next = terminals
            if let index = next.firstIndex(where: { $0.terminalID == summary.terminalID }) {
                guard next[index] != summary else { return }
                next[index] = summary
            } else {
                next.append(summary)
            }
            terminals = Self.sorted(next)
        case .terminalRemoved:
            guard let terminalID = item.terminalID else { return }
            terminals.removeAll { $0.terminalID == terminalID }
            if let active = activeAttachment, active.terminalID == terminalID {
                closeActiveAttachment()
            }
        case nil:
            // Unknown future kinds must not crash the client.
            break
        }
    }

    private static func sorted(_ summaries: [TerminalSummary]) -> [TerminalSummary] {
        summaries.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.terminalID < rhs.terminalID
        }
    }

    // MARK: - Attachments

    /// Opens (or keeps) the attachment for the requested terminal. Any other
    /// active attachment is detached first; its shell keeps running. Stopped
    /// rows relaunch, which is the explicit-open acknowledgement the daemon
    /// expects.
    @discardableResult
    func openTerminal(_ request: TerminalOpenRequest) -> TerminalAttachment {
        if let active = activeAttachment, active.matches(request) {
            return active
        }
        let mode: TerminalAttachment.Mode
        switch request {
        case .new(let cwd, let title):
            mode = .create(cwd: cwd, title: title)
        case .existing(let terminalID):
            if summary(for: terminalID)?.needsRelaunchToOpen == true {
                mode = .relaunch(terminalID: terminalID)
            } else {
                mode = .attach(terminalID: terminalID)
            }
        }
        closeActiveAttachment()
        let attachment = TerminalAttachment(store: self, origin: request, mode: mode, timing: timing)
        activeAttachment = attachment
        return attachment
    }

    /// Detaches whatever terminal is currently open. Driven by navigation
    /// state: containers call this when the visible content is no longer a
    /// terminal.
    func closeActiveTerminal() {
        closeActiveAttachment()
    }

    /// Detaches the given attachment if it is still the active one. Called
    /// when a terminal view disappears; late calls after a switch are no-ops.
    func closeAttachment(_ attachment: TerminalAttachment) {
        guard attachment === activeAttachment else { return }
        closeActiveAttachment()
    }

    /// Replaces the active attachment with a fresh run of the same terminal.
    /// A new attachment (and Ghostty session) renders the new shell from a
    /// clean state.
    @discardableResult
    func relaunchActiveTerminal() -> TerminalAttachment? {
        guard let active = activeAttachment, let terminalID = active.terminalID else {
            return nil
        }
        closeActiveAttachment()
        let attachment = TerminalAttachment(
            store: self,
            origin: active.origin,
            mode: .relaunch(terminalID: terminalID),
            timing: timing
        )
        activeAttachment = attachment
        return attachment
    }

    // MARK: - Actions

    func terminateTerminal(terminalID: String) {
        Task {
            try? await rpc.terminateTerminal(terminalID: terminalID)
        }
    }

    func renameTerminal(terminalID: String, title: String) {
        Task { [weak self] in
            guard let self else { return }
            if let summary = try? await rpc.renameTerminal(
                TerminalRenameParams(terminalID: terminalID, title: title))
            {
                applyListItem(
                    TerminalListStreamItem(
                        kind: MaidTerminalListStreamItemKind.terminalUpserted.rawValue,
                        terminal: summary,
                        terminalID: nil,
                        terminals: nil
                    ))
            }
        }
    }

    /// Deletes the terminal: the daemon terminates any live shell and removes
    /// the persisted row. The list removal notification clears local state.
    func deleteTerminal(terminalID: String) async throws {
        try await rpc.deleteTerminal(terminalID: terminalID)
        if let active = activeAttachment, active.terminalID == terminalID {
            closeActiveAttachment()
        }
    }

    // MARK: - Transport events

    /// Called by an attachment when its attach snapshot was installed,
    /// proving the connection is live.
    func attachmentDidAttach(_ attachment: TerminalAttachment) {
        guard started, attachment === activeAttachment else { return }
        connectionPhase = .connected
    }

    private func receiveStreamItem(_ item: TerminalStreamMessage) {
        activeAttachment?.receive(item)
    }

    private func handleDisconnect() {
        guard started else { return }
        listSubscriptionGeneration += 1
        isAwaitingListSnapshot = false
        bufferedListItems.removeAll(keepingCapacity: true)
        connectionPhase = .disconnected
        activeAttachment?.connectionLost()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            if timing.reconnectDelay != .zero {
                do {
                    try await Task.sleep(for: timing.reconnectDelay)
                } catch { return }
            }
            guard started else { return }
            connectionPhase = .connecting
            rpc.connect()
            subscribeList()
            activeAttachment?.reattachAfterReconnect()
        }
    }

    private func closeActiveAttachment() {
        activeAttachment?.close()
        activeAttachment = nil
    }
}
