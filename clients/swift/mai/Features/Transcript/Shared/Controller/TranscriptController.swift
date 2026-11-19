import CoreGraphics
import Foundation
import Observation

/// One open chat's transcript, and the only owner of its scrolling (PLAN
/// 3.9): rows, their geometry, the follow state, the reading place and every
/// viewport move. The platform scroll view reports each move synchronously
/// and moves only when asked; SwiftUI reads `isEndVisible` and asks for a
/// jump, nothing else.
///
/// The rules, by number in PLAN 3.9: (1) a viewport move the controller did
/// not make, in an unchanged viewport, is the reader's, classified by
/// `ScrollFollowPolicy`; (2) its own moves, and the platform's inside the
/// setters it calls, are bracketed by `isAdjusting`, the baseline recorded
/// after; (3) a size or inset change restores the place, or the end while
/// following; (4) every geometry change keeps the reading place; (5) end
/// visibility comes from the same pass; (6) expanding stops following until
/// the end shows; (7) a jump follows; (9) the transcript shows once its
/// first rows land on the end, and keeps its place when shown again; (10) a
/// selection stops following.
@MainActor
@Observable
final class TranscriptController {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    /// Whether the transcript's end is on screen; the jump button shows when
    /// it is not. Written only here, in the pass that moves the viewport.
    private(set) var isEndVisible = true

    @ObservationIgnored let configuration: TranscriptConfiguration
    @ObservationIgnored private(set) weak var host: (any TranscriptViewportHost)?
    @ObservationIgnored private(set) var rows: [TranscriptRow] = []
    @ObservationIgnored private(set) var geometry = TranscriptGeometry()
    @ObservationIgnored private var follow = FollowState()
    @ObservationIgnored private var isAdjusting = false
    @ObservationIgnored private var updateDepth = 0
    /// Where the viewport was after the last move that counted; small steps
    /// add up against it (rule 1).
    @ObservationIgnored private var baselineTop: CGFloat = 0
    @ObservationIgnored private(set) var lastViewport: TranscriptViewport?
    @ObservationIgnored private(set) var isAwaitingInitialEnd = true
    /// The place to restore when the chat is shown again (rule 9).
    @ObservationIgnored private var detachedPlace: ReadingPlace?
    @ObservationIgnored private var detachedTop: CGFloat = 0
    /// An animated jump to the end (rule 7, iOS): when it started and how
    /// far from the end the viewport was.
    @ObservationIgnored private(set) var endJump: (start: ContinuousClock.Instant, distance: CGFloat)?
    /// Rows added by the latest change to a message's rows (a block streamed
    /// in): the host fades their text in and draws them as they arrive,
    /// which is not a failure to draw ahead. Cleared once placed.
    @ObservationIgnored var arrivedRowIDs: Set<String> = []
    #if DEBUG
        @ObservationIgnored var debugReaderMoves: [ScrollFollowPolicy.ReaderScroll] = []
    #endif

    // Layout state, used by TranscriptController+Layout.
    @ObservationIgnored var style: TextStyle
    @ObservationIgnored var palette: TextPalette?
    @ObservationIgnored var columnWidth: CGFloat = 0
    /// Layouts of rows in and near the viewport (state: being shown or about
    /// to be). Others are dropped; the layout cache may keep them.
    @ObservationIgnored var layouts: [String: RowLayout] = [:]
    /// The key each row's height was measured at.
    @ObservationIgnored var measuredKeys: [String: RowLayoutKey] = [:]
    @ObservationIgnored var synchronousHeights: [String: CGFloat] = [:]
    @ObservationIgnored var inbox: [LayoutQueue.Result] = []
    @ObservationIgnored var isDrainScheduled = false
    @ObservationIgnored var lastScheduledTop: CGFloat = 0
    @ObservationIgnored var backgroundSweepTask: Task<Void, Never>?
    @ObservationIgnored var isWarm = false
    @ObservationIgnored var openStarted = ContinuousClock.now
    @ObservationIgnored lazy var queue = LayoutQueue(
        concurrency: configuration.concurrency, cache: configuration.cachesEnabled ? TextLayoutCache.shared : nil
    ) { [weak self] result in
        Task { @MainActor in self?.receive(result) }
    }

    /// The reader's selection (PLAN 5), state: it outlives the rows'
    /// layouts and views. Used by TranscriptController+Selection.
    @ObservationIgnored var selection: TranscriptSelection?

    // Content state, used by TranscriptController+Rows.
    @ObservationIgnored var store: ThreadStore?
    @ObservationIgnored var threadID: String?
    @ObservationIgnored var turns: [TranscriptTurn] = []
    @ObservationIgnored var expandedTurnIDs: Set<String> = []
    /// The working row's verb and the latest entry it was picked for: it
    /// changes only when the agent starts something new.
    @ObservationIgnored var workingPhrase = ChatWorkingPhrases.next(after: nil)
    @ObservationIgnored var workingActivityKey: String?
    /// Parsed assistant messages: rows are state (PLAN 3.1 rule 9).
    @ObservationIgnored var parsedMessages: [String: (source: String, blocks: [MarkdownBlock])] = [:]
    @ObservationIgnored var streams: [String: TranscriptStream] = [:]
    /// The daemon has turns before the first loaded one.
    @ObservationIgnored var hasOlderTurns = false
    /// The oldest loaded turn when older ones were last asked for: asked
    /// once per loaded history while the top is near.
    @ObservationIgnored var requestedOlderBefore: String?
    @ObservationIgnored let streamWorker = TranscriptStreamWorker()

    init(configuration: TranscriptConfiguration = .launch) {
        self.configuration = configuration
        style = TextStyle.current()
    }

    var isFollowing: Bool { follow.isFollowing }

    /// Whether the controller is in the middle of a change: moving the
    /// viewport, or applying rows with their layouts. The host places rows
    /// in its layout pass once the change is complete (still before the
    /// frame), so it never sees rows whose layouts are a moment away.
    var isUpdating: Bool { isAdjusting || updateDepth > 0 }

    /// Applies `body` as one change for the host (see `isUpdating`).
    func updating(_ body: () -> Void) {
        updateDepth += 1
        body()
        updateDepth -= 1
        if updateDepth == 0 { host?.setNeedsRowPlacement() }
    }

    /// While the first rows have not landed, every change lands on the end.
    private var isFollowingEnd: Bool { isAwaitingInitialEnd || follow.isFollowing }

    // MARK: Host

    func attach(_ host: any TranscriptViewportHost) {
        self.host = host
        lastViewport = nil
        host.setContentVisible(!isAwaitingInitialEnd)
        adjusting { host.setDocumentHeight(geometry.totalHeight) }
        if let viewport = host.viewport {
            viewportBecameAvailable(viewport)
            if !isAwaitingInitialEnd {
                let top = isFollowingEnd ? endTop(viewport) : detachedPlace.flatMap(geometry.offset(for:)) ?? detachedTop
                move(to: top)
            }
        }
        detachedPlace = nil
        alignInitialEndIfPossible()
        host.setNeedsRowPlacement()
        updateFrameUpdates()
    }

    func detach(_ host: any TranscriptViewportHost) {
        guard self.host === host else { return }
        // A jump has no frames off screen: it lands now.
        if endJump != nil, let viewport = host.viewport {
            endJump = nil
            move(to: endTop(viewport))
        }
        detachedTop = host.viewportTop
        detachedPlace = geometry.readingPlace(atViewportTop: detachedTop, markerHeight: 1)
        host.setNeedsFrameUpdates(false)
        self.host = nil
    }

    /// The host calls this for every viewport move and resize, synchronously.
    func viewportDidChange() {
        guard let host, !isAdjusting, let viewport = host.viewport else { return }
        let top = host.viewportTop
        guard let last = lastViewport else {
            viewportBecameAvailable(viewport)
            alignInitialEndIfPossible()
            return
        }
        if viewport != last {
            // Rule 3: layout moved the viewport, not the reader.
            lastViewport = viewport
            if viewport.size.width != last.size.width { widthDidChange(viewport.size.width) }
            move(to: isFollowingEnd ? endTop(viewport) : baselineTop)
            alignInitialEndIfPossible()
            viewportDidMove()
            return
        }
        let from = baselineTop
        guard abs(top - from) > ScrollFollowPolicy.minimumMovement else { return }
        baselineTop = top
        if !isAwaitingInitialEnd, !geometry.isEmpty,
            let scroll = ScrollFollowPolicy.readerScroll(
                from: from, to: top, endTop: endTop(viewport), isNearBottom: isNearEnd(top: top, viewport))
        {
            follow.note(scroll)
            // The reader took over from a jump to the end.
            endJump = nil
            #if DEBUG
                debugReaderMoves.append(scroll)
            #endif
        }
        updateEndVisibility()
        viewportDidMove()
    }

    private func viewportBecameAvailable(_ viewport: TranscriptViewport) {
        lastViewport = viewport
        baselineTop = host?.viewportTop ?? 0
        if columnWidth != Self.columnWidth(for: viewport.size.width) { widthDidChange(viewport.size.width) }
        updateEndVisibility()
        viewportDidMove()
    }

    // MARK: Rows and heights

    /// Replaces the rows (rule 4). A row that stays keeps its measured
    /// height unless `measuredHeights` has one; a new row takes an estimate.
    func setRows(_ newRows: [TranscriptRow], measuredHeights: [String: CGFloat] = [:]) {
        let versioned = versioned(newRows)
        changeGeometry {
            rows = versioned
            let width = columnWidth > 0 ? columnWidth : 600
            geometry.replace(
                ids: versioned.map(\.id), sources: versioned.map(\.sourceID), measured: measuredHeights
            ) { HeightEstimator.estimate(versioned[$0].kind, width: width, style: style) }
        }
        rowsDidChange()
    }

    /// Measured heights by row ID (rule 4).
    func setHeights(_ heights: [String: CGFloat]) {
        guard !heights.isEmpty else { return }
        changeGeometry { geometry.setHeights(heights) }
    }

    /// Replaces rows `range` with `replacement` as one geometry change that
    /// touches only the rows from `range` on: a streamed message gaining a
    /// block. A row that stays keeps its height unless `heights` has one.
    func replaceRows(_ range: Range<Int>, with replacement: [TranscriptRow], heights: [String: CGFloat]) {
        var old: [String: (row: TranscriptRow, height: CGFloat, measured: Bool)] = [:]
        for index in range { old[rows[index].id] = (rows[index], geometry.height(at: index), geometry.isMeasured[index]) }
        let width = columnWidth > 0 ? columnWidth : 600
        var versioned = replacement
        var newHeights: [CGFloat] = []
        var measured: [Bool] = []
        for index in versioned.indices {
            let id = versioned[index].id
            if let previous = old[id] {
                versioned[index].contentVersion =
                    previous.row.kind == versioned[index].kind ? previous.row.contentVersion : previous.row.contentVersion + 1
            }
            if let height = heights[id] {
                newHeights.append(height)
                measured.append(true)
            } else if let previous = old[id] {
                newHeights.append(previous.height)
                measured.append(previous.measured)
            } else {
                newHeights.append(HeightEstimator.estimate(versioned[index].kind, width: width, style: style))
                measured.append(false)
            }
        }
        arrivedRowIDs = Set(versioned.lazy.map(\.id).filter { old[$0] == nil })
        changeGeometry {
            rows.replaceSubrange(range, with: versioned)
            geometry.replaceRows(
                range, ids: versioned.map(\.id), sources: versioned.map(\.sourceID), heights: newHeights,
                measured: measured)
        }
        scheduleWork()
    }

    /// Updates rows in place whose IDs stay, with their new heights: a
    /// streaming tail growing. O(changed × log n), no structural change.
    func updateRows(_ updates: [(index: Int, row: TranscriptRow)], heights: [String: CGFloat]) {
        changeGeometry {
            for (index, row) in updates where rows.indices.contains(index) && rows[index].id == row.id {
                var row = row
                row.contentVersion = rows[index].kind == row.kind ? rows[index].contentVersion : rows[index].contentVersion + 1
                rows[index] = row
            }
            geometry.setHeights(heights)
        }
    }

    /// New content versions for rows whose content changed.
    private func versioned(_ newRows: [TranscriptRow]) -> [TranscriptRow] {
        newRows.map { row in
            guard let index = geometry.index(for: row.id), rows.indices.contains(index), rows[index].id == row.id
            else { return row }
            var row = row
            let old = rows[index]
            row.contentVersion = old.kind == row.kind ? old.contentVersion : old.contentVersion + 1
            return row
        }
    }

    /// The only way geometry changes: capture the reading place, apply the
    /// change, then land on the end while following or restore the place
    /// (rule 4), and recompute end visibility in the same pass (rule 5).
    func changeGeometry(_ change: () -> Void) {
        let follows = isFollowingEnd
        let top = host?.viewportTop ?? detachedTop
        let place = follows ? nil : geometry.readingPlace(atViewportTop: top, markerHeight: 1)
        change()
        guard let host else { return }
        adjusting { host.setDocumentHeight(geometry.totalHeight) }
        if let viewport = host.viewport {
            if follows {
                move(to: endTop(viewport))
            } else {
                // Without a place to keep, the viewport still moves back
                // inside content that may have shrunk under it.
                move(to: place.flatMap(geometry.offset(for:)) ?? top)
            }
        }
        alignInitialEndIfPossible()
        host.setNeedsRowPlacement()
    }

    // MARK: Following

    /// Send and the jump button (rule 7). Animated where the host animates
    /// jumps (iOS: 0.3 s, cubic ease-out); the Mac jumps at once.
    func jumpToEnd(animated: Bool) {
        follow.noteJumpToEnd()
        endJump = nil
        guard let host, let viewport = host.viewport else { return }
        let distance = endTop(viewport) - host.viewportTop
        guard animated, host.animatesJumps, abs(distance) > ScrollFollowPolicy.minimumMovement else {
            move(to: endTop(viewport))
            updateFrameUpdates()
            return
        }
        host.stopDeceleration()
        endJump = (.now, distance)
        updateFrameUpdates()
    }

    /// One frame of an animated jump: a shrinking distance short of the end
    /// as it is now, so an end that grows on the way is still where it lands.
    func stepEndJump() {
        guard let jump = endJump, let viewport = host?.viewport else {
            endJump = nil
            return
        }
        let elapsed = jump.start.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let progress = min(1, seconds / 0.3)
        let remaining = pow(1 - progress, 3)
        move(to: endTop(viewport) - jump.distance * remaining)
        if progress >= 1 {
            endJump = nil
            updateFrameUpdates()
        }
    }

    /// The reader is about to expand or collapse a row (rule 6); call before
    /// the rows change.
    func noteExpansion() {
        follow.noteExpansion()
    }

    // MARK: Viewport math

    static func columnWidth(for viewportWidth: CGFloat) -> CGFloat {
        min(760, max(0, viewportWidth - 32)).rounded(.down)
    }

    var viewportTop: CGFloat { host?.viewportTop ?? detachedTop }

    /// The viewport top that shows the end: the content's bottom at the
    /// uncovered bottom, or its start for content shorter than the viewport.
    func endTop(_ viewport: TranscriptViewport) -> CGFloat {
        max(0, geometry.totalHeight - viewport.visibleHeight)
    }

    private func isNearEnd(top: CGFloat, _ viewport: TranscriptViewport) -> Bool {
        geometry.totalHeight - (top + viewport.visibleHeight) <= ScrollFollowPolicy.nearEndDistance
    }

    private func move(to top: CGFloat) {
        guard let host else { return }
        adjusting { host.setViewportTop(top) }
        baselineTop = host.viewportTop
        lastViewport = host.viewport
        updateEndVisibility()
    }

    /// Rule 2: viewport moves the controller causes, including the
    /// platform's own inside the setters, are not the reader's.
    private func adjusting(_ body: () -> Void) {
        let wasAdjusting = isAdjusting
        isAdjusting = true
        body()
        isAdjusting = wasAdjusting
    }

    private func updateEndVisibility() {
        guard let host, let viewport = host.viewport, !geometry.isEmpty else {
            if !isEndVisible { isEndVisible = true }
            return
        }
        let visible = isNearEnd(top: host.viewportTop, viewport)
        if isEndVisible != visible { isEndVisible = visible }
        follow.noteEndVisible(visible)
    }

    /// Rule 9: lands the first rows on the end once they and a viewport
    /// exist and the rows on the end screen are laid out, then shows them.
    func alignInitialEndIfPossible() {
        guard isAwaitingInitialEnd, let host, let viewport = host.viewport, viewport.visibleHeight > 0,
            !geometry.isEmpty, isEndScreenReady(viewport)
        else { return }
        move(to: endTop(viewport))
        isAwaitingInitialEnd = false
        host.setContentVisible(true)
        host.setNeedsRowPlacement()
        transcriptDidShow()
    }
}
