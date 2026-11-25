import CoreGraphics
import Foundation
import QuartzCore
import Synchronization

/// Layout near the viewport, ahead of the scroll (PLAN 4.2): the viewport,
/// plus screens biased in the scroll direction, laid out and pre-rastered off
/// the main thread (1-hop raster), with a strict per-frame sync budget for
/// normal-sized visible blank rows on rapid scrollbar scrubbing. Results land
/// in batches and change geometry through `changeGeometry`, so the reader's
/// place holds.
extension TranscriptController {
    private static let maxCachedLayoutRows = 64
    /// What 4,000 lines of prose hold (`RowContentLayout.retainedBytes`).
    private static let maxCachedLayoutBytes = 12 << 20
    private static let maxParsedMessageBytes = 16 * 1024 * 1024
    /// Maximum UTF-8 bytes (or selectable UTF-16 units) of a visible blank row
    /// eligible for bounded-budget synchronous layout fallback (matches
    /// `TranscriptBlockFlattener.maxSliceBytes` plus a 256-byte marker margin
    /// so every flattened slice qualifies while giant blocks stay off-main).
    static let syncFallbackByteLimit = 4_352
    /// Maximum UTF-8 bytes of a visible `.pendingMessage` eligible for
    /// synchronous parse-only splicing (< 2 ms via SIMD C scanner); step 2 then
    /// lays out strictly the 1–3 slices intersecting the viewport.
    static let syncFallbackParseByteLimit = 131_072
    /// Maximum cells in a Markdown table eligible for synchronous fallback.
    private static let syncFallbackTableCellLimit = 64

    /// The key a row's layout must have to be current.
    func currentKey(_ row: TranscriptRow) -> RowLayoutKey {
        RowLayoutKey(contentVersion: row.contentVersion, width: columnWidth, styleVersion: style.version)
    }

    func storeLayout(_ layout: RowLayout) {
        if let previous = layouts.updateValue(layout, forKey: layout.rowID) {
            cachedLayoutBytes -= previous.content.retainedBytes
        }
        cachedLayoutBytes += layout.content.retainedBytes
    }

    func removeLayout(for rowID: String) {
        if let removed = layouts.removeValue(forKey: rowID) {
            cachedLayoutBytes -= removed.content.retainedBytes
        }
    }

    func cacheParsedMessage(id: String, source: String, blocks: [MarkdownBlock], metrics: [TextMetrics] = []) {
        if let existing = parsedMessages[id] {
            parsedMessageBytes -= existing.source.utf8.count
        } else {
            parsedMessageOrder.append(id)
        }
        parsedMessages[id] = (source, blocks, metrics)
        parsedMessageBytes += source.utf8.count
        evictParsedMessagesIfNeeded()
    }

    private func evictParsedMessagesIfNeeded() {
        guard parsedMessageBytes > Self.maxParsedMessageBytes, parsedMessages.count > 16 else { return }
        var protectedSources: Set<String> = []
        if let keep = keptWindow(), let range = geometry.indices(overlapping: keep.lowerBound, keep.upperBound) {
            for index in range { protectedSources.insert(rows[index].sourceID) }
        }
        var retained: [String] = []
        retained.reserveCapacity(parsedMessageOrder.count)
        for id in parsedMessageOrder {
            guard parsedMessageBytes > Self.maxParsedMessageBytes, parsedMessages.count > 16 else {
                retained.append(id)
                continue
            }
            if protectedSources.contains(id) {
                retained.append(id)
                continue
            }
            if let removed = parsedMessages.removeValue(forKey: id) {
                parsedMessageBytes -= removed.source.utf8.count
            }
        }
        parsedMessageOrder = retained
    }

    /// Builds a layout request for `row`, passing the previous layout when the
    /// text size still matches so code blocks and tables reuse their laid-out
    /// text across resizes.
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

    /// The cached layout for row `index`, or `nil` while its worker job is in
    /// flight (pure async + blanking: layout never runs on MainActor).
    func layout(forRowAt index: Int) -> RowLayout? {
        layouts[rows[index].id]
    }

    /// Synchronously parses visible `.pendingMessage` turns (`<= 128 KB`,
    /// parse-only) and lays out only the visible `<= 4 KB` slices missing a
    /// cached layout, stopping immediately once `deadline` elapses. Runs before
    /// `mounter.place` so rapid scrollbar scrubbing never shows white flashes
    /// while giant blocks and huge tables stay strictly off-main.
    func prepareVisibleSynchronously(in visible: CGRect, deadline: CFTimeInterval) {
        guard configuration.laysOutRows, columnWidth > 0, !isAwaitingInitialEnd,
            let range = geometry.indices(overlapping: max(0, visible.minY), visible.maxY)
        else { return }
        // Fast path: 99% of frames already have every visible row laid out.
        var hasMissing = false
        for index in range {
            let row = rows[index]
            if case .pendingMessage = row.kind {
                hasMissing = true
                break
            }
            if layouts[row.id] == nil {
                hasMissing = true
                break
            }
        }
        guard hasMissing, CACurrentMediaTime() < deadline else { return }

        // 1. Parse visible `.pendingMessage` rows up to 128 KB so their
        // bounded <= 4 KB slices splice cleanly before mounting. Larger
        // messages skip eager whole-message layout here so step 2 lays out
        // strictly the 1–3 slices actually intersecting the viewport.
        var parsedBatch: [ParsedBatchItem] = []
        for index in range {
            guard CACurrentMediaTime() < deadline else { break }
            guard case .pendingMessage(let message, let source) = rows[index].kind,
                source.utf8.count <= Self.syncFallbackParseByteLimit
            else { continue }
            let blocks = MarkdownPlanner.blocks(from: source)
            let builtRows = message.rows(from: blocks)
            let metrics = builtRows.map(\.metrics)
            cacheParsedMessage(id: message.id, source: source, blocks: blocks, metrics: metrics)
            var blockLayouts: [RowLayout]?
            if source.utf8.count <= Self.syncFallbackByteLimit, builtRows.count <= 8 {
                let key = RowLayoutKey(contentVersion: 0, width: columnWidth, styleVersion: style.version)
                var laid: [RowLayout] = []
                laid.reserveCapacity(builtRows.count)
                for blockRow in builtRows {
                    if CACurrentMediaTime() >= deadline { break }
                    laid.append(
                        RowLayoutBuilder.layout(
                            RowLayoutRequest(rowID: blockRow.id, kind: blockRow.kind, key: key, style: style)))
                }
                if !laid.isEmpty { blockLayouts = laid }
            }
            parsedBatch.append(
                ParsedBatchItem(
                    message: message, source: source, blocks: blocks, metrics: metrics,
                    layouts: blockLayouts, drawn: []))
        }
        if !parsedBatch.isEmpty {
            applyParsedMessages(parsedBatch)
        }

        // 2. Lay out any remaining small visible rows missing a layout.
        // Convert `host.viewportTop` (uncovered top, includes `topInset`) back
        // to raw document rect coordinates matching `visible.minY`.
        guard CACurrentMediaTime() < deadline else { return }
        let currentMinY = host.map { $0.viewportTop - ($0.viewport?.topInset ?? 0) } ?? visible.minY
        guard let visibleRange = geometry.indices(overlapping: max(0, currentMinY), currentMinY + visible.height) else {
            return
        }
        var syncHeights: [String: CGFloat] = [:]
        for index in visibleRange {
            guard CACurrentMediaTime() < deadline else { break }
            let row = rows[index]
            if case .pendingMessage = row.kind { continue }
            if case .markdownBlock(.table(let table), _, _) = row.kind,
                (table.rows.count + 1) * table.columnCount > Self.syncFallbackTableCellLimit
            {
                continue
            }
            guard layouts[row.id] == nil,
                max(row.metrics.bytes, row.metrics.selectableUTF16 ?? 0) <= Self.syncFallbackByteLimit
            else { continue }
            let layout = RowLayoutBuilder.layout(request(row))
            storeLayout(layout)
            syncHeights[row.id] = layout.height
            measuredRowHeights[row.id] = layout.height
        }
        if !syncHeights.isEmpty {
            setHeights(syncHeights)
        }
    }

    /// The host is about to draw rows `indices`, which have no layout at
    /// all: lay them out first. Rows with an older layout show it meanwhile
    /// and are queued already (a new width or style schedules them), so a
    /// resize does not queue them again every frame.
    func prefetch(_ indices: [Int]) {
        guard configuration.laysOutRows, columnWidth > 0 else { return }
        let top = viewportTop
        let drawing = currentDrawing
        let nearLimit = Int(max(1, (host?.viewport ?? lastViewport)?.visibleHeight ?? 800))
        let jobs = indices.compactMap { index -> LayoutQueue.Job? in
            let distance = Int(abs(geometry.offset(at: index) - top))
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

    /// The text size changed (Dynamic Type): every layout is stale. Rows show
    /// their old layouts until new ones land, and heights correct with the
    /// reading place kept (rule 4).
    func updateStyle() {
        let style = TextStyle.current()
        guard style.version != self.style.version else { return }
        self.style = style
        measuredRowHeights.removeAll()
        guard configuration.laysOutRows else { return }
        scheduleWork()
        host?.setNeedsRowPlacement()
    }

    // MARK: Scheduling

    func viewportDidMove() {
        loadOlderTurnsIfNearTop()
        guard configuration.laysOutRows, let viewport = lastViewport else { return }
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
        }
        scheduleWork()
    }

    /// Lays out the window around the viewport, nearest first.
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
        let minY = top - (downward ? 1 : 2) * screen
        let maxY = top + screen + (downward ? 2 : 1) * screen
        let drawing = currentDrawing
        // In Low Power Mode keep speculative 1-hop pre-raster focused tightly
        // on the visible screen so throttled cores don't paint offscreen rows.
        let nearLimit = Int(ProcessInfo.processInfo.isLowPowerModeEnabled ? max(1, screen / 2) : screen)
        var jobs: [LayoutQueue.Job] = []
        if let range = geometry.indices(overlapping: max(0, minY), maxY) {
            for index in range {
                let distance = Int(abs(geometry.offset(at: index) - top))
                if let job = job(for: index, priority: distance, drawing: distance <= nearLimit ? drawing : nil) {
                    jobs.append(job)
                }
            }
        }
        dropLayouts(outside: (top - 2 * screen)...(top + 3 * screen))
        urgentGeneration &+= 1
        let generation = urgentGeneration
        Task { await queue.submit(urgent: jobs, generation: generation, replacingUrgent: true) }
        if jobs.isEmpty { checkWarm() }
    }

    private var currentDrawing: DrawnBands.Drawing? {
        guard configuration.drawsOffMain, let palette else { return nil }
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
        // Only pre-raster 1-hop bitmaps for cold rows with no layout yet; rows
        // already on screen (such as live-resize reflows) keep their old pixels
        // while reflowing and let `RasterQueue` cancel stale widths cleanly.
        let coldDrawing = layouts[row.id] == nil ? drawing : nil
        return LayoutQueue.Job(
            id: "layout|\(row.id)", work: .layout(request(row), drawing: coldDrawing), priority: priority)
    }

    /// Layouts are state only near the viewport; the rest are dropped by row
    /// count and total retained bytes so huge rows never pin memory
    /// off-screen.
    func dropLayouts(outside window: ClosedRange<CGFloat>) {
        guard layouts.count > Self.maxCachedLayoutRows || cachedLayoutBytes > Self.maxCachedLayoutBytes else {
            return
        }
        for id in Array(layouts.keys) {
            guard let index = geometry.index(for: id) else {
                removeLayout(for: id)
                continue
            }
            let frame = geometry.frame(at: index)
            if frame.minY + frame.height < window.lowerBound || frame.minY > window.upperBound {
                removeLayout(for: id)
            }
        }
    }

    // MARK: Results

    /// Applies every result that arrived since the last drain as one change.
    func drainInbox() {
        updating { drainResults() }
    }

    private struct ParsedBatchItem {
        let message: TranscriptMessage
        let source: String
        let blocks: [MarkdownBlock]
        let metrics: [TextMetrics]
        let layouts: [RowLayout]?
        let drawn: [DrawnBands?]
    }

    private func drainResults() {
        let results = layoutInbox.state.withLock { state -> [LayoutQueue.Result] in
            state.isDrainScheduled = false
            defer { state.items.removeAll(keepingCapacity: true) }
            return state.items
        }
        guard !results.isEmpty else { return }
        var newlyParsed: [ParsedBatchItem] = []
        var heights: [String: CGFloat] = [:]
        var heightDeltaSum: CGFloat = 0
        let keep = keptWindow()
        for result in results {
            switch result {
            case .parsedAndLaidOut(let message, let source, let blocks, let metrics, let blockLayouts, let blockDrawn):
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
                        message: message, source: source, blocks: blocks, metrics: metrics,
                        layouts: matchingLayouts ? blockLayouts : nil,
                        drawn: matchingLayouts ? blockDrawn : []))
            case .layout(let layout, let drawn):
                guard let index = geometry.index(for: layout.rowID), layout.key == currentKey(rows[index]) else {
                    continue
                }
                heights[layout.rowID] = layout.height
                measuredRowHeights[layout.rowID] = layout.height
                heightDeltaSum += abs(layout.height - geometry.height(at: index))
                let frame = geometry.frame(at: index)
                if keep.map({ frame.minY < $0.upperBound && frame.minY + frame.height > $0.lowerBound }) ?? true {
                    storeLayout(layout)
                    if let drawn { preDrawnBands[layout.rowID] = (layout, drawn) }
                }
            }
        }
        // Apply `.layout` heights before splicing `.parsedAndLaidOut` rows so
        // `replaceRows`'s `alignInitialEndIfPossible()` sees every measured
        // height in this batch rather than aligning on stale estimates.
        setHeights(heights)
        if !newlyParsed.isEmpty {
            applyParsedMessages(newlyParsed)
        }
        // Large height changes can pull unscheduled rows onto the initial
        // screen: schedule them now instead of waiting for the 1s timeout
        // (gated on the total change so normal open drains don't re-queue
        // in-flight jobs).
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

    /// Splices newly parsed `.pendingMessage` rows in one batch with their
    /// ready layouts and exact heights, avoiding a second layout round-trip and
    /// double `setFrameSize` bounce.
    private func applyParsedMessages(_ parsed: [ParsedBatchItem]) {
        var byIndex: [Int: (rows: [TranscriptRow], layouts: [RowLayout]?, drawn: [DrawnBands?])] = [:]
        var needsFullRebuild = false
        for item in parsed {
            guard let index = geometry.index(for: item.message.pendingRowID),
                rows.indices.contains(index),
                case .pendingMessage(let currentMessage, let currentSource) = rows[index].kind,
                currentMessage == item.message, currentSource == item.source
            else {
                if geometry.index(for: item.message.firstParsedRowID) == nil { needsFullRebuild = true }
                continue
            }
            byIndex[index] = (item.message.rows(from: item.blocks, metrics: item.metrics), item.layouts, item.drawn)
        }
        if needsFullRebuild {
            rebuildRows()
            return
        }
        guard let firstIndex = byIndex.keys.min(), let lastIndex = byIndex.keys.max() else { return }
        var replacementRows: [TranscriptRow] = []
        var replacementHeights: [String: CGFloat] = [:]
        replacementRows.reserveCapacity((lastIndex - firstIndex + 1) + byIndex.count * 4)
        // Populate ready layouts before `replaceRows` so its `scheduleWork()`
        // and `alignInitialEndIfPossible()` see them immediately (zero redundant
        // layout jobs, and `dropLayouts` trims any out-of-window blocks). Blocks
        // without one take `replaceRows`'s estimate.
        for index in firstIndex...lastIndex {
            if let replacement = byIndex[index] {
                for (offset, blockRow) in replacement.rows.enumerated() {
                    if let prebuilt = replacement.layouts, offset < prebuilt.count {
                        let layout = prebuilt[offset]
                        replacementHeights[blockRow.id] = layout.height
                        measuredRowHeights[blockRow.id] = layout.height
                        storeLayout(layout)
                        if offset < replacement.drawn.count, let drawn = replacement.drawn[offset] {
                            preDrawnBands[blockRow.id] = (layout, drawn)
                        }
                    }
                    replacementRows.append(blockRow)
                }
            } else {
                replacementRows.append(rows[index])
            }
        }
        replaceRows(firstIndex..<(lastIndex + 1), with: replacementRows, heights: replacementHeights)
    }

    private func keptWindow() -> ClosedRange<CGFloat>? {
        guard let viewport = host?.viewport ?? lastViewport else { return nil }
        let screen = max(1, viewport.visibleHeight)
        let top = isAwaitingInitialEnd ? initialTargetTop(viewport).top : viewportTop
        return (top - 2 * screen)...(top + 3 * screen)
    }

    /// Rule 9's readiness: the rows on the initial screen (the end, or a
    /// restored saved place) are parsed and laid out at the current key. Waits
    /// at most a second; after that it reveals and lets workers fill in
    /// asynchronously rather than stay hidden indefinitely.
    func isEndScreenReady(_ viewport: TranscriptViewport) -> Bool {
        guard configuration.laysOutRows else { return true }
        guard columnWidth > 0 else { return false }
        if openStarted.duration(to: .now) > .seconds(1) { return true }
        // The saved row may be one its stream has not produced yet: wait for
        // the stream to catch up rather than land on the end.
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
        checkWarm()
    }

    /// Warm once the visible screen is parsed and laid out at the current key
    /// (on-demand layout never sweeps off-screen history).
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
