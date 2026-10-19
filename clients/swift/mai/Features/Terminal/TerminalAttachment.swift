import Foundation
import GhosttyTerminal
import GhosttyVT
import SwiftUI

/// One client attachment to one terminal thread run, and the I/O of the
/// terminal view that renders it.
///
/// The attachment implements the attach contract: install the authoritative
/// native Ghostty snapshot, then apply only live items whose run matches and
/// whose sequence is greater than the snapshot's (its `TerminalFeed` does the
/// ordering, off the main actor). The view draws the daemon's grid, scaled
/// to fit. Creating, relaunching and resizing take the size, and so does
/// attaching while no other device has the terminal open; the view resizes
/// before the input that takes it.
///
/// Observable properties change only on lifecycle events; output bytes go
/// straight to the feed and never enter observation.
@Observable
final class TerminalAttachment: TerminalIO {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

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

    /// True once the first snapshot is installed. Reconnects keep the
    /// rendered screen visible while a replacement snapshot is in flight.
    private(set) var hasInstalledInitialSnapshot = false

    /// Known immediately for attach/relaunch; assigned by the create snapshot.
    private(set) var terminalID: String?

    /// The title the program set, frame by frame: the open terminal shows
    /// it as it is, while the list shows the daemon's steadier one.
    private(set) var programTitle = ""

    /// The terminal the view draws. Stable for the attachment's lifetime so
    /// SwiftUI updates never recreate the surface.
    @ObservationIgnored let terminal: Terminal

    /// The navigation request this attachment serves. Preserved across
    /// relaunch replacement so a screen opened via `.new` keeps matching.
    @ObservationIgnored let origin: TerminalOpenRequest

    /// The view's light or dark appearance, which the daemon answers the
    /// program's color queries with while this view sizes the terminal.
    @ObservationIgnored var colorScheme: ColorScheme = .dark {
        didSet {
            guard colorScheme != oldValue else { return }
            // The daemon answers with the appearance of the view holding the
            // size, which it learns from that view's resizes: while this view
            // holds it (draws its own grid), resize to that grid. Otherwise the
            // resize that takes the size carries the new appearance.
            Task {
                let grid = await terminal.grid
                if grid == preferredGrid { requestResize(grid) }
            }
        }
    }

    /// Applies the stream to the terminal, off the main actor.
    @ObservationIgnored nonisolated let feed: TerminalFeed
    @ObservationIgnored private(set) var runID: String?
    /// Names this view's subscription on the connection, so a detach sent
    /// after the terminal was reopened elsewhere cannot drop the new view's.
    @ObservationIgnored private let attachmentID = UUID().uuidString
    @ObservationIgnored private var mode: Mode
    @ObservationIgnored private weak var store: TerminalStore?
    @ObservationIgnored private var awaitingSnapshot = true
    @ObservationIgnored private var isClosed = false
    /// The grid that fits the view, which attach asks for.
    @ObservationIgnored private var preferredGrid: GridSize?
    @ObservationIgnored private var startTask: Task<Void, Never>?

    init(store: TerminalStore, origin: TerminalOpenRequest, mode: Mode) {
        self.store = store
        self.origin = origin
        self.mode = mode
        // A placeholder until the snapshot replaces it.
        // swiftlint:disable:next force_try
        let terminal = try! Terminal(grid: GridSize(columns: 80, rows: 24))
        self.terminal = terminal
        let relay = FeedEventRelay()
        feed = TerminalFeed(terminal: terminal) { event in relay.attachment?.handle(event) }
        switch mode {
        case .create:
            terminalID = nil
        case .attach(let terminalID), .relaunch(let terminalID):
            self.terminalID = terminalID
        }
        relay.attachment = self
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

    // MARK: - TerminalIO

    /// The user's input. Every attached view may write to the shared PTY;
    /// input is dropped unless this attachment is on a running shell.
    func send(_ bytes: [UInt8]) {
        guard !isClosed, phase == .running, !awaitingSnapshot, let terminalID, let runID else { return }
        store?.rpc.writeTerminal(
            TerminalWriteParams(data: Data(bytes).base64EncodedString(), runID: runID, terminalID: terminalID))
    }

    /// The view claims the size, before the input that follows.
    func requestResize(_ grid: GridSize) {
        guard !isClosed, phase == .running, let terminalID, let runID else { return }
        store?.rpc.resizeTerminal(
            TerminalResizeParams(
                appearance: MaidTerminalAppearance.wireAppearance(for: colorScheme),
                columns: Int(grid.columns),
                rows: Int(grid.rows),
                runID: runID,
                terminalID: terminalID))
    }

    func handle(_ event: TerminalEvent) {
        if case .titleChanged(let title) = event {
            programTitle = title
        }
    }

    /// The first grid that fits the view starts the attach.
    func preferredGridChanged(_ grid: GridSize) {
        preferredGrid = grid
        scheduleStart()
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
        requestSnapshot(phase: .attaching)
    }

    /// Best-effort detach; the shell keeps running on the daemon.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        // Once an attach RPC has been sent, let it finish so its returned
        // identity can detach the server-side subscription.
        if let terminalID {
            store?.rpc.detachTerminal(TerminalDetachParams(attachmentID: attachmentID, terminalID: terminalID))
        }
    }

    /// Transport loss: keep the last rendered screen, stop input.
    func connectionLost() {
        guard !isClosed else { return }
        startTask?.cancel()
        startTask = nil
        phase = .disconnected
    }

    /// Asks the daemon for a snapshot again, keeping the screen until it
    /// arrives.
    private func requestSnapshot(phase: Phase) {
        self.phase = phase
        awaitingSnapshot = true
        startTask?.cancel()
        startTask = nil
        scheduleStart()
    }

    private func scheduleStart() {
        guard !isClosed, awaitingSnapshot, startTask == nil, let grid = preferredGrid else { return }
        startTask = Task { [weak self] in
            await self?.start(grid: grid)
        }
    }

    private func start(grid: GridSize) async {
        guard let rpc = store?.rpc else { return }
        let appearance = MaidTerminalAppearance.wireAppearance(for: colorScheme)
        do {
            await feed.expectSnapshot()
            let snapshot: TerminalAttachSnapshot
            switch mode {
            case .create(let cwd, let title):
                snapshot = try await rpc.createTerminal(
                    TerminalCreateParams(
                        appearance: appearance, attachmentID: attachmentID, columns: Int(grid.columns),
                        cwd: cwd, rows: Int(grid.rows), title: title))
            case .attach(let terminalID):
                snapshot = try await rpc.attachTerminal(
                    TerminalAttachParams(
                        appearance: appearance, attachmentID: attachmentID, columns: Int(grid.columns),
                        rows: Int(grid.rows), terminalID: terminalID))
            case .relaunch(let terminalID):
                snapshot = try await rpc.relaunchTerminal(
                    TerminalAttachParams(
                        appearance: appearance, attachmentID: attachmentID, columns: Int(grid.columns),
                        rows: Int(grid.rows), terminalID: terminalID))
            }
            // A reconnect or replacement may have canceled this request while
            // the RPC completed; its response must not overwrite the newer one.
            guard !Task.isCancelled else { return }
            terminalID = snapshot.terminal.terminalID
            mode = .attach(terminalID: snapshot.terminal.terminalID)
            if isClosed {
                rpc.detachTerminal(TerminalDetachParams(attachmentID: attachmentID, terminalID: snapshot.terminal.terminalID))
                return
            }
            try await install(snapshot)
        } catch {
            guard !Task.isCancelled, !isClosed else { return }
            startTask = nil
            fail(error.localizedDescription)
        }
    }

    /// Installs the authoritative native model through the feed, which then
    /// applies items above it.
    private func install(_ snapshot: TerminalAttachSnapshot) async throws {
        guard snapshot.snapshotFormat == Self.snapshotFormat else {
            throw TerminalAttachError(String(localized: "The app and daemon use incompatible terminal snapshot versions."))
        }
        guard let data = Data(base64Encoded: snapshot.snapshot), !data.isEmpty else {
            throw TerminalAttachError(String(localized: "The daemon returned an invalid terminal snapshot."))
        }
        runID = snapshot.runID
        try await feed.install(snapshot, data: data)
        // The feed may have asked for a newer snapshot while installing.
        guard !isClosed, !Task.isCancelled else { return }
        startTask = nil
        awaitingSnapshot = false
        hasInstalledInitialSnapshot = true
        // The snapshot carries the title without announcing it.
        programTitle = await terminal.title
        switch MaidTerminalStatus(rawValue: snapshot.terminal.status) {
        case .starting, .running, nil: phase = .running
        case .exited: phase = .exited(snapshot.terminal.exitCode)
        case .stopped: phase = .stopped
        case .error: phase = .failed(String(localized: "The terminal failed"))
        }
    }

    /// GHOSTSNP v1 isn't stable across Ghostty commits, so the daemon and
    /// this app must link libghostty-vt from the same one (the daemon's
    /// `vtscreen.SnapshotFormat`).
    private static let snapshotFormat = "ghostty-gsn-v1-" + BuildInfo.commit

    fileprivate func handle(_ event: TerminalFeed.Event) {
        guard !isClosed else { return }
        switch event {
        case .ready:
            break
        case .status(let item):
            switch MaidTerminalStatus(rawValue: item.status ?? "") {
            case .exited: phase = .exited(item.exitCode)
            case .stopped: phase = .stopped
            case .error: phase = .failed(item.message ?? String(localized: "The terminal failed"))
            case .starting, .running, nil: break
            }
        case .replacementRun, .needsSnapshot:
            guard let terminalID else { return }
            mode = .attach(terminalID: terminalID)
            requestSnapshot(phase: phase == .running ? .running : .attaching)
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        awaitingSnapshot = false
        if let terminalID {
            store?.rpc.detachTerminal(TerminalDetachParams(attachmentID: attachmentID, terminalID: terminalID))
        }
    }
}

/// Hands the feed's events to the attachment, which owns the feed.
private final class FeedEventRelay {
    weak var attachment: TerminalAttachment?
}

private struct TerminalAttachError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
