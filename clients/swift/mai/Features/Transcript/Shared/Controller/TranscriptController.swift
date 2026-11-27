import CoreGraphics
import Foundation
import Observation
import Synchronization

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
/// first rows land on the end, and keeps its place when shown again.
@MainActor
@Observable
final class TranscriptController {
    // Nonisolated for back-deployment: avoids the isolated-deinit runtime bug
    // (swiftlang/swift#88036).
    nonisolated deinit {
        // A long chat's layouts and parsed messages took 70–120 ms of the main
        // thread to free on each chat switch (iPhone 14 trace): free them on a
        // background queue, as Texture frees its nodes, soon (not `.utility`,
        // which the next chat's layout work starves while its memory stays).
        // The block must hold the only references, or it may finish first
        // and leave the last release here.
        let retained = (
            layouts, parsedMessages, deferredBackfillResults, preDrawnBands,
            rows, geometry, measuredRowHeights, rememberedHeights, turns, turnRevisions
        )
        layouts = [:]
        parsedMessages = [:]
        deferredBackfillResults = []
        preDrawnBands = [:]
        rows = []
        geometry = TranscriptGeometry()
        measuredRowHeights = [:]
        rememberedHeights = nil
        turns = []
        turnRevisions = []
        Task.detached(priority: .userInitiated) { _ = retained }
    }

    /// Thread-safe handoff from `LayoutQueue` workers so finished viewport
    /// layouts coalesce into a single main-actor drain.
    final class LayoutInbox: Sendable {
        struct State {
            var items: [(result: LayoutQueue.Result, isBackfill: Bool)] = []
            var isDrainScheduled = false
        }

        let state = Mutex<State>(State())
    }

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
    /// Saved place from a previous session of this thread, applied on initial
    /// alignment instead of landing at the end.
    @ObservationIgnored var pendingRestorePlace: TranscriptSavedPlace?
    /// An animated jump to the end (rule 7, iOS): when it started and how
    /// far from the end the viewport was.
    @ObservationIgnored private(set) var endJump: (start: ContinuousClock.Instant, distance: CGFloat)?
    /// Bands pre-drawn off the main thread with a streamed or cold layout, for
    /// the row's next placement. Every placement clears them, so they hold at
    /// most one drain's worth (never past 24 rows in the suite or 20 MB runs).
    @ObservationIgnored var preDrawnBands: [String: (layout: RowLayout, drawn: DrawnBands)] = [:]
    #if DEBUG
        @ObservationIgnored var debugReaderMoves: [ScrollFollowPolicy.ReaderScroll] = []
    #endif

    // Layout state, used by TranscriptController+Layout.
    @ObservationIgnored var style: TextStyle
    @ObservationIgnored var palette: TextPalette?
    @ObservationIgnored var columnWidth: CGFloat = 0
    /// Every laid-out row's layout, kept for the whole transcript so geometry
    /// is exact and scrolling back never lays out again (`REDESIGN.md §8`).
    @ObservationIgnored var layouts: [String: RowLayout] = [:]
    /// Measured heights recorded at `(columnWidth, style.version)` during this
    /// controller's lifetime; persisted onto `ThreadSession` on detach.
    @ObservationIgnored var measuredRowHeights: [String: CGFloat] = [:]
    /// Remembered heights from a prior open of this thread, seeded when
    /// `(columnWidth, style.version)` matches.
    @ObservationIgnored var rememberedHeights: TranscriptMeasuredHeights?
    @ObservationIgnored let layoutInbox = LayoutInbox()
    @ObservationIgnored var urgentGeneration = 0
    @ObservationIgnored var lastScheduledTop: CGFloat = 0
    @ObservationIgnored var isScrollingDown = true
    @ObservationIgnored var openStarted = ContinuousClock.now
    @ObservationIgnored var backfillResumeTask: Task<Void, Never>?
    @ObservationIgnored var isBackfillTemporarilyPaused = false
    @ObservationIgnored var needsBackfillRebuild = false
    /// Backfill results that arrived just as a selection started; drained once
    /// the selection clears so off-screen height shifts never flicker UIKit's
    /// selection highlight or dismiss its edit menu.
    @ObservationIgnored var deferredBackfillResults: [LayoutQueue.Result] = []
    @ObservationIgnored lazy var queue = LayoutQueue(concurrency: configuration.concurrency) {
        [weak self, inbox = layoutInbox] result, isBackfill in
        let shouldSchedule = inbox.state.withLock { state -> Bool in
            state.items.append((result, isBackfill))
            guard !state.isDrainScheduled else { return false }
            state.isDrainScheduled = true
            return true
        }
        if shouldSchedule {
            Task { @MainActor [weak self] in self?.drainInbox() }
        }
    }

    /// How far each wide block is scrolled sideways, keyed by row ID so a
    /// block scrolled out of view comes back where it was left, as a browser
    /// keeps an element's `scrollLeft`.
    @ObservationIgnored var wideBlockOffsets: [String: CGFloat] = [:]

    /// The reader's selection (PLAN 5), state: it outlives the rows'
    /// layouts and views. Used by TranscriptController+Selection.
    @ObservationIgnored var selection: TranscriptSelection?

    // Content state, used by TranscriptController+Rows.
    @ObservationIgnored var store: ThreadStore?
    @ObservationIgnored var threadID: String?
    @ObservationIgnored var turns: [TranscriptTurn] = []
    @ObservationIgnored var plan: [PlanEntry] = []
    @ObservationIgnored var lastSnapshotID: Int?
    @ObservationIgnored var turnRevisions: [Int] = []
    @ObservationIgnored var expandedTurnIDs: Set<String> = []
    /// The working row's verb and the latest entry it was picked for: it
    /// changes only when the agent starts something new.
    @ObservationIgnored var workingPhrase = ChatWorkingPhrases.next(after: nil)
    @ObservationIgnored var workingActivityKey: String?
    /// Parsed messages (user, assistant, reasoning): rows are state (`REDESIGN.md §8`:
    /// kept for the whole transcript so revisiting history never re-parses).
    /// Metrics are cached alongside blocks so rebuilds stay O(blocks) on the main thread.
    @ObservationIgnored var parsedMessages: [String: (source: String, blocks: [MarkdownBlock], metrics: [TextMetrics])] = [:]
    @ObservationIgnored var streams: [String: TranscriptStream] = [:]
    /// The daemon has turns before the first loaded one.
    @ObservationIgnored var hasOlderTurns = false
    /// The oldest loaded turn when older ones were last asked for: asked
    /// once per loaded history while the top is near.
    @ObservationIgnored var requestedOlderBefore: String?
    @ObservationIgnored let streamWorker = TranscriptStreamWorker()

    init(configuration: TranscriptConfiguration = TranscriptConfiguration()) {
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
        }
        alignInitialEndIfPossible()
        queue.setBackfillPaused(shouldPauseBackfill)
        if !isAwaitingInitialEnd { scheduleBackfill() }
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
        detachedTop = host.viewport != nil ? host.viewportTop : baselineTop
        detachedPlace = geometry.readingPlace(atViewportTop: detachedTop)
        persistSavedPlace()
        let stale = (preDrawnBands, deferredBackfillResults)
        preDrawnBands = [:]
        deferredBackfillResults = []
        if !stale.0.isEmpty || !stale.1.isEmpty {
            Task.detached(priority: .userInitiated) { _ = stale }
        }
        backfillResumeTask?.cancel()
        backfillResumeTask = nil
        isBackfillTemporarilyPaused = false
        queue.setBackfillPaused(false)
        Task { await queue.cancelAll() }
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
            let widthChanged = viewport.size.width != last.size.width
            // When resizing away from the end, anchor the first visible
            // character on the top row (or proportional offset for non-text
            // rows) so tall paragraphs keep the exact reading line pinned.
            var resizeAnchor: (rowID: String, charOffset: Int?, fraction: CGFloat)?
            if widthChanged, !isFollowingEnd, !isAwaitingInitialEnd,
                let anchorIdx = geometry.index(at: baselineTop)
            {
                let rowID = rows[anchorIdx].id
                let (rowMinY, rowHeight) = geometry.frame(at: anchorIdx)
                let localY = max(0, baselineTop - rowMinY)
                let charOffset = layouts[rowID]?.content.textOffset(closestTo: CGPoint(x: 0, y: localY))
                let fraction = rowHeight > 0 ? min(1, localY / rowHeight) : 0
                resizeAnchor = (rowID: rowID, charOffset: charOffset, fraction: fraction)
            }
            if widthChanged { widthDidChange(viewport.size.width) }
            if endJump != nil {
                stepEndJump()
            } else if isAwaitingInitialEnd {
                move(to: initialTargetTop(viewport).top)
            } else {
                // Keep the end pinned when the keyboard opens/closes while the
                // reader is already within the near-bottom zone (even if a tiny
                // finger-lift wiggle flipped `isFollowing` off).
                let pinsToEnd =
                    isFollowingEnd || (viewport.bottomInset != last.bottomInset && isNearEnd(top: baselineTop, last))
                if pinsToEnd {
                    move(to: endTop(viewport))
                } else if let anchor = resizeAnchor, let idx = geometry.index(for: anchor.rowID) {
                    let (newMinY, newHeight) = geometry.frame(at: idx)
                    let localY: CGFloat
                    if let charOff = anchor.charOffset,
                        let caret = layouts[anchor.rowID]?.content.caretRect(for: charOff)
                    {
                        localY = min(newHeight, max(0, caret.minY))
                    } else {
                        localY = anchor.fraction * newHeight
                    }
                    move(to: newMinY + localY)
                } else {
                    move(to: baselineTop)
                }
            }
            alignInitialEndIfPossible()
            viewportDidMove()
            return
        }
        let from = baselineTop
        guard abs(top - from) > ScrollFollowPolicy.minimumMovement else { return }
        baselineTop = top
        if abs(top - from) > 4 { isScrollingDown = top > from }
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
        if columnWidth != Self.columnWidth(for: viewport.size.width) { widthDidChange(viewport.size.width) }
        if !isAwaitingInitialEnd {
            let top = isFollowingEnd ? endTop(viewport) : detachedPlace.flatMap(geometry.offset(for:)) ?? detachedTop
            detachedPlace = nil
            move(to: top)
        } else {
            detachedPlace = nil
            if !geometry.isEmpty {
                move(to: initialTargetTop(viewport).top)
            } else {
                baselineTop = host?.viewportTop ?? 0
                updateEndVisibility()
            }
        }
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
            let spans = versioned.map(Self.selectableSpan(for:))
            geometry.replace(
                ids: versioned.map(\.id), sources: versioned.map(\.sourceID), measured: measuredHeights,
                selectableSpans: spans
            ) { index in
                rememberedHeight(for: versioned[index])
                    ?? HeightEstimator.estimate(versioned[index], width: width, style: style)
            }
        }
        scheduleWork()
    }

    /// Measured heights by row ID (rule 4).
    func setHeights(_ heights: [String: CGFloat]) {
        guard !heights.isEmpty else { return }
        changeGeometry(preservesRowIDs: true) { geometry.setHeights(heights) }
    }

    /// Replaces rows `range` with `replacement` as one geometry change that
    /// touches only the rows from `range` on: a streamed message gaining a
    /// block or a parsed message expanding in place. A row that stays keeps its
    /// height unless `heights` has one.
    func replaceRows(
        _ range: Range<Int>, with replacement: [TranscriptRow], heights: [String: CGFloat],
        shouldSchedule: Bool = true
    ) {
        var old: [String: (row: TranscriptRow, height: CGFloat)] = [:]
        for index in range { old[rows[index].id] = (rows[index], geometry.height(at: index)) }
        let width = columnWidth > 0 ? columnWidth : 600
        var versioned = replacement
        var newHeights: [CGFloat] = []
        newHeights.reserveCapacity(versioned.count)
        for index in versioned.indices {
            let id = versioned[index].id
            let previous = old[id]
            let sameKind = previous.map { $0.row.kind == versioned[index].kind } ?? false
            if let previous {
                versioned[index].contentVersion = sameKind ? previous.row.contentVersion : previous.row.contentVersion + 1
                if !sameKind { measuredRowHeights.removeValue(forKey: id) }
            }
            let reusedHeight: CGFloat? =
                if let explicit = heights[id] {
                    explicit
                } else if let previous {
                    sameKind ? previous.height : nil
                } else {
                    rememberedHeight(for: versioned[index])
                }
            newHeights.append(reusedHeight ?? HeightEstimator.estimate(versioned[index], width: width, style: style))
        }
        // Drop cached layouts and measured heights for rows leaving the
        // transcript so a reused ID (such as `"working"` on the next turn)
        // cannot collide at contentVersion 0 or reuse a stale height.
        var remappedSelection: TranscriptSelection?
        if !old.isEmpty {
            let kept = Set(versioned.lazy.map(\.id))
            for id in old.keys where !kept.contains(id) {
                removeLayout(for: id)
                measuredRowHeights.removeValue(forKey: id)
            }
            if let current = selection {
                let newAnchor = remapRemovedPosition(current.anchor, old: old, kept: kept, replacement: versioned)
                let newFocus = remapRemovedPosition(current.focus, old: old, kept: kept, replacement: versioned)
                if newAnchor != current.anchor || newFocus != current.focus {
                    remappedSelection = TranscriptSelection(anchor: newAnchor, focus: newFocus)
                }
            }
        }
        changeGeometry(replacingRange: range) {
            rows.replaceSubrange(range, with: versioned)
            geometry.replaceRows(
                range, ids: versioned.map(\.id), sources: versioned.map(\.sourceID), heights: newHeights,
                selectableSpans: versioned.map(Self.selectableSpan(for:)))
        }
        if let remappedSelection {
            selection = remappedSelection
            host?.setNeedsSelectionDisplay()
        }
        if shouldSchedule { scheduleWork() }
    }

    /// Remaps a selection endpoint anchored on a replaced row (such as a
    /// `.pendingMessage` expanding into its parsed blocks) onto the surviving
    /// rows for the same `sourceID` so Select All and cross-row selections
    /// survive lazy parsing.
    private func remapRemovedPosition(
        _ position: TextPosition,
        old: [String: (row: TranscriptRow, height: CGFloat)],
        kept: Set<String>,
        replacement: [TranscriptRow]
    ) -> TextPosition {
        guard !kept.contains(position.rowID), let removed = old[position.rowID]?.row else { return position }
        let matching = replacement.filter { $0.sourceID == removed.sourceID && $0.kind.isSelectable }
        guard let first = matching.first, let last = matching.last else { return position }
        if position.offset <= 0 {
            return TextPosition(rowID: first.id, offset: 0)
        }
        if let oldLength = removed.metrics.selectableUTF16 ?? RowSelectableText.utf16Length(for: removed.kind),
            position.offset >= oldLength
        {
            let lastLength = last.metrics.selectableUTF16 ?? RowSelectableText.utf16Length(for: last.kind) ?? 0
            return TextPosition(rowID: last.id, offset: lastLength)
        }
        var remaining = position.offset
        for (idx, row) in matching.enumerated() {
            if idx > 0 { remaining = max(0, remaining - 1) }
            let len = row.metrics.selectableUTF16 ?? RowSelectableText.utf16Length(for: row.kind) ?? 0
            if remaining <= len {
                return TextPosition(rowID: row.id, offset: remaining)
            }
            remaining -= len
        }
        let lastLength = last.metrics.selectableUTF16 ?? RowSelectableText.utf16Length(for: last.kind) ?? 0
        return TextPosition(rowID: last.id, offset: lastLength)
    }

    /// Updates rows in place whose IDs stay, with their new heights: a
    /// streaming tail growing. O(changed × log n), no structural change.
    func updateRows(_ updates: [(index: Int, row: TranscriptRow)], heights: [String: CGFloat]) {
        changeGeometry(preservesRowIDs: true) {
            for (index, row) in updates where rows.indices.contains(index) && rows[index].id == row.id {
                var row = row
                let changed = rows[index].kind != row.kind
                row.contentVersion = changed ? rows[index].contentVersion + 1 : rows[index].contentVersion
                if changed, heights[row.id] == nil { measuredRowHeights.removeValue(forKey: row.id) }
                rows[index] = row
                if changed { geometry.setSelectableSpan(Self.selectableSpan(for: row), at: index) }
            }
            geometry.setHeights(heights)
        }
    }

    private static func selectableSpan(for row: TranscriptRow) -> Int {
        guard row.kind.isSelectable else { return 0 }
        let len = row.metrics.selectableUTF16 ?? RowSelectableText.utf16Length(for: row.kind) ?? 0
        return 1 + len
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
    func changeGeometry(
        preservesRowIDs: Bool = false, replacingRange: Range<Int>? = nil, _ change: () -> Void
    ) {
        let follows = isFollowingEnd
        let top = host?.viewportTop ?? detachedTop
        let place: ReadingPlace?
        if follows {
            place = nil
        } else if let replacingRange {
            place = geometry.readingPlace(atViewportTop: top, replacingRange: replacingRange)
        } else {
            place = geometry.readingPlace(atViewportTop: top, includeFallbacks: !preservesRowIDs)
        }
        change()
        guard let host else { return }
        adjusting { host.setDocumentHeight(geometry.totalHeight) }
        if let viewport = host.viewport {
            if endJump != nil {
                // Keep stepping the animated jump toward the newly grown end
                // instead of snapping and oscillating back on the next tick.
                stepEndJump()
            } else if isAwaitingInitialEnd {
                move(to: initialTargetTop(viewport).top)
            } else if follows {
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
        pendingRestorePlace = nil
        follow.noteJumpToEnd()
        endJump = nil
        guard let host, let viewport = host.viewport else { return }
        if isAwaitingInitialEnd {
            move(to: endTop(viewport))
            scheduleWork()
            alignInitialEndIfPossible()
            return
        }
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

    /// Resolves the clipboard text for a copy accessory action.
    func copyText(for action: RowAccessory.Action) -> String {
        switch action {
        case .copy(let text, _): text
        case .copyReply(let turnID): replyMarkdown(forTurnID: turnID)
        case .fork: ""
        }
    }

    /// Lazily joins the assistant reply Markdown for `turnID` only when the
    /// user clicks Copy Reply (avoids duplicating strings on every rebuild).
    func replyMarkdown(forTurnID turnID: String) -> String {
        guard let turn = turns.first(where: { $0.id == turnID }) else { return "" }
        return turn.entries
            .filter { $0.kind == .assistantMessage && !$0.text.isEmpty }
            .map(\.text)
            .joined(separator: "\n\n")
    }

    /// Rule 2: viewport moves the controller causes, including the
    /// platform's own inside the setters, are not the reader's.
    private func adjusting(_ body: () -> Void) {
        let wasAdjusting = isAdjusting
        isAdjusting = true
        body()
        isAdjusting = wasAdjusting
    }

    /// Compact reading place to persist across thread switches; nil while
    /// following the end or before initial alignment has shown the transcript.
    func savedPlace() -> TranscriptSavedPlace? {
        guard !isAwaitingInitialEnd, !follow.isFollowing, !geometry.isEmpty else { return nil }
        let top = host.map { $0.viewport != nil ? $0.viewportTop : baselineTop } ?? detachedTop
        guard let place = geometry.readingPlace(atViewportTop: top) else { return nil }
        return TranscriptSavedPlace(
            anchorID: place.anchorID, offsetIntoRow: place.offsetIntoRow, source: place.source,
            offsetIntoSource: place.offsetIntoSource, expandedTurnIDs: expandedTurnIDs)
    }

    /// Configures initial alignment to reopen at `saved` instead of the end.
    func restoreSavedPlace(_ saved: TranscriptSavedPlace) {
        guard isAwaitingInitialEnd else { return }
        expandedTurnIDs = saved.expandedTurnIDs
        pendingRestorePlace = saved
    }

    /// Saves the reader's position and measured heights into the store's
    /// session cache on detach: every way a chat leaves (another chat selected,
    /// a pop, its window closing) takes its view out of the window. Never
    /// overwrites a saved place while still hidden waiting for initial alignment.
    private func persistSavedPlace() {
        guard let store, let threadID else { return }
        if columnWidth > 0, !measuredRowHeights.isEmpty {
            let input = measuredHeightsInput()
            store.saveTranscriptMeasuredHeights(for: threadID) { input.build() }
        }
        guard !isAwaitingInitialEnd else { return }
        store.setSavedTranscriptPlace(savedPlace(), for: threadID)
    }

    /// Remembered height for `row` when `(columnWidth, style.version)` matches.
    func rememberedHeight(for row: TranscriptRow) -> CGFloat? {
        if let height = measuredRowHeights[row.id] { return height }
        guard let remembered = rememberedHeights, columnWidth > 0,
            remembered.width == columnWidth, remembered.styleVersion == style.version
        else { return nil }
        if let height = remembered.rowHeights[row.id] { return height }
        if case .pendingMessage = row.kind { return remembered.sourceHeights[row.sourceID] }
        return nil
    }

    /// Seeds remembered heights onto already-loaded rows once the initial
    /// column width is known (handles `start(store:threadID:)` running before
    /// `attach(host)`).
    func applyRememberedHeightsIfMatching() {
        guard let remembered = rememberedHeights, columnWidth > 0,
            remembered.width == columnWidth, remembered.styleVersion == style.version, !rows.isEmpty
        else { return }
        var updates: [String: CGFloat] = [:]
        for row in rows where layouts[row.id] == nil && measuredRowHeights[row.id] == nil {
            if let height = remembered.rowHeights[row.id] {
                updates[row.id] = height
            } else if case .pendingMessage = row.kind, let height = remembered.sourceHeights[row.sourceID] {
                updates[row.id] = height
            }
        }
        if !updates.isEmpty { setHeights(updates) }
    }

    private struct MeasuredHeightsInput: Sendable {
        let width: CGFloat
        let styleVersion: Int
        let rows: [TranscriptRow]
        let turns: [TranscriptTurn]
        let streamSourceIDs: Set<String>
        let measuredRowHeights: [String: CGFloat]
        let rememberedHeights: TranscriptMeasuredHeights?

        nonisolated func build() -> TranscriptMeasuredHeights? {
            guard width > 0 else { return nil }
            let runningTurnIDs = Set(turns.lazy.filter(\.isRunning).map(\.id))
            var volatileRowIDs: Set<String> = []
            var volatileSourceIDs = streamSourceIDs
            for row in rows {
                if streamSourceIDs.contains(row.sourceID) || row.turnID.map({ runningTurnIDs.contains($0) }) == true {
                    volatileRowIDs.insert(row.id)
                    volatileSourceIDs.insert(row.sourceID)
                }
            }
            var rowHeights: [String: CGFloat] = [:]
            var sourceHeights: [String: CGFloat] = [:]
            if let remembered = rememberedHeights,
                remembered.width == width, remembered.styleVersion == styleVersion
            {
                rowHeights = remembered.rowHeights
                sourceHeights = remembered.sourceHeights
            }
            for (id, height) in measuredRowHeights where !volatileRowIDs.contains(id) {
                rowHeights[id] = height
            }
            for id in volatileRowIDs { rowHeights.removeValue(forKey: id) }
            for sourceID in volatileSourceIDs { sourceHeights.removeValue(forKey: sourceID) }
            guard !rowHeights.isEmpty || !sourceHeights.isEmpty else { return nil }
            // Sum measured heights per sourceID so unparsed `.pendingMessage` rows
            // on the next open start with the exact total height of their blocks.
            var totals: [String: (sum: CGFloat, complete: Bool)] = [:]
            for row in rows where !volatileSourceIDs.contains(row.sourceID) {
                if case .pendingMessage = row.kind { continue }
                var entry = totals[row.sourceID] ?? (0, true)
                if let height = rowHeights[row.id] {
                    entry.sum += height
                } else {
                    entry.complete = false
                }
                totals[row.sourceID] = entry
            }
            for (sourceID, entry) in totals where entry.complete && entry.sum > 0 {
                sourceHeights[sourceID] = entry.sum
            }
            return TranscriptMeasuredHeights(
                width: width, styleVersion: styleVersion, rowHeights: rowHeights, sourceHeights: sourceHeights)
        }
    }

    private func measuredHeightsInput() -> MeasuredHeightsInput {
        MeasuredHeightsInput(
            width: columnWidth, styleVersion: style.version, rows: rows, turns: turns,
            streamSourceIDs: Set(streams.keys), measuredRowHeights: measuredRowHeights,
            rememberedHeights: rememberedHeights)
    }

    /// Snapshots all measured row and message-source heights for finished turns
    /// at the current `(columnWidth, style.version)` for persistence on
    /// `ThreadSession`. Running/streaming turns are excluded so mid-stream
    /// heights never become stale if the turn finishes while detached.
    func snapshotMeasuredHeights() -> TranscriptMeasuredHeights? {
        measuredHeightsInput().build()
    }

    /// Where initial alignment wants the viewport: the restored saved place if
    /// its row or source still exists, otherwise the end.
    func initialTargetTop(_ viewport: TranscriptViewport) -> (top: CGFloat, restored: Bool) {
        if let saved = pendingRestorePlace, let offset = geometry.offset(for: saved) {
            return (min(max(0, offset), endTop(viewport)), true)
        }
        return (endTop(viewport), false)
    }

    private func updateEndVisibility() {
        guard let host, let viewport = host.viewport, !geometry.isEmpty, !isAwaitingInitialEnd else {
            if !isEndVisible { isEndVisible = true }
            return
        }
        let visible = isNearEnd(top: host.viewportTop, viewport)
        if isEndVisible != visible { isEndVisible = visible }
        follow.noteEndVisible(visible)
    }

    /// Rule 9: lands the first rows on the end (or restored saved place) once
    /// they and a viewport exist and the visible screen is laid out, then shows
    /// them.
    func alignInitialEndIfPossible() {
        guard isAwaitingInitialEnd, let host, let viewport = host.viewport, viewport.visibleHeight > 0,
            !geometry.isEmpty, isEndScreenReady(viewport)
        else { return }
        let target = initialTargetTop(viewport)
        if target.restored, !isNearEnd(top: target.top, viewport) {
            follow.note(.awayFromEnd)
        }
        pendingRestorePlace = nil
        isAwaitingInitialEnd = false
        move(to: target.top)
        host.setContentVisible(true)
        host.setNeedsRowPlacement()
        transcriptDidShow()
    }
}
