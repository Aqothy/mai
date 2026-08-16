import Foundation

/// Owns terminal domain state and this window's active attachment. Connection
/// lifecycle is shared with ThreadStore through RPCConnectionCoordinator. Raw
/// output bytes flow straight from the transport to the attachment's session
/// controller and never enter observation.
@Observable
final class TerminalStore {
    typealias SnapshotRestorer = (TerminalSessionController, Data) async throws -> Void

    /// Terminal summaries ordered by updatedAt descending, then id — the
    /// same deterministic order the daemon persists.
    private(set) var terminals: [TerminalSummary] = []
    private(set) var hasLoadedTerminalList = false

    /// The one attachment currently rendering a terminal, if any.
    private(set) var activeAttachment: TerminalAttachment?

    @ObservationIgnored let rpc: any TerminalRPCClient
    @ObservationIgnored private let connection: RPCConnectionCoordinator
    @ObservationIgnored private let snapshotRestorer: SnapshotRestorer
    @ObservationIgnored private var isAwaitingListSnapshot = false
    @ObservationIgnored private var bufferedListItems: [TerminalListStreamItem] = []
    @ObservationIgnored private var listSubscriptionGeneration = 0

    init(
        rpc: any TerminalRPCClient = RPCClient(),
        connection: RPCConnectionCoordinator? = nil,
        snapshotRestorer: @escaping SnapshotRestorer = { controller, data in
            try await controller.restore(snapshot: data)
        }
    ) {
        let connection = connection ?? RPCConnectionCoordinator(rpc: rpc)
        precondition(connection.uses(rpc), "TerminalStore must use the coordinator's RPC client")
        self.rpc = rpc
        self.connection = connection
        self.snapshotRestorer = snapshotRestorer

        rpc.onTerminalStreamItem = { [weak self] item in
            self?.receiveStreamItem(item)
        }
        rpc.onTerminalListItem = { [weak self] item in
            self?.receiveListItem(item)
        }
        connection.register(
            prepare: { [weak self] in
                self?.prepareConnectionAttempt()
            },
            synchronize: { [weak self] in
                guard let self else { return }
                try await synchronizeConnection()
            },
            connected: { [weak self] in
                self?.connectionDidConnect()
            },
            disconnected: { [weak self] _ in
                self?.connectionDidDisconnect()
            }
        )
    }

    /// Starts the shared app connection. Attachments begin when their Ghostty
    /// surface reports its real grid.
    func start() {
        Task { [weak self] in
            await self?.connection.start()
        }
    }

    // MARK: - Terminal list

    func summary(for terminalID: String) -> TerminalSummary? {
        terminals.first { $0.terminalID == terminalID }
    }

    private func prepareConnectionAttempt() {
        listSubscriptionGeneration += 1
        isAwaitingListSnapshot = true
        bufferedListItems.removeAll(keepingCapacity: true)
    }

    private func synchronizeConnection() async throws {
        let generation = listSubscriptionGeneration
        let snapshot = try await rpc.subscribeTerminalList()
        guard generation == listSubscriptionGeneration else {
            throw CancellationError()
        }
        applyListItem(snapshot)
        let buffered = bufferedListItems
        bufferedListItems.removeAll(keepingCapacity: true)
        isAwaitingListSnapshot = false
        for item in buffered {
            applyListItem(item)
        }
        hasLoadedTerminalList = true
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
        let attachment = TerminalAttachment(
            store: self,
            origin: request,
            mode: mode,
            snapshotRestorer: snapshotRestorer
        )
        activeAttachment = attachment
        return attachment
    }

    /// Detaches whatever terminal is currently open. Driven by navigation
    /// state: containers call this when the visible content is no longer a
    /// terminal.
    func closeActiveTerminal() {
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
            snapshotRestorer: snapshotRestorer
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

    private func receiveStreamItem(_ item: TerminalStreamMessage) {
        activeAttachment?.receive(item)
    }

    private func connectionDidConnect() {
        guard activeAttachment?.phase == .disconnected else { return }
        activeAttachment?.reattachAfterReconnect()
    }

    private func connectionDidDisconnect() {
        listSubscriptionGeneration += 1
        isAwaitingListSnapshot = false
        bufferedListItems.removeAll(keepingCapacity: true)
        activeAttachment?.connectionLost()
    }

    private func closeActiveAttachment() {
        activeAttachment?.close()
        activeAttachment = nil
    }
}
