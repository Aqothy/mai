import CoreGraphics
import Foundation
import QuartzCore
import Synchronization

/// Layout, exact geometry backfill, and in-frame visible preparation
/// (`REDESIGN.md §4.6, §7 R3, §8`): visible rows always have current-key
/// layouts and draw in the frame (zero blanks, zero live-resize width lag);
/// once the initial screen shows, background workers backfill exact geometry
/// for all remaining history nearest-first while keeping the viewport anchored.
extension TranscriptController {
    /// The key a row's layout must have to be current.
    func currentKey(_ row: TranscriptRow) -> RowLayoutKey {
        RowLayoutKey(contentVersion: row.contentVersion, width: columnWidth, styleVersion: style.version)
    }

    func storeLayout(_ layout: RowLayout) {
        layouts[layout.rowID] = layout
    }

    func removeLayout(for rowID: String) {
        layouts.removeValue(forKey: rowID)
        preDrawnBands.removeValue(forKey: rowID)
    }

    func cacheParsedMessage(id: String, source: String, blocks: [MarkdownBlock], metrics: [TextMetrics] = []) {
        parsedMessages[id] = (source, blocks, metrics)
    }

    /// Builds a layout request for `row`, passing the previous layout when the
    /// text size still matches so prose, code, and tables reuse `PreparedText`
    /// across resizes and streaming.
    func request(_ row: TranscriptRow) -> RowLayoutRequest {
        let key = currentKey(row)
        var request = RowLayoutRequest(rowID: row.id, kind: row.kind, key: key, style: style)
        if let current = layouts[row.id], current.key.contentVersion == key.contentVersion,
            current.key.styleVersion == key.styleVersion
        {
            request.previous = (row.kind, current)
        }
        return request
    }

    // MARK: For the host

    /// The cached layout for row `index`, or `nil` if not yet built.
    func layout(forRowAt index: Int) -> RowLayout? {
        layouts[rows[index].id]
    }

    /// Ensures every row intersecting `visible` is parsed and has a current-key
    /// layout synchronously in the frame (`REDESIGN.md §1 rule 3, §7 R3`):
    /// eliminates blank frames during scrubbing/flinging and stale widths on
    /// resize, with no artificial byte or cell caps.
    func ensureVisibleRowsReady(in visible: CGRect) {
        guard configuration.laysOutRows, columnWidth > 0, !isAwaitingInitialEnd,
            let range = geometry.indices(overlapping: max(0, visible.minY), visible.maxY)
        else { return }
        // Fast path: 99% of frames already have every visible row current.
        var hasMissing = false
        for index in range {
            let row = rows[index]
            if case .pendingMessage = row.kind {
                hasMissing = true
                break
            }
            if layouts[row.id]?.key != currentKey(row) {
                hasMissing = true
                break
            }
        }
        guard hasMissing else { return }

        // 1. Parse any visible `.pendingMessage` rows and splice their blocks
        //    with estimates first; step 2 below lays out strictly the blocks
        //    actually intersecting the visible viewport (never off-screen
        //    blocks of a multi-block message on the main thread).
        var parsedBatch: [ParsedBatchItem] = []
        for index in range {
            guard case .pendingMessage(let message, let source) = rows[index].kind else { continue }
            let blocks = MarkdownPlanner.blocks(from: source)
            let builtRows = message.rows(from: blocks)
            let metrics = builtRows.map(\.metrics)
            cacheParsedMessage(id: message.id, source: source, blocks: blocks, metrics: metrics)
            parsedBatch.append(ParsedBatchItem(message: message, source: source, rows: builtRows, layouts: nil, drawn: []))
        }
        if !parsedBatch.isEmpty {
            applyParsedMessages(parsedBatch, shouldSchedule: false)
        }

        // 2. Lay out (or arithmetic-resize) any remaining visible row whose
        // layout is missing or stale.
        let currentMinY = host.map { $0.viewportTop - ($0.viewport?.topInset ?? 0) } ?? visible.minY
        guard let visibleRange = geometry.indices(overlapping: max(0, currentMinY), currentMinY + visible.height) else {
            return
        }
        var syncHeights: [String: CGFloat] = [:]
        for index in visibleRange {
            let row = rows[index]
            if case .pendingMessage = row.kind { continue }
            guard layouts[row.id]?.key != currentKey(row) else { continue }
            let layout = RowLayoutBuilder.layout(request(row))
            storeLayout(layout)
            syncHeights[row.id] = layout.height
            measuredRowHeights[row.id] = layout.height
        }
        if !syncHeights.isEmpty {
            setHeights(syncHeights)
        }
    }

    /// Distance from row `index` to the visible viewport `[top, top + screen]`
    /// (0 for every row intersecting the viewport).
    private func viewportDistance(ofRowAt index: Int, top: CGFloat, screen: CGFloat) -> Int {
        let frame = geometry.frame(at: index)
        if frame.minY + frame.height < top { return Int(top - (frame.minY + frame.height)) }
        if frame.minY > top + screen { return Int(frame.minY - (top + screen)) }
        return 0
    }

    /// Queues off-screen prefetch rows that have no layout yet.
    func prefetch(_ indices: [Int]) {
        guard configuration.laysOutRows, columnWidth > 0 else { return }
        let top = viewportTop
        let screen = max(1, (host?.viewport ?? lastViewport)?.visibleHeight ?? 800)
        let drawing = currentDrawing
        let nearLimit = Int(screen)
        let jobs = indices.compactMap { index -> LayoutQueue.Job? in
            let distance = viewportDistance(ofRowAt: index, top: top, screen: screen)
            return job(for: index, priority: distance, drawing: distance <= nearLimit ? drawing : nil)
        }
        guard !jobs.isEmpty else { return }
        let generation = urgentGeneration
        Task { await queue.submit(urgent: jobs, generation: generation, replacingUrgent: false) }
    }

    func setPalette(_ palette: TextPalette) {
        let themeChanged = self.palette?.isDark != palette.isDark
        self.palette = palette
        guard themeChanged else { return }
        host?.setNeedsRowPlacement()
    }

    /// The text size changed (Dynamic Type): every layout is stale. Visible
    /// rows re-lay out on placement and off-screen rows backfill off-main.
    func updateStyle() {
        let style = TextStyle.current()
        guard style.version != self.style.version else { return }
        self.style = style
        measuredRowHeights.removeAll()
        guard configuration.laysOutRows else { return }
        scheduleWork()
        scheduleBackfill()
        host?.setNeedsRowPlacement()
    }

    // MARK: Scheduling

    func viewportDidMove() {
        loadOlderTurnsIfNearTop()
        guard configuration.laysOutRows, let viewport = lastViewport else { return }
        pauseBackfillBriefly(rebuildAfter: false)
        // Most frames stay inside the scheduled window; reschedule once the
        // viewport has moved a quarter screen.
        if abs(viewportTop - lastScheduledTop) > viewport.visibleHeight / 4 { scheduleWork() }
    }

    func widthDidChange(_ viewportWidth: CGFloat) {
        let width = Self.columnWidth(for: viewportWidth)
        guard width != columnWidth else { return }
        let wasInitial = columnWidth == 0
        columnWidth = width
        if wasInitial {
            applyRememberedHeightsIfMatching()
        } else {
            measuredRowHeights.removeAll()
            pauseBackfillBriefly(rebuildAfter: true)
            // Re-fit visible rows synchronously in the frame via arithmetic
            // `PreparedText.fit(width:)` so text tracks the window edge with
            // zero lag (`REDESIGN.md §4.2, §7 R3`).
            if configuration.laysOutRows, !isAwaitingInitialEnd,
                let viewport = host?.viewport ?? lastViewport
            {
                let visTop = max(0, viewportTop - viewport.topInset)
                if let range = geometry.indices(overlapping: visTop, viewportTop + viewport.visibleHeight) {
                    var resizedHeights: [String: CGFloat] = [:]
                    for index in range {
                        let row = rows[index]
                        if case .pendingMessage = row.kind { continue }
                        let layout = RowLayoutBuilder.layout(request(row))
                        storeLayout(layout)
                        resizedHeights[row.id] = layout.height
                        measuredRowHeights[row.id] = layout.height
                    }
                    if !resizedHeights.isEmpty {
                        setHeights(resizedHeights)
                    }
                }
            }
        }
        scheduleWork()
    }

    /// Pauses `.utility` backfill while the reader scrolls or resizes, whose
    /// frames may lay out and draw rows on the main thread, then resumes (or
    /// rebuilds backfill for the new width) once idle for 250 ms. Streaming
    /// does not pause it: a stream can last minutes, and frames measured the
    /// same with it running (stream 4,000 cps: 118.9 vs 119.0 fps).
    func pauseBackfillBriefly(rebuildAfter: Bool) {
        guard configuration.laysOutRows, !isAwaitingInitialEnd else { return }
        if rebuildAfter { needsBackfillRebuild = true }
        Task { await queue.setBackfillPaused(true) }
        backfillResumeTask?.cancel()
        backfillResumeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.host != nil else { return }
            if self.needsBackfillRebuild {
                self.needsBackfillRebuild = false
                self.scheduleBackfill()
            } else {
                await self.queue.setBackfillPaused(false)
            }
        }
    }

    /// Lays out the viewport and prefetch window urgently (`O(visible rows)`,
    /// never scanning the whole transcript).
    func scheduleWork() {
        guard configuration.laysOutRows, columnWidth > 0, let viewport = host?.viewport ?? lastViewport else { return }
        let screen = max(1, viewport.visibleHeight)
        let top = isAwaitingInitialEnd ? initialTargetTop(viewport).top : viewportTop
        let downward: Bool
        if abs(top - lastScheduledTop) > 4 {
            downward = top > lastScheduledTop
        } else {
            downward = isScrollingDown
        }
        lastScheduledTop = top
        let minY = top - (downward ? 0.5 : 2.0) * screen
        let maxY = top + screen + (downward ? 2.0 : 0.5) * screen
        let drawing = currentDrawing
        let nearLimit = Int(1.5 * screen)
        var urgentJobs: [LayoutQueue.Job] = []
        if let range = geometry.indices(overlapping: max(0, minY), maxY) {
            for index in range {
                let distance = viewportDistance(ofRowAt: index, top: top, screen: screen)
                if let job = job(for: index, priority: distance, drawing: distance <= nearLimit ? drawing : nil) {
                    urgentJobs.append(job)
                }
            }
        }
        urgentGeneration &+= 1
        let generation = urgentGeneration
        Task {
            await queue.submit(urgent: urgentJobs, generation: generation, replacingUrgent: true)
        }
        if urgentJobs.isEmpty { checkWarm() }
    }

    /// Queues one nearest-first `.utility` backfill pass over all remaining
    /// unparsed or stale rows (called once on `transcriptDidShow` and once
    /// after a settled width change, never per scroll/resize/stream frame).
    func scheduleBackfill() {
        guard configuration.laysOutRows, columnWidth > 0, !isAwaitingInitialEnd,
            let viewport = host?.viewport ?? lastViewport
        else { return }
        let screen = max(1, viewport.visibleHeight)
        let top = viewportTop
        var backfillJobs: [LayoutQueue.Job] = []
        for index in rows.indices {
            let row = rows[index]
            if case .pendingMessage = row.kind {
                let distance = viewportDistance(ofRowAt: index, top: top, screen: screen)
                if let job = job(for: index, priority: distance, drawing: nil) {
                    backfillJobs.append(job)
                }
            } else if layouts[row.id]?.key != currentKey(row) {
                let distance = viewportDistance(ofRowAt: index, top: top, screen: screen)
                if let job = job(for: index, priority: distance, drawing: nil) {
                    backfillJobs.append(job)
                }
            }
        }
        guard !backfillJobs.isEmpty else { return }
        Task { await queue.setBackfill(backfillJobs) }
    }

    private var currentDrawing: DrawnBands.Drawing? {
        guard let palette else { return nil }
        return DrawnBands.Drawing(
            palette: palette, scale: host?.scale ?? 2, colorSpace: host?.colorSpace ?? RowLayer.colorSpace)
    }

    private func job(for index: Int, priority: Int, drawing: DrawnBands.Drawing?) -> LayoutQueue.Job? {
        let row = rows[index]
        if case .pendingMessage(let message, let source) = row.kind {
            return LayoutQueue.Job(
                id: "parse|\(message.pendingRowID)",
                work: .parseAndLayout(
                    message: message, source: source, width: columnWidth, style: style, drawing: drawing),
                priority: priority)
        }
        guard layouts[row.id]?.key != currentKey(row) else { return nil }
        let coldDrawing = layouts[row.id] == nil ? drawing : nil
        return LayoutQueue.Job(
            id: "layout|\(row.id)", work: .layout(request(row), drawing: coldDrawing), priority: priority)
    }

    // MARK: Results

    /// Applies every result that arrived since the last drain as one change.
    func drainInbox() {
        updating { drainResults() }
    }

    private struct ParsedBatchItem {
        let message: TranscriptMessage
        let source: String
        /// Built by the worker that parsed the message, so the main thread
        /// does not build them again (233 ms of an iPhone 14 trace).
        let rows: [TranscriptRow]
        let layouts: [RowLayout]?
        let drawn: [DrawnBands?]
    }

    private func drainResults() {
        let maxParsedPerDrain = isAwaitingInitialEnd ? Int.max : 4
        let (results, hasMore) = layoutInbox.state.withLock { state -> ([LayoutQueue.Result], Bool) in
            if state.items.count <= maxParsedPerDrain {
                state.isDrainScheduled = false
                let all = state.items
                state.items.removeAll(keepingCapacity: true)
                return (all, false)
            }
            var parsedCount = 0
            var splitIndex = 0
            for item in state.items {
                if case .parsedAndLaidOut = item {
                    if parsedCount >= maxParsedPerDrain { break }
                    parsedCount += 1
                }
                splitIndex += 1
            }
            if splitIndex >= state.items.count {
                state.isDrainScheduled = false
                let all = state.items
                state.items.removeAll(keepingCapacity: true)
                return (all, false)
            }
            let batch = Array(state.items[..<splitIndex])
            state.items.removeFirst(splitIndex)
            return (batch, true)
        }
        if hasMore {
            Task { @MainActor [weak self] in self?.drainInbox() }
        }
        guard !results.isEmpty else { return }
        var newlyParsed: [ParsedBatchItem] = []
        var heights: [String: CGFloat] = [:]
        var heightDeltaSum: CGFloat = 0
        for result in results {
            switch result {
            case .parsedAndLaidOut(
                let message, let source, let blocks, let metrics, let blockRows, let blockLayouts, let blockDrawn):
                guard isCurrentParseSource(source, for: message), parsedMessages[message.id]?.source != source else {
                    continue
                }
                cacheParsedMessage(id: message.id, source: source, blocks: blocks, metrics: metrics)
                let matchingLayouts =
                    !blockLayouts.isEmpty
                    && blockLayouts.first.map { $0.key.width == columnWidth && $0.key.styleVersion == style.version }
                        == true
                newlyParsed.append(
                    ParsedBatchItem(
                        message: message, source: source, rows: blockRows,
                        layouts: matchingLayouts ? blockLayouts : nil,
                        drawn: matchingLayouts ? blockDrawn : []))
            case .layout(let layout, let drawn):
                guard let index = geometry.index(for: layout.rowID), layout.key == currentKey(rows[index]) else {
                    continue
                }
                heights[layout.rowID] = layout.height
                measuredRowHeights[layout.rowID] = layout.height
                heightDeltaSum += abs(layout.height - geometry.height(at: index))
                storeLayout(layout)
                if let drawn, host != nil {
                    preDrawnBands[layout.rowID] = (layout, drawn)
                }
            }
        }
        // Apply `.layout` heights before splicing `.parsedAndLaidOut` rows so
        // `replaceRows`'s `alignInitialEndIfPossible()` sees every measured
        // height in this batch rather than aligning on stale estimates.
        setHeights(heights)
        if !newlyParsed.isEmpty {
            applyParsedMessages(newlyParsed, shouldSchedule: isAwaitingInitialEnd)
        }
        if isAwaitingInitialEnd, newlyParsed.isEmpty, let viewport = host?.viewport ?? lastViewport,
            heightDeltaSum >= viewport.visibleHeight / 4
        {
            scheduleWork()
        }
        checkWarm()
    }

    /// Rejects stale out-of-order worker parses whose `source` no longer
    /// matches the pending row or current turn entry.
    private func isCurrentParseSource(_ source: String, for message: TranscriptMessage) -> Bool {
        if let index = geometry.index(for: message.pendingRowID), rows.indices.contains(index),
            case .pendingMessage(let pendingMessage, let pendingSource) = rows[index].kind
        {
            return pendingMessage == message && pendingSource == source
        }
        if let turn = turns.first(where: { $0.id == message.turnID }),
            let entry = turn.entries.first(where: { $0.ref == message.ref })
        {
            return entry.text == source
        }
        return false
    }

    /// Splices newly parsed `.pendingMessage` rows in contiguous runs (from
    /// highest index down) so non-adjacent backfill results never splice
    /// hundreds of untouched rows between them.
    private func applyParsedMessages(_ parsed: [ParsedBatchItem], shouldSchedule: Bool = false) {
        var byIndex: [Int: (rows: [TranscriptRow], layouts: [RowLayout]?, drawn: [DrawnBands?])] = [:]
        for item in parsed {
            guard let index = geometry.index(for: item.message.pendingRowID),
                rows.indices.contains(index),
                case .pendingMessage(let currentMessage, let currentSource) = rows[index].kind,
                currentMessage == item.message, currentSource == item.source
            else {
                continue
            }
            byIndex[index] = (item.rows, item.layouts, item.drawn)
        }
        guard !byIndex.isEmpty else { return }
        let sortedIndices = byIndex.keys.sorted()
        var runs: [ClosedRange<Int>] = []
        var runStart = sortedIndices[0]
        var runEnd = sortedIndices[0]
        for idx in sortedIndices.dropFirst() {
            if idx == runEnd + 1 {
                runEnd = idx
            } else {
                runs.append(runStart...runEnd)
                runStart = idx
                runEnd = idx
            }
        }
        runs.append(runStart...runEnd)

        for run in runs.reversed() {
            var replacementRows: [TranscriptRow] = []
            var replacementHeights: [String: CGFloat] = [:]
            replacementRows.reserveCapacity(run.count * 4)
            for index in run {
                guard let replacement = byIndex[index] else { continue }
                for (offset, blockRow) in replacement.rows.enumerated() {
                    if let prebuilt = replacement.layouts, offset < prebuilt.count {
                        let layout = prebuilt[offset]
                        replacementHeights[blockRow.id] = layout.height
                        measuredRowHeights[blockRow.id] = layout.height
                        storeLayout(layout)
                        if offset < replacement.drawn.count, let drawn = replacement.drawn[offset], host != nil {
                            preDrawnBands[blockRow.id] = (layout, drawn)
                        }
                    }
                    replacementRows.append(blockRow)
                }
            }
            replaceRows(
                run.lowerBound..<(run.upperBound + 1), with: replacementRows, heights: replacementHeights,
                shouldSchedule: shouldSchedule)
        }
    }

    /// Rule 9's readiness: the rows on the initial screen (the end, or a
    /// restored saved place) are parsed and laid out at the current key. Waits
    /// at most a second; after that it reveals and lets workers fill in
    /// asynchronously rather than stay hidden indefinitely.
    func isEndScreenReady(_ viewport: TranscriptViewport) -> Bool {
        guard configuration.laysOutRows else { return true }
        guard columnWidth > 0 else { return false }
        if openStarted.duration(to: .now) > .seconds(1) { return true }
        if let saved = pendingRestorePlace, geometry.index(for: saved.anchorID) == nil,
            let stream = streams[saved.source], stream.shownLength < stream.currentText.utf8.count
        {
            return false
        }
        let target = initialTargetTop(viewport).top
        let top = max(0, target - viewport.topInset)
        guard let range = geometry.indices(overlapping: top, target + viewport.visibleHeight) else {
            return true
        }
        for index in range {
            let row = rows[index]
            if case .pendingMessage = row.kind { return false }
            if layouts[row.id]?.key != currentKey(row) { return false }
        }
        return true
    }

    func transcriptDidShow() {
        #if DEBUG
            ChatBenchmarkAutoRun.isNativeGeometryWarm = true
            ChatBenchmarkAutoRun.isInitialAlignmentComplete = true
            let elapsed = openStarted.duration(to: .now)
            ChatBenchmarkAutoRun.trace("transcript shown ms=\(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)")
        #endif
        // Start background exact-geometry backfill for the rest of the
        // transcript now that the initial screen is visible.
        scheduleBackfill()
        checkWarm()
    }

    /// Warm once the visible screen is parsed and laid out at the current key.
    func checkWarm() {
        #if DEBUG
            guard configuration.laysOutRows, !rows.isEmpty, !isAwaitingInitialEnd,
                let viewport = host?.viewport ?? lastViewport
            else { return }
            let top = max(0, viewportTop - viewport.topInset)
            if let range = geometry.indices(overlapping: top, viewportTop + viewport.visibleHeight) {
                for index in range {
                    let row = rows[index]
                    if case .pendingMessage = row.kind { return }
                    if layouts[row.id]?.key != currentKey(row) { return }
                }
            }
            if !ChatBenchmarkAutoRun.isTranscriptWarm {
                ChatBenchmarkAutoRun.noteTranscriptWarm()
            }
        #endif
    }
}
