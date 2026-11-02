import Foundation
import GhosttyTerminal
import GhosttyVT
import SwiftUI

/// One client attachment to one terminal thread, and the I/O of the terminal
/// view that renders it.
///
/// Attaching returns a ticket for the view's terminal stream, which begins
/// with a native Ghostty snapshot and carries everything after it; its
/// `TerminalFeed` applies it off the main actor. The view draws the daemon's grid, scaled
/// to fit, and reports the grid that fits it. The daemon sizes the terminal
/// to the view the user is using: opening, focusing, pressing or typing
/// into a view takes the size, and closing it gives the size back.
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
        /// Attach to an existing terminal.
        case attach(terminalID: String)
    }

    enum Phase: Equatable {
        case attaching
        case running
        case failed(String)
        case disconnected
    }

    private(set) var phase: Phase = .attaching

    /// True once the first snapshot is installed. Reconnects keep the
    /// rendered screen visible while a replacement snapshot is in flight.
    private(set) var hasInstalledInitialSnapshot = false

    /// Known immediately for attach; assigned by the create result.
    private(set) var terminalID: String?

    /// The title the program set, frame by frame: the open terminal shows
    /// it as it is, while the list shows the daemon's steadier one.
    private(set) var programTitle = ""

    /// The terminal the view draws. Stable for the attachment's lifetime so
    /// SwiftUI updates never recreate the surface.
    @ObservationIgnored let terminal: Terminal

    /// The navigation request this attachment serves.
    @ObservationIgnored let origin: TerminalOpenRequest

    /// The view's light or dark appearance, which the daemon answers the
    /// program's color queries with while this view has the size.
    @ObservationIgnored var colorScheme: ColorScheme = .dark {
        didSet {
            if colorScheme != oldValue { reportView() }
        }
    }

    /// Applies the stream to the terminal, off the main actor.
    @ObservationIgnored nonisolated let feed: TerminalFeed
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
    /// The view's open stream, once attach returned its ticket.
    @ObservationIgnored private var stream: TerminalStreamConnection?

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
        case .attach(let terminalID):
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
    /// input is dropped until this attachment shows the shell.
    func send(_ bytes: [UInt8]) {
        guard !isClosed, phase == .running, !awaitingSnapshot, let terminalID else { return }
        store?.rpc.writeTerminal(
            TerminalWriteParams(data: Data(bytes).base64EncodedString(), terminalID: terminalID))
    }

    /// The grid that fits the view: the first one starts the attach.
    func requestResize(_ grid: GridSize) {
        preferredGrid = grid
        scheduleStart()
        reportView()
    }

    func activate() {
        guard !isClosed, !awaitingSnapshot, let terminalID else { return }
        store?.rpc.focusTerminal(terminalID: terminalID)
    }

    func handle(_ event: TerminalEvent) {
        if case .titleChanged(let title) = event {
            programTitle = title
        }
    }

    // MARK: - Lifecycle

    /// Re-runs the attach flow, after a reconnect or when the user retries a
    /// failed attach. The last rendered screen stays visible until the new
    /// snapshot replaces it.
    func reattach() {
        guard !isClosed else { return }
        if let terminalID {
            mode = .attach(terminalID: terminalID)
        }
        // Without an identity the original create never completed; retry it
        // unchanged.
        requestSnapshot(phase: .attaching)
    }

    /// Best-effort detach; the shell keeps running on the daemon.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        closeStream()
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
        closeStream()
        phase = .disconnected
    }

    /// Attaches again for a fresh stream, keeping the screen until its
    /// snapshot arrives.
    private func requestSnapshot(phase: Phase) {
        self.phase = phase
        awaitingSnapshot = true
        startTask?.cancel()
        startTask = nil
        closeStream()
        scheduleStart()
    }

    private func scheduleStart() {
        guard !isClosed, awaitingSnapshot, startTask == nil, stream == nil, let grid = preferredGrid else { return }
        startTask = Task { [weak self] in
            await self?.start(grid: grid)
        }
    }

    /// Tells the daemon the view's grid and appearance, once it has the view.
    private func reportView() {
        guard !isClosed, !awaitingSnapshot, let terminalID, let preferredGrid else { return }
        store?.rpc.resizeTerminal(
            TerminalResizeParams(
                appearance: MaidTerminalAppearance.wireAppearance(for: colorScheme),
                columns: Int(preferredGrid.columns),
                rows: Int(preferredGrid.rows),
                terminalID: terminalID))
    }

    private func start(grid: GridSize) async {
        guard let rpc = store?.rpc else { return }
        let appearance = MaidTerminalAppearance.wireAppearance(for: colorScheme)
        do {
            let result: TerminalAttachResult
            switch mode {
            case .create(let cwd, let title):
                result = try await rpc.createTerminal(
                    TerminalCreateParams(
                        appearance: appearance, attachmentID: attachmentID, columns: Int(grid.columns),
                        cwd: cwd, rows: Int(grid.rows), title: title))
            case .attach(let terminalID):
                // Opening the terminal takes the size; attaching again after a
                // reconnect or a dropped stream doesn't.
                result = try await rpc.attachTerminal(
                    TerminalAttachParams(
                        appearance: appearance, attachmentID: attachmentID, columns: Int(grid.columns),
                        focus: !hasInstalledInitialSnapshot, rows: Int(grid.rows), terminalID: terminalID))
            }
            // A reconnect or replacement may have canceled this request while
            // the RPC completed; its response must not overwrite the newer one.
            guard !Task.isCancelled else { return }
            terminalID = result.terminal.terminalID
            mode = .attach(terminalID: result.terminal.terminalID)
            if isClosed {
                rpc.detachTerminal(TerminalDetachParams(attachmentID: attachmentID, terminalID: result.terminal.terminalID))
                return
            }
            guard let ticket = TerminalStreamConnection.ticketBytes(result.streamTicket) else {
                throw TerminalStreamError(String(localized: "maiD returned an invalid terminal stream ticket."))
            }
            startTask = nil
            await openStream(ticket: ticket, endpoint: rpc.terminalStreamEndpoint)
        } catch {
            guard !Task.isCancelled, !isClosed else { return }
            startTask = nil
            fail(error.localizedDescription)
        }
    }

    private func openStream(ticket: Data, endpoint: URL) async {
        let stream = TerminalStreamConnection(endpoint: endpoint)
        self.stream = stream
        let feed = feed
        await feed.expectSnapshot()
        Task { [weak self] in
            let (end, sawSnapshot) = await stream.run(ticket: ticket) { record in
                try await feed.apply(record)
            }
            self?.streamEnded(stream, end: end, sawSnapshot: sawSnapshot)
        }
    }

    /// The view's stream ended. A stream that never delivered a snapshot
    /// failed the attach, with no retry; one that dropped later attaches
    /// again, which converges.
    private func streamEnded(_ ended: TerminalStreamConnection, end: TerminalStreamConnection.End, sawSnapshot: Bool) {
        guard ended === stream, !isClosed else { return }
        stream = nil
        switch end {
        case .closed(.normalClosure, _):
            // The view ended on purpose: detached, replaced or deleted.
            break
        case .closed(.goingAway, _):
            // The daemon is going away or dropped this connection; the
            // connection's reconnect attaches again.
            break
        case .failed(let message):
            fail(message)
        case .closed(_, let reason) where !sawSnapshot:
            fail(reason.isEmpty ? String(localized: "maiD refused the terminal stream.") : reason)
        case .dropped where !sawSnapshot:
            fail(String(localized: "The terminal stream closed before it showed the terminal."))
        case .closed, .dropped:
            guard phase != .disconnected else { return }
            requestSnapshot(phase: phase)
        }
    }

    private func closeStream() {
        stream?.close()
        stream = nil
    }

    fileprivate func handle(_ event: TerminalFeed.Event) {
        guard !isClosed else { return }
        switch event {
        case .snapshot(let title):
            awaitingSnapshot = false
            hasInstalledInitialSnapshot = true
            // The snapshot carries the title without announcing it.
            programTitle = title
            phase = .running
            // The view may have changed while it attached.
            reportView()
        case .needsSnapshot:
            requestSnapshot(phase: phase == .running ? .running : .attaching)
        }
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        awaitingSnapshot = false
        closeStream()
        if let terminalID {
            store?.rpc.detachTerminal(TerminalDetachParams(attachmentID: attachmentID, terminalID: terminalID))
        }
    }
}

/// Hands the feed's events to the attachment, which owns the feed.
private final class FeedEventRelay {
    weak var attachment: TerminalAttachment?
}

