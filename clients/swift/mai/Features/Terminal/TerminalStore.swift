import Foundation

/// Owns terminal domain state and this window's active attachment. Connection
/// lifecycle is shared with ThreadStore through RPCConnectionCoordinator. Raw
/// output arrives on each attachment's own stream and never enters
/// observation.
@Observable
final class TerminalStore {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    /// Terminal summaries ordered by updatedAt descending, then id — the
    /// same deterministic order the daemon persists.
    private(set) var terminals: [TerminalSummary] = []
    private(set) var hasLoadedTerminalList = false
    /// The terminal most recently removed, by anyone: a screen showing it
    /// leaves.
    private(set) var removedTerminalID: String?

    /// The one attachment currently rendering a terminal, if any.
    private(set) var activeAttachment: TerminalAttachment?

    @ObservationIgnored let rpc: any TerminalRPCClient
    @ObservationIgnored private let connection: RPCConnectionCoordinator
    @ObservationIgnored private var isAwaitingListSnapshot = false
    @ObservationIgnored private var bufferedListItems: [TerminalListStreamItem] = []
    @ObservationIgnored private var listSubscriptionGeneration = 0

    init(
        rpc: any TerminalRPCClient = RPCClient(),
        connection: RPCConnectionCoordinator? = nil
    ) {
        let connection = connection ?? RPCConnectionCoordinator(rpc: rpc)
        precondition(connection.uses(rpc), "TerminalStore must use the coordinator's RPC client")
        self.rpc = rpc
        self.connection = connection

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
            disconnected: { [weak self] in
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
            // It went away while this client was disconnected. Only a terminal
            // this client was already showing can be told that way: a new one
            // may be newer than the snapshot.
            if let active = activeAttachment, active.hasInstalledInitialSnapshot, active.phase != .running,
                let terminalID = active.terminalID, summary(for: terminalID) == nil
            {
                terminalWasRemoved(terminalID)
            }
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
            terminalWasRemoved(terminalID)
        case nil:
            // Unknown future kinds must not crash the client.
            break
        }
    }

    private func terminalWasRemoved(_ terminalID: String) {
        terminals.removeAll { $0.terminalID == terminalID }
        if let active = activeAttachment, active.terminalID == terminalID {
            closeActiveTerminal()
        }
        removedTerminalID = terminalID
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
    /// active attachment is detached first; its shell keeps running.
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
            mode = .attach(terminalID: terminalID)
        }
        closeActiveTerminal()
        let attachment = TerminalAttachment(
            store: self,
            origin: request,
            mode: mode
        )
        activeAttachment = attachment
        return attachment
    }

    /// Detaches whatever terminal is currently open. Driven by navigation
    /// state: containers call this when the visible content is no longer a
    /// terminal.
    func closeActiveTerminal() {
        activeAttachment?.close()
        activeAttachment = nil
    }

    // MARK: - Actions

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
    /// the persisted row. Other clients hear of it from the list.
    func deleteTerminal(terminalID: String) async throws {
        try await rpc.deleteTerminal(terminalID: terminalID)
        terminalWasRemoved(terminalID)
    }

    // MARK: - Transport events

    private func connectionDidConnect() {
        guard activeAttachment?.phase == .disconnected else { return }
        activeAttachment?.reattach()
    }

    private func connectionDidDisconnect() {
        listSubscriptionGeneration += 1
        isAwaitingListSnapshot = false
        bufferedListItems.removeAll(keepingCapacity: true)
        activeAttachment?.connectionLost()
    }
}
