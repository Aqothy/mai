import Foundation

/// One client attachment to one terminal thread run.
///
/// The attachment owns the stable Ghostty controller for the terminal view's
/// lifetime and implements the attach contract: install the authoritative
/// snapshot, feed its replay, then apply only live items whose run matches
/// and whose sequence is greater than the snapshot sequence. Items that
/// arrive while the attach call is in flight are buffered and applied in
/// sequence order afterward.
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

    /// True once this surface has received its first authoritative replay and
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
    @ObservationIgnored private let timing: TerminalStore.Timing

    @ObservationIgnored private var lastAppliedSequence = 0
    @ObservationIgnored private var awaitingSnapshot = true
    @ObservationIgnored private var bufferedItems: [TerminalStreamMessage] = []
    @ObservationIgnored private var hasRenderedRun = false
    @ObservationIgnored private var isClosed = false

    @ObservationIgnored private var pendingGrid: TerminalOutputPipeline.Grid?
    @ObservationIgnored private var lastSentGrid: TerminalOutputPipeline.Grid?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var startInFlight = false
    @ObservationIgnored private var resizeTask: Task<Void, Never>?

    init(
        store: TerminalStore,
        origin: TerminalOpenRequest,
        mode: Mode,
        timing: TerminalStore.Timing
    ) {
        self.store = store
        self.origin = origin
        self.mode = mode
        self.timing = timing
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

    /// The first measured grid starts attach; later bursts collapse to their
    /// latest value.
    func gridChanged(columns: UInt16, rows: UInt16) {
        pendingGrid = .init(columns: columns, rows: rows)
        if runID != nil {
            scheduleResize()
        } else {
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
        startTask?.cancel()
        startTask = nil
        resizeTask?.cancel()
        resizeTask = nil
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
            guard !Task.isCancelled, let self, !isClosed,
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
            startInFlight = false
            startTask = nil
            guard !isClosed else { return }
            apply(snapshot: snapshot)
        } catch {
            startInFlight = false
            startTask = nil
            guard !isClosed, !Task.isCancelled, phase == .attaching else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    /// Installs the authoritative snapshot: reset the renderer when it showed
    /// an earlier point of the stream, feed replay, then apply buffered items
    /// above the snapshot sequence in order.
    private func apply(snapshot: TerminalAttachSnapshot) {
        terminalID = snapshot.terminal.terminalID
        runID = snapshot.runID
        lastAppliedSequence = snapshot.sequence
        lastSentGrid = .init(
            columns: UInt16(clamping: snapshot.terminal.columns),
            rows: UInt16(clamping: snapshot.terminal.rows)
        )

        if hasRenderedRun {
            // Full reset (RIS) clears the previous run/attach point — modes,
            // alternate screen, and grid contents — before replay rebuilds
            // the current screen.
            controller.receive(Data("\u{1B}c".utf8))
        }
        hasRenderedRun = true
        if let replay = snapshot.replay,
            let data = Data(base64Encoded: replay),
            !data.isEmpty
        {
            controller.receiveReplay(data)
        }

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
        store?.attachmentDidAttach(self)
    }

    // MARK: - Stream items

    func receive(_ item: TerminalStreamMessage) {
        guard !isClosed else { return }
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
        case .controlRevoked, nil:
            // Kept wire-compatible with older daemons; shared attachments do
            // not revoke one another.
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

    // MARK: - Resize

    private func scheduleResize() {
        guard !isClosed, phase == .running, runID != nil,
            pendingGrid != lastSentGrid
        else { return }
        resizeTask?.cancel()
        if timing.resizeSettleDelay == .zero {
            sendPendingResize()
            return
        }
        resizeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: timing.resizeSettleDelay)
            } catch { return }
            sendPendingResize()
        }
    }

    private func sendPendingResize() {
        resizeTask = nil
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
