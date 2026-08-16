import Foundation

/// One client attachment to one terminal thread run.
///
/// The attachment owns the stable Ghostty controller for the terminal view's
/// lifetime and implements the attach contract: transactionally install the
/// authoritative native Ghostty snapshot, then apply only live items whose
/// run matches and whose sequence is greater than the snapshot sequence.
/// Items that arrive while the attach call is in flight are buffered and
/// applied in sequence order afterward.
///
/// Observable properties change only on lifecycle events; raw output bytes go
/// straight to the controller and never enter observation.
@Observable
final class TerminalAttachment {
    /// How the attachment obtains its run.
    enum Mode: Equatable {
        /// Create a new terminal in the given working directory.
        case create(cwd: String, title: String?)
        /// Attach to an existing live (running or exited) terminal.
        case attach(terminalID: String)
        /// Start a fresh run for an existing terminal (stopped rows, or the
        /// explicit Relaunch action).
        case relaunch(terminalID: String)
    }

    enum Phase: Equatable {
        case attaching
        case running
        case exited(Int?)
        case stopped
        case failed(String)
        case disconnected
    }

    private(set) var phase: Phase = .attaching

    /// True once this surface has installed its first authoritative snapshot and
    /// all live items buffered behind it. Reconnects keep the rendered screen
    /// visible while a replacement snapshot is in flight.
    private(set) var hasInstalledInitialSnapshot = false

    /// Stable for the attachment's lifetime so SwiftUI updates never recreate
    /// the Ghostty surface.
    @ObservationIgnored let controller: TerminalSessionController

    /// Known immediately for attach/relaunch; assigned by the create snapshot.
    private(set) var terminalID: String?

    /// The navigation request this attachment serves. Preserved across
    /// relaunch replacement so a screen opened via `.new` keeps matching.
    @ObservationIgnored let origin: TerminalOpenRequest

    @ObservationIgnored private(set) var runID: String?
    @ObservationIgnored private var mode: Mode
    @ObservationIgnored private weak var store: TerminalStore?
    @ObservationIgnored private let backend: TerminalAttachmentBackend
    @ObservationIgnored private let snapshotRestorer: TerminalStore.SnapshotRestorer

    @ObservationIgnored private var lastAppliedSequence = 0
    @ObservationIgnored private var awaitingSnapshot = true
    @ObservationIgnored private var bufferedItems: [TerminalStreamMessage] = []
    @ObservationIgnored private var isClosed = false

    @ObservationIgnored private var pendingGrid: TerminalOutputPipeline.Grid?
    @ObservationIgnored private var lastSentGrid: TerminalOutputPipeline.Grid?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var startInFlight = false

    init(
        store: TerminalStore,
        origin: TerminalOpenRequest,
        mode: Mode,
        snapshotRestorer: @escaping TerminalStore.SnapshotRestorer
    ) {
        self.store = store
        self.origin = origin
        self.mode = mode
        self.snapshotRestorer = snapshotRestorer
        let backend = TerminalAttachmentBackend()
        self.backend = backend
        controller = TerminalSessionController(
            backend: backend,
            fontSize: TerminalSettings.shared.fontSize
        )
        backend.bind(to: self)
        switch mode {
        case .create:
            terminalID = nil
        case .attach(let terminalID), .relaunch(let terminalID):
            self.terminalID = terminalID
        }
    }

    /// Whether this attachment already serves the requested navigation
    /// target, so a re-appearing view keeps it instead of re-attaching.
    func matches(_ request: TerminalOpenRequest) -> Bool {
        if request == origin { return true }
        if case .existing(let terminalID) = request {
            return self.terminalID == terminalID
        }
        return false
    }

    // MARK: - Surface callbacks (via backend, MainActor)

    /// Terminal input from the surface. Dropped unless this attachment is on
    /// a running shell; every attached client may write to the shared PTY.
    func sendInput(_ data: Data) {
        guard !isClosed, phase == .running, !awaitingSnapshot,
            let terminalID, let runID
        else { return }
        store?.rpc.writeTerminal(
            TerminalWriteParams(
                data: data.base64EncodedString(),
                runID: runID,
                terminalID: terminalID
            ))
    }

    /// The first measured grid starts attach. Synchronous layout bursts use
    /// their latest value; a later change is handled by the snapshot-grid
    /// validation in `apply(snapshot:)`.
    func gridChanged(columns: UInt16, rows: UInt16) {
        pendingGrid = .init(columns: columns, rows: rows)
        if runID != nil {
            scheduleResize()
        } else if !startInFlight {
            startTask?.cancel()
            startTask = nil
            scheduleStart()
        }
    }

    // MARK: - Lifecycle

    /// Re-runs the attach flow over a fresh connection. The last rendered
    /// screen stays visible until the new snapshot replaces it.
    func reattachAfterReconnect() {
        guard !isClosed else { return }
        if let terminalID {
            mode = .attach(terminalID: terminalID)
        }
        // Without an identity the original create never completed; retry it
        // unchanged on the fresh connection.
        prepareForNewRunRequest()
    }

    /// Starts a fresh shell for this terminal after exit/stop/failure.
    func relaunch() {
        guard !isClosed, let terminalID else { return }
        switch phase {
        case .exited, .stopped, .failed:
            mode = .relaunch(terminalID: terminalID)
            prepareForNewRunRequest()
        case .attaching, .running, .disconnected:
            return
        }
    }

    /// Best-effort detach; the shell keeps running on the daemon.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        // Once an attach RPC has been sent, let it finish so we can detach the
        // server-side subscription using the identity returned in its snapshot.
        // Canceling only the local await would discard that identity while the
        // daemon keeps this connection subscribed.
        if !startInFlight {
            startTask?.cancel()
            startTask = nil
        }
        if let terminalID, let runID {
            store?.rpc.detachTerminal(
                TerminalDetachParams(runID: runID, terminalID: terminalID))
        }
        controller.setInputEnabled(false)
    }

    /// Transport loss: keep the last rendered screen, disable input.
    func connectionLost() {
        guard !isClosed else { return }
        startTask?.cancel()
        startTask = nil
        startInFlight = false
        phase = .disconnected
        controller.setInputEnabled(false)
    }

    private func prepareForNewRunRequest() {
        phase = .attaching
        awaitingSnapshot = true
        startInFlight = false
        startTask?.cancel()
        startTask = nil
        bufferedItems.removeAll()
        scheduleStart()
    }

    private func scheduleStart() {
        guard !isClosed, awaitingSnapshot, !startInFlight,
            startTask == nil, pendingGrid != nil
        else { return }
        startTask = Task { [weak self] in
            guard let self, !Task.isCancelled, !isClosed,
                awaitingSnapshot, !startInFlight,
                let grid = pendingGrid
            else { return }
            startInFlight = true
            await start(grid: grid)
        }
    }

    private func start(grid: TerminalOutputPipeline.Grid) async {
        guard let rpc = store?.rpc else { return }
        do {
            let snapshot: TerminalAttachSnapshot
            switch mode {
            case .create(let cwd, let title):
                snapshot = try await rpc.createTerminal(
                    TerminalCreateParams(
                        columns: Int(grid.columns),
                        cwd: cwd,
                        rows: Int(grid.rows),
                        title: title
                    ))
            case .attach(let terminalID):
                snapshot = try await rpc.attachTerminal(
                    TerminalAttachParams(
                        columns: Int(grid.columns),
                        rows: Int(grid.rows),
                        terminalID: terminalID
                    ))
            case .relaunch(let terminalID):
                snapshot = try await rpc.relaunchTerminal(
                    TerminalAttachParams(
                        columns: Int(grid.columns),
                        rows: Int(grid.rows),
                        terminalID: terminalID
                    ))
            }
            // A reconnect or replacement request may have canceled this task
            // while an RPC implementation was still completing it. Such a
            // stale response must not clear or overwrite the newer request.
            guard !Task.isCancelled else { return }
            startInFlight = false
            startTask = nil
            if isClosed {
                rpc.detachTerminal(
                    TerminalDetachParams(
                        runID: snapshot.runID,
                        terminalID: snapshot.terminal.terminalID
                    ))
                return
            }
            await apply(snapshot: snapshot)
        } catch {
            guard !Task.isCancelled else { return }
            startInFlight = false
            startTask = nil
            guard !isClosed, phase == .attaching else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    /// Installs the authoritative native model, then applies buffered items
    /// above the snapshot sequence in order. Awaiting Ghostty's completion is
    /// the visibility barrier that prevents the old/empty buffer from flashing.
    private func apply(snapshot: TerminalAttachSnapshot) async {
        let snapshotGrid = TerminalOutputPipeline.Grid(
            columns: UInt16(clamping: snapshot.columns),
            rows: UInt16(clamping: snapshot.rows)
        )
        // A native model can only be installed at its captured grid. If the
        // surface's grid moved while the request was in flight (iOS reports a
        // provisional layout before settling), discard this snapshot and
        // fetch a fresh one at the settled grid; the run it started
        // (create/relaunch) is joined with a plain attach. The daemon can also
        // reflow a naturally exited run's retained model without a live PTY.
        let canReflowSnapshot: Bool =
            switch MaidTerminalStatus(rawValue: snapshot.terminal.status) {
            case .running, .starting, .exited: true
            default: false
            }
        if canReflowSnapshot, let pendingGrid, pendingGrid != snapshotGrid {
            terminalID = snapshot.terminal.terminalID
            mode = .attach(terminalID: snapshot.terminal.terminalID)
            scheduleStart()
            return
        }

        terminalID = snapshot.terminal.terminalID
        runID = snapshot.runID
        lastAppliedSequence = snapshot.sequence
        lastSentGrid = snapshotGrid

        guard snapshot.snapshotFormat == TerminalSnapshotContract.format else {
            failSnapshot(
                String(localized: "The app and daemon use incompatible terminal snapshot versions."))
            return
        }
        guard let data = Data(base64Encoded: snapshot.snapshot), !data.isEmpty else {
            failSnapshot(String(localized: "The daemon returned an invalid terminal snapshot."))
            return
        }

        do {
            try await snapshotRestorer(controller, data)
        } catch {
            guard !isClosed else { return }
            // A layout change can race the native install after the earlier
            // check. Fetch again only when the measured grid actually moved;
            // malformed or incompatible snapshots must not retry forever.
            if canReflowSnapshot, let pendingGrid, pendingGrid != snapshotGrid {
                mode = .attach(terminalID: snapshot.terminal.terminalID)
                scheduleStart()
                return
            }
            failSnapshot(error.localizedDescription)
            return
        }
        guard !isClosed else { return }

        switch MaidTerminalStatus(rawValue: snapshot.terminal.status) {
        case .starting, .running, nil:
            phase = .running
            controller.setInputEnabled(true)
        case .exited:
            phase = .exited(snapshot.terminal.exitCode)
            controller.processDidEnd(exitCode: snapshot.terminal.exitCode)
        case .stopped:
            phase = .stopped
            controller.setInputEnabled(false)
        case .error:
            phase = .failed(String(localized: "The terminal failed"))
            controller.setInputEnabled(false)
        }

        awaitingSnapshot = false
        let buffered = bufferedItems.sorted { ($0.sequence ?? 0) < ($1.sequence ?? 0) }
        bufferedItems.removeAll()
        for item in buffered {
            applyStreamItem(item)
        }
        hasInstalledInitialSnapshot = true
        scheduleResize()
    }

    // MARK: - Stream items

    func receive(_ item: TerminalStreamMessage) {
        guard !isClosed else { return }
        if case .failed = phase { return }
        if awaitingSnapshot {
            bufferedItems.append(item)
            return
        }
        if shouldReattachForReplacementRun(item) {
            guard let terminalID else { return }
            mode = .attach(terminalID: terminalID)
            prepareForNewRunRequest()
            bufferedItems.append(item)
            return
        }
        applyStreamItem(item)
    }

    /// A relaunch is shared lifecycle state. The daemon announces the fresh
    /// running run so every listener can obtain its authoritative snapshot.
    /// Old-run exit items intentionally do not trigger another attach.
    private func shouldReattachForReplacementRun(_ item: TerminalStreamMessage) -> Bool {
        guard item.terminalID == terminalID,
            item.runID != nil, item.runID != runID,
            MaidTerminalStreamItemKind(rawValue: item.kind) == .status
        else { return false }
        return switch MaidTerminalStatus(rawValue: item.status ?? "") {
        case .starting, .running: true
        case .exited, .stopped, .error, nil: false
        }
    }

    private func applyStreamItem(_ item: TerminalStreamMessage) {
        guard item.terminalID == terminalID else { return }
        guard item.runID == runID else { return }
        let sequence = item.sequence ?? 0
        guard sequence > lastAppliedSequence else { return }
        lastAppliedSequence = sequence

        switch MaidTerminalStreamItemKind(rawValue: item.kind) {
        case .output:
            if let data = item.data {
                controller.receive(data)
            }
        case .status:
            applyStatus(item)
        case nil:
            // Unknown future kinds must not crash the client.
            break
        }
    }

    private func applyStatus(_ item: TerminalStreamMessage) {
        switch MaidTerminalStatus(rawValue: item.status ?? "") {
        case .exited:
            phase = .exited(item.exitCode)
            controller.processDidEnd(exitCode: item.exitCode)
        case .stopped:
            phase = .stopped
            controller.processDidEnd(exitCode: item.exitCode)
        case .error:
            phase = .failed(item.message ?? String(localized: "The terminal failed"))
            controller.setInputEnabled(false)
        case .starting, .running, nil:
            break
        }
    }

    private func failSnapshot(_ message: String) {
        phase = .failed(message)
        awaitingSnapshot = false
        bufferedItems.removeAll()
        controller.setInputEnabled(false)
        if let terminalID, let runID {
            store?.rpc.detachTerminal(
                TerminalDetachParams(runID: runID, terminalID: terminalID))
        }
    }

    // MARK: - Resize

    private func scheduleResize() {
        guard !isClosed, phase == .running, runID != nil,
            pendingGrid != lastSentGrid
        else { return }
        sendPendingResize()
    }

    private func sendPendingResize() {
        guard !isClosed, phase == .running,
            let terminalID, let runID,
            let grid = pendingGrid, grid != lastSentGrid
        else { return }
        lastSentGrid = grid
        store?.rpc.resizeTerminal(
            TerminalResizeParams(
                columns: Int(grid.columns),
                rows: Int(grid.rows),
                runID: runID,
                terminalID: terminalID
            ))
    }
}
