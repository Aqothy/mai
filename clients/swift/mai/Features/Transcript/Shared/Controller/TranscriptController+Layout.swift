import CoreGraphics
import Foundation
import Synchronization

/// Layout near the viewport, ahead of the scroll (PLAN 4.2): the viewport,
/// plus two screens in the scroll direction and one behind, laid out on demand.
/// Results land in batches and change geometry through `changeGeometry`, so
/// the reader's place holds. A row about to show without a layout is laid out
/// on the main thread in that frame (PLAN D3).
extension TranscriptController {
    /// The key a row's layout must have to be current.
    func currentKey(_ row: TranscriptRow) -> RowLayoutKey {
        RowLayoutKey(contentVersion: row.contentVersion, width: columnWidth, styleVersion: style.version)
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

    /// The layout to show for row `index`: the current one, an older one
    /// while its replacement is on its way, or, for a row about to be
    /// visible with neither, one made now.
    func layout(forRowAt index: Int, synchronously: Bool) -> RowLayout? {
        let row = rows[index]
        if let layout = layouts[row.id] { return layout }
        guard synchronously, configuration.laysOutRows, columnWidth > 0 else { return nil }
        let request = request(row)
        let layout = RowLayoutBuilder.layout(request)
        #if DEBUG
            TranscriptDebugCounters.syncLayouts += 1
        #endif
        layouts[row.id] = layout
        if geometry.height(at: index) != layout.height { synchronousHeights[row.id] = layout.height }
        return layout
    }

    /// Gives every row overlapping `minY..<maxY` (the visible rows) a
    /// layout, laying out now those still without one (PLAN D3), and applies
    /// the heights that measured as one anchored change. Any visible
    /// `.pendingMessage` that had no cached layout is also queued to parse so
    /// it cannot stay stuck as raw markdown if it entered without scrolling.
    func layOutVisibleRows(minY: CGFloat, maxY: CGFloat) {
        guard let range = geometry.indices(overlapping: max(0, minY), maxY) else { return }
        var pending: [Int] = []
        for index in range {
            let row = rows[index]
            if case .pendingMessage = row.kind, layouts[row.id] == nil {
                pending.append(index)
            }
            _ = layout(forRowAt: index, synchronously: true)
        }
        commitSynchronousHeights()
        if !pending.isEmpty { prefetch(pending) }
    }

    /// Applies heights measured by synchronous layouts, after the host's
    /// mounting pass, as one anchored change.
    func commitSynchronousHeights() {
        guard !synchronousHeights.isEmpty else { return }
        let heights = synchronousHeights
        synchronousHeights.removeAll()
        setHeights(heights)
    }

    /// The host is about to draw rows `indices`, which have no layout at
    /// all: lay them out first. Rows with an older layout show it meanwhile
    /// and are queued already (a new width or style schedules them), so a
    /// resize does not queue them again every frame.
    func prefetch(_ indices: [Int]) {
        guard configuration.laysOutRows, columnWidth > 0 else { return }
        let top = viewportTop
        let jobs = indices.compactMap { index in
            job(for: index, priority: Int(abs(geometry.offset(at: index) - top)))
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
        guard width != columnWidth else {
            checkWarm()
            return
        }
        columnWidth = width
        scheduleWork()
    }

    /// Lays out the window around the viewport, nearest first.
    func scheduleWork() {
        guard configuration.laysOutRows, columnWidth > 0, let viewport = host?.viewport ?? lastViewport else { return }
        let screen = max(1, viewport.visibleHeight)
        let top = isAwaitingInitialEnd ? initialTargetTop(viewport).top : viewportTop
        let downward = top >= lastScheduledTop
        lastScheduledTop = top
        let minY = top - (downward ? 1 : 2) * screen
        let maxY = top + screen + (downward ? 2 : 1) * screen
        var jobs: [LayoutQueue.Job] = []
        let overlapping = geometry.indices(overlapping: max(0, minY), maxY)
        if isAwaitingInitialEnd, let saved = pendingRestorePlace, geometry.index(for: saved.anchorID) == nil,
            let pendingIndex = geometry.index(for: "\(saved.source)#pending"),
            !(overlapping?.contains(pendingIndex) ?? false),
            let pendingJob = job(for: pendingIndex, priority: 0)
        {
            jobs.append(pendingJob)
        }
        if let range = overlapping {
            for index in range {
                let distance = Int(abs(geometry.offset(at: index) - top))
                if let job = job(for: index, priority: distance) { jobs.append(job) }
            }
        }
        dropLayouts(outside: (top - 2 * screen)...(top + 3 * screen))
        urgentGeneration &+= 1
        let generation = urgentGeneration
        Task { await queue.submit(urgent: jobs, generation: generation, replacingUrgent: true) }
        if jobs.isEmpty { checkWarm() }
    }

    private func job(for index: Int, priority: Int) -> LayoutQueue.Job? {
        let row = rows[index]
        if case .pendingMessage(let source) = row.kind, let messageID = row.messageID {
            return LayoutQueue.Job(
                id: "parse|\(messageID)",
                work: .parseAndLayout(messageID: messageID, source: source, width: columnWidth, style: style),
                priority: priority)
        }
        guard layouts[row.id]?.key != currentKey(row) else { return nil }
        return LayoutQueue.Job(id: "layout|\(row.id)", work: .layout(request(row)), priority: priority)
    }

    /// Layouts are state only near the viewport; the rest are dropped so memory
    /// stays bounded (Q6).
    private func dropLayouts(outside window: ClosedRange<CGFloat>) {
        guard layouts.count > 64 else { return }
        for id in Array(layouts.keys) {
            guard let index = geometry.index(for: id) else {
                layouts[id] = nil
                continue
            }
            let frame = geometry.frame(at: index)
            if frame.minY + frame.height < window.lowerBound || frame.minY > window.upperBound { layouts[id] = nil }
        }
    }

    // MARK: Results

    /// Applies every result that arrived since the last drain as one change.
    func drainInbox() {
        updating { drainResults() }
    }

    private struct ParsedBatchItem {
        let messageID: String
        let source: String
        let blocks: [MarkdownBlock]
        let layouts: [RowLayout]?
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
            case .parsedAndLaidOut(let messageID, let source, let blocks, let blockLayouts):
                guard parsedMessages[messageID]?.source != source else { continue }
                parsedMessages[messageID] = (source, blocks)
                let matchingLayouts =
                    blockLayouts.first.map { $0.key.width == columnWidth && $0.key.styleVersion == style.version }
                    ?? true
                newlyParsed.append(
                    ParsedBatchItem(
                        messageID: messageID, source: source, blocks: blocks,
                        layouts: matchingLayouts ? blockLayouts : nil))
            case .layout(let layout):
                guard let index = geometry.index(for: layout.rowID), layout.key == currentKey(rows[index]) else {
                    continue
                }
                heights[layout.rowID] = layout.height
                heightDeltaSum += abs(layout.height - geometry.height(at: index))
                let frame = geometry.frame(at: index)
                if keep.map({ frame.minY < $0.upperBound && frame.minY + frame.height > $0.lowerBound }) ?? true {
                    layouts[layout.rowID] = layout
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
        // If large height shrinkage pulled unscheduled rows onto the initial
        // screen, schedule them immediately instead of waiting for the 1s
        // timeout (gated on delta so normal open drains don't re-queue in-flight jobs).
        if isAwaitingInitialEnd, newlyParsed.isEmpty, let viewport = host?.viewport ?? lastViewport,
            heightDeltaSum >= viewport.visibleHeight / 4
        {
            scheduleWork()
        }
        checkWarm()
    }

    /// Splices newly parsed `.pendingMessage` rows in one batch with their
    /// ready layouts and exact heights, avoiding a second layout round-trip and
    /// double `setFrameSize` bounce.
    private func applyParsedMessages(_ parsed: [ParsedBatchItem]) {
        var byIndex: [Int: (rows: [TranscriptRow], layouts: [RowLayout]?)] = [:]
        var needsFullRebuild = false
        for item in parsed {
            guard let index = geometry.index(for: "\(item.messageID)#pending"),
                rows.indices.contains(index),
                case .pendingMessage(let currentSource) = rows[index].kind,
                currentSource == item.source
            else {
                if geometry.index(for: "\(item.messageID)#0") == nil { needsFullRebuild = true }
                continue
            }
            let blockRows = item.blocks.enumerated().map { offset, block in
                TranscriptRow(
                    id: "\(item.messageID)#\(offset)", sourceID: item.messageID,
                    kind: .markdownBlock(block, .of(offset, in: item.blocks)),
                    messageID: item.messageID, role: .assistant)
            }
            byIndex[index] = (blockRows, item.layouts)
        }
        if needsFullRebuild {
            rebuildRows()
            return
        }
        guard let firstIndex = byIndex.keys.min(), let lastIndex = byIndex.keys.max() else { return }
        let width = columnWidth > 0 ? columnWidth : 600
        var replacementRows: [TranscriptRow] = []
        var replacementHeights: [String: CGFloat] = [:]
        replacementRows.reserveCapacity((lastIndex - firstIndex + 1) + byIndex.count * 4)
        // Populate ready layouts before `replaceRows` so its `scheduleWork()`
        // and `alignInitialEndIfPossible()` see them immediately (zero redundant
        // layout jobs, and `dropLayouts` trims any out-of-window blocks).
        for index in firstIndex...lastIndex {
            if let replacement = byIndex[index] {
                for (offset, blockRow) in replacement.rows.enumerated() {
                    if let prebuilt = replacement.layouts, offset < prebuilt.count {
                        let layout = prebuilt[offset]
                        replacementHeights[blockRow.id] = layout.height
                        layouts[layout.rowID] = layout
                    } else {
                        replacementHeights[blockRow.id] = HeightEstimator.estimate(blockRow.kind, width: width, style: style)
                    }
                    replacementRows.append(blockRow)
                }
            } else {
                replacementRows.append(rows[index])
            }
        }
        replaceRows(firstIndex..<(lastIndex + 1), with: replacementRows, heights: replacementHeights, marksArrived: false)
    }

    private func keptWindow() -> ClosedRange<CGFloat>? {
        guard let viewport = host?.viewport ?? lastViewport else { return nil }
        let screen = max(1, viewport.visibleHeight)
        let top = isAwaitingInitialEnd ? initialTargetTop(viewport).top : viewportTop
        return (top - 2 * screen)...(top + 3 * screen)
    }

    /// Rule 9's readiness: the rows on the initial screen (the end, or a
    /// restored saved place) are parsed and laid out at the current key. Waits
    /// at most a second; after that the host lays the screen out itself rather
    /// than stay blank.
    func isEndScreenReady(_ viewport: TranscriptViewport) -> Bool {
        guard configuration.laysOutRows else { return true }
        guard columnWidth > 0 else { return false }
        if openStarted.duration(to: .now) > .seconds(1) { return true }
        if let saved = pendingRestorePlace, geometry.index(for: saved.anchorID) == nil {
            if geometry.index(for: "\(saved.source)#pending") != nil { return false }
            if let stream = streams[saved.source], stream.shownLength < stream.currentText.utf8.count {
                return false
            }
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
