import Foundation
#if DEBUG
import OSLog
#endif

/// Owns one terminal's transport state on its own RPC connection, separate
/// from ThreadStore. Observable properties change only on lifecycle events;
/// raw output bytes flow straight to the session controller and never enter
/// observation.
///
/// This first increment drives a single development terminal: connect, create
/// once the surface reports its measured grid, stream output, forward input
/// and resize, and surface exit. Terminal lists, reattach, and persistence
/// arrive in later increments.
@Observable
final class TerminalStore {
    struct Timing: Sendable {
        let initialGridSettleDelay: Duration
        let resizeSettleDelay: Duration

        static let standard = Timing(
            initialGridSettleDelay: .milliseconds(100),
            resizeSettleDelay: .milliseconds(40)
        )

        static let immediate = Timing(
            initialGridSettleDelay: .zero,
            resizeSettleDelay: .zero
        )
    }

    enum Phase: Equatable {
        case idle
        case connecting
        case running
        case exited(Int?)
        case failed(String)
        case disconnected
    }

    private(set) var phase: Phase = .idle

    /// Stable for the store's lifetime so the Ghostty surface is never
    /// recreated by SwiftUI updates.
    @ObservationIgnored let controller: TerminalSessionController

    @ObservationIgnored private let rpc: any TerminalRPCClient
    @ObservationIgnored private let backend: TerminalDaemonBackend
    @ObservationIgnored private var started = false
    @ObservationIgnored private var isCreating = false
    @ObservationIgnored private var terminalID: String?
    @ObservationIgnored private var runID: String?
    @ObservationIgnored private var lastAppliedSequence = 0
    @ObservationIgnored private var bufferedItems: [TerminalStreamMessage] = []
    @ObservationIgnored private var pendingGrid: TerminalOutputPipeline.Grid?
    @ObservationIgnored private var lastSentGrid: TerminalOutputPipeline.Grid?
    @ObservationIgnored private var requestedCwd = ""
    @ObservationIgnored private var createTask: Task<Void, Never>?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private let timing: Timing

    #if DEBUG
    private static let logger = Logger(
        subsystem: "com.aqothy.mai",
        category: "TerminalStream"
    )
    #endif

    init(
        rpc: any TerminalRPCClient = RPCClient(),
        timing: Timing = .standard
    ) {
        self.rpc = rpc
        self.timing = timing
        let backend = TerminalDaemonBackend()
        self.backend = backend
        controller = TerminalSessionController(backend: backend)
        backend.bind(to: self)
    }

    /// Connects the transport. The terminal itself is created lazily when the
    /// surface reports its first measured grid, so the shell starts with real
    /// dimensions instead of a guess.
    func start(cwd: String = "") {
        guard !started else { return }
        started = true
        requestedCwd = cwd
        phase = .connecting
        rpc.onTerminalStreamItem = { [weak self] item in
            self?.receiveStreamItem(item)
        }
        rpc.onDisconnect = { [weak self] _ in
            self?.handleDisconnect()
        }
        rpc.connect()
        scheduleCreate()
    }

    func stop() {
        createTask?.cancel()
        createTask = nil
        resizeTask?.cancel()
        resizeTask = nil
        rpc.disconnect()
    }

    func terminate() {
        guard let terminalID else { return }
        Task {
            try? await rpc.terminateTerminal(terminalID: terminalID)
        }
    }

    /// Forwards terminal input to the daemon. Called by the backend on the
    /// MainActor in surface callback order.
    func sendInput(_ data: Data) {
        guard let terminalID, let runID, phase == .running else { return }
        rpc.writeTerminal(TerminalWriteParams(
            data: data.base64EncodedString(),
            runID: runID,
            terminalID: terminalID
        ))
    }

    /// Handles a deduplicated grid change from the surface. Initial creation
    /// waits for a stable keyboard-adjusted grid; later resize bursts keep
    /// only their latest value.
    func surfaceGridChanged(columns: UInt16, rows: UInt16) {
        pendingGrid = .init(columns: columns, rows: rows)
        if terminalID != nil, runID != nil {
            scheduleResize()
            return
        }
        scheduleCreate()
    }

    private func scheduleCreate() {
        guard started, terminalID == nil, !isCreating, pendingGrid != nil else { return }
        createTask?.cancel()
        let delay = timing.initialGridSettleDelay
        createTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, terminalID == nil, !isCreating, let grid = pendingGrid else { return }
            isCreating = true
            await createTerminal(grid: grid)
        }
    }

    private func createTerminal(grid: TerminalOutputPipeline.Grid) async {
        do {
            let snapshot = try await rpc.createTerminal(TerminalCreateParams(
                columns: Int(grid.columns),
                cwd: requestedCwd,
                rows: Int(grid.rows),
                title: nil
            ))
            guard !Task.isCancelled else { return }
            apply(snapshot: snapshot)
        } catch {
            isCreating = false
            createTask = nil
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    /// Installs the attach snapshot, then applies stream items that were
    /// buffered while the create call was in flight, ordered by sequence.
    private func apply(snapshot: TerminalAttachSnapshot) {
        isCreating = false
        createTask = nil
        terminalID = snapshot.terminal.terminalID
        runID = snapshot.runID
        lastAppliedSequence = snapshot.sequence
        lastSentGrid = .init(
            columns: UInt16(clamping: snapshot.terminal.columns),
            rows: UInt16(clamping: snapshot.terminal.rows)
        )
        phase = .running
        if let replay = snapshot.replay,
            let data = Data(base64Encoded: replay),
            !data.isEmpty {
            controller.receive(data)
        }
        let buffered = bufferedItems.sorted { ($0.sequence ?? 0) < ($1.sequence ?? 0) }
        bufferedItems.removeAll()
        for item in buffered {
            applyStreamItem(item)
        }
        scheduleResize()
    }

    private func receiveStreamItem(_ item: TerminalStreamMessage) {
        if terminalID == nil {
            bufferedItems.append(item)
            return
        }
        applyStreamItem(item)
    }

    private func applyStreamItem(_ item: TerminalStreamMessage) {
        guard item.terminalID == terminalID, item.runID == runID else { return }
        let sequence = item.sequence ?? 0
        guard sequence > lastAppliedSequence else { return }
        #if DEBUG
        if sequence != lastAppliedSequence + 1 {
            Self.logger.warning(
                "terminal sequence gap previous=\(self.lastAppliedSequence) received=\(sequence)"
            )
        }
        #endif
        lastAppliedSequence = sequence

        switch MaidTerminalStreamItemKind(rawValue: item.kind) {
        case .output:
            if let data = item.data {
                controller.receive(data)
            }
        case .status:
            applyStatus(item)
        case .controlRevoked:
            controller.setInputEnabled(false)
        case nil:
            // Unknown future kinds must not crash the client.
            break
        }
    }

    private func applyStatus(_ item: TerminalStreamMessage) {
        switch MaidTerminalStatus(rawValue: item.status ?? "") {
        case .exited, .stopped:
            phase = .exited(item.exitCode)
            controller.processDidEnd(exitCode: item.exitCode)
        case .error:
            phase = .failed(item.message ?? "The terminal failed")
        case .starting, .running, nil:
            break
        }
    }

    private func handleDisconnect() {
        createTask?.cancel()
        createTask = nil
        resizeTask?.cancel()
        resizeTask = nil
        isCreating = false
        phase = .disconnected
        controller.setInputEnabled(false)
    }

    private func scheduleResize() {
        guard phase == .running,
              terminalID != nil,
              runID != nil,
              pendingGrid != lastSentGrid
        else { return }

        resizeTask?.cancel()
        if timing.resizeSettleDelay == .zero {
            sendPendingResize()
            return
        }
        let delay = timing.resizeSettleDelay
        resizeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            self?.sendPendingResize()
        }
    }

    private func sendPendingResize() {
        resizeTask = nil
        guard phase == .running,
              let terminalID,
              let runID,
              let grid = pendingGrid,
              grid != lastSentGrid
        else { return }

        lastSentGrid = grid
        rpc.resizeTerminal(TerminalResizeParams(
            columns: Int(grid.columns),
            rows: Int(grid.rows),
            runID: runID,
            terminalID: terminalID
        ))
    }
}
