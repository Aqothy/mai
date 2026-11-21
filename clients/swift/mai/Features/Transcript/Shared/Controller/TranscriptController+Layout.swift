import CoreGraphics
import Foundation
import Synchronization

/// Layout near the viewport, ahead of the scroll (PLAN 4.2): the viewport,
/// then two screens in the scroll direction and one behind, then the rest of
/// the history at low priority so heights settle. Results land in batches
/// and change geometry through `changeGeometry`, so the reader's place
/// holds. A row about to show without a layout is laid out on the main
/// thread in that frame (PLAN D3).
extension TranscriptController {
    /// The key a row's layout must have to be current.
    func currentKey(_ row: TranscriptRow) -> RowLayoutKey {
        RowLayoutKey(contentVersion: row.contentVersion, width: columnWidth, styleVersion: style.version)
    }

    /// Builds a layout request for `row`, passing the previous layout when the
    /// text size still matches so code blocks (plain or highlighted) and tables
    /// reuse their laid-out text across resizes.
    func request(_ row: TranscriptRow) -> RowLayoutRequest {
        let key = currentKey(row)
        var request = RowLayoutRequest(rowID: row.id, kind: row.kind, key: key, style: style)
        if let current = layouts[row.id], current.key.contentVersion == key.contentVersion,
            current.key.styleVersion == key.styleVersion
        {
            request.previous = (row.kind, current)
        }
        if case .markdownBlock(.code(_, let code), _) = row.kind, let palette,
            let colors = codeColors(forRowID: row.id, code: code, isDark: palette.isDark)
        {
            request.codeColors = colors
        }
        return request
    }

    /// The colors a code row's layout has, if made for `code` in this theme.
    func codeColors(forRowID id: String, code: String, isDark: Bool) -> CodeColors? {
        guard let colors = layouts[id]?.content.codeLayout?.colors, colors.matches(code: code, isDark: isDark)
        else { return nil }
        return colors
    }

    /// Highlights for the code rows among `rowIDs` whose colors are not
    /// for their current code and theme.
    func submitHighlights(forRowIDs rowIDs: some Sequence<String>) {
        let jobs = rowIDs.compactMap { id in
            geometry.index(for: id).flatMap { index in
                highlightJob(
                    for: index, priority: Int(abs(geometry.offset(at: index) - viewportTop)), within: nil)
            }
        }
        guard !jobs.isEmpty else { return }
        let generation = urgentGeneration
        Task { await queue.submit(urgent: jobs, generation: generation, replacingUrgent: false) }
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
        measuredKeys[row.id] = layout.key
        if geometry.height(at: index) != layout.height { synchronousHeights[row.id] = layout.height }
        return layout
    }

    /// Gives every row overlapping `minY..<maxY` (the visible rows) a
    /// layout, laying out now those still without one (PLAN D3), and applies
    /// the heights that measured as one anchored change.
    func layOutVisibleRows(minY: CGFloat, maxY: CGFloat) {
        guard let range = geometry.indices(overlapping: max(0, minY), maxY) else { return }
        for index in range { _ = layout(forRowAt: index, synchronously: true) }
        commitSynchronousHeights()
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
        // Other colors resolve when drawn; syntax colors are per theme, so
        // code shows the old theme's until highlighted again.
        scheduleWork()
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
        if !isAwaitingInitialEnd { scheduleBackgroundSweep(after: .milliseconds(50)) }
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
        columnWidth = width
        guard configuration.laysOutRows else { return }
        scheduleWork()
        if !isAwaitingInitialEnd { scheduleBackgroundSweep(after: .milliseconds(300)) }
    }

    func rowsDidChange() {
        guard configuration.laysOutRows else { return }
        scheduleWork()
        // Two-stage startup (Texture): keep CPU and main-actor drains focused
        // on the end screen until it shows; `transcriptDidShow()` starts the
        // full-history background sweep once visible.
        if !isAwaitingInitialEnd { scheduleBackgroundSweep(after: .milliseconds(50)) }
    }

    /// Lays out the window around the viewport, nearest first.
    func scheduleWork() {
        guard configuration.laysOutRows, columnWidth > 0, let viewport = host?.viewport ?? lastViewport else { return }
        let screen = max(1, viewport.visibleHeight)
        let top = isAwaitingInitialEnd ? endTop(viewport) : viewportTop
        let downward = top >= lastScheduledTop
        lastScheduledTop = top
        let minY = top - (downward ? 1 : 2) * screen
        let maxY = top + screen + (downward ? 2 : 1) * screen
        var jobs: [LayoutQueue.Job] = []
        if let range = geometry.indices(overlapping: max(0, minY), maxY) {
            for index in range {
                let distance = Int(abs(geometry.offset(at: index) - top))
                if let job = job(for: index, priority: distance) { jobs.append(job) }
                if let job = highlightJob(for: index, priority: distance, within: top - screen...(top + 2 * screen)) {
                    jobs.append(job)
                }
            }
        }
        dropLayouts(outside: (top - 2 * screen)...(top + 3 * screen))
        urgentGeneration &+= 1
        let generation = urgentGeneration
        Task { await queue.submit(urgent: jobs, generation: generation, replacingUrgent: true) }
    }

    private func job(for index: Int, priority: Int) -> LayoutQueue.Job? {
        let row = rows[index]
        if case .pendingMessage(let source) = row.kind, let messageID = row.messageID {
            return LayoutQueue.Job(
                id: "parse|\(messageID)", work: .parse(messageID: messageID, source: source), priority: priority)
        }
        guard layouts[row.id]?.key != currentKey(row) else { return nil }
        return LayoutQueue.Job(id: "layout|\(row.id)", work: .layout(request(row)), priority: priority)
    }

    private func highlightJob(
        for index: Int, priority: Int, within window: ClosedRange<CGFloat>?
    ) -> LayoutQueue.Job? {
        let row = rows[index]
        guard case .markdownBlock(.code(let language, let code), _) = row.kind else { return nil }
        if let window {
            let frame = geometry.frame(at: index)
            guard frame.minY < window.upperBound, frame.minY + frame.height > window.lowerBound else { return nil }
        }
        guard let palette, let layout = layouts[row.id], layout.key == currentKey(row),
            let codeLayout = layout.content.codeLayout,
            !(codeLayout.isHighlighted && codeLayout.colorsAreDark == palette.isDark),
            !isOpenStreamTail(at: index)
        else { return nil }
        return LayoutQueue.Job(
            id: "highlight|\(row.id)",
            work: .highlight(request(row), code: code, language: language, isDark: palette.isDark),
            priority: priority)
    }

    /// A code block a stream is still writing: highlighted once it closes
    /// (the stream moves past it or ends), not again on every update.
    private func isOpenStreamTail(at index: Int) -> Bool {
        let row = rows[index]
        guard isStreaming(row) else { return false }
        return index + 1 == rows.count || rows[index + 1].messageID != row.messageID
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

    /// Measures everything not measured at the current width and style,
    /// newest first, after `delay` (a resize settles first). Off-screen rows
    /// use the measure-only path so background settling never builds throwaway
    /// glyph/caret arrays.
    func scheduleBackgroundSweep(after delay: Duration) {
        backgroundSweepTask?.cancel()
        backgroundSweepTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.columnWidth > 0 else { return }
            let keep = self.keptWindow()
            let width = self.columnWidth
            let style = self.style
            var jobs: [LayoutQueue.Job] = []
            for index in self.rows.indices.reversed() {
                let row = self.rows[index]
                let priority = LayoutQueue.backgroundPriority + (self.rows.count - index)
                if case .pendingMessage(let source) = row.kind, let messageID = row.messageID {
                    jobs.append(
                        .init(
                            id: "parse|\(messageID)",
                            work: .parseAndMeasure(messageID: messageID, source: source, width: width, style: style),
                            priority: priority))
                } else if self.measuredKeys[row.id] != self.currentKey(row) {
                    let nearViewport = keep.map {
                        let frame = self.geometry.frame(at: index)
                        return frame.minY < $0.upperBound && frame.minY + frame.height > $0.lowerBound
                    } ?? false
                    let work: LayoutQueue.Work = nearViewport ? .layout(self.request(row)) : .measure(self.request(row))
                    jobs.append(.init(id: "layout|\(row.id)", work: work, priority: priority))
                }
            }
            #if DEBUG
                if !jobs.isEmpty, self.isWarm == false { ChatBenchmarkAutoRun.noteTranscriptWarmStarted() }
            #endif
            await self.queue.submit(background: jobs)
            self.checkWarm()
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
        let measuredHeights: [CGFloat]?
    }

    private func drainResults() {
        let results = layoutInbox.state.withLock { state -> [LayoutQueue.Result] in
            state.hasUrgentScheduled = false
            state.hasBackgroundScheduled = false
            defer { state.items.removeAll(keepingCapacity: true) }
            return state.items
        }
        guard !results.isEmpty else { return }
        var newlyParsed: [ParsedBatchItem] = []
        var landedCode: [String] = []
        var heights: [String: CGFloat] = [:]
        let keep = keptWindow()
        for result in results {
            switch result {
            case .parsed(let messageID, let source, let blocks):
                guard parsedMessages[messageID]?.source != source else { continue }
                parsedMessages[messageID] = (source, blocks)
                newlyParsed.append(ParsedBatchItem(messageID: messageID, source: source, blocks: blocks, measuredHeights: nil))
            case .parsedAndMeasured(let messageID, let source, let blocks, let width, let styleVersion, let blockHeights):
                guard parsedMessages[messageID]?.source != source else { continue }
                parsedMessages[messageID] = (source, blocks)
                let matchingHeights = (width == columnWidth && styleVersion == style.version) ? blockHeights : nil
                newlyParsed.append(
                    ParsedBatchItem(messageID: messageID, source: source, blocks: blocks, measuredHeights: matchingHeights))
            case .measured(let rowID, let key, let height):
                guard let index = geometry.index(for: rowID), key == currentKey(rows[index]) else { continue }
                measuredKeys[rowID] = key
                heights[rowID] = height
            case .layout(let layout):
                guard let index = geometry.index(for: layout.rowID), layout.key == currentKey(rows[index]) else {
                    continue
                }
                measuredKeys[layout.rowID] = layout.key
                heights[layout.rowID] = layout.height
                // A plain layout finishing after the colored one for the same
                // key would take the colors away again.
                if let current = layouts[layout.rowID], current.key == layout.key, current.content.isHighlighted,
                    !layout.content.isHighlighted, current.content.colorsAreDark == palette?.isDark
                {
                    continue
                }
                let frame = geometry.frame(at: index)
                if keep.map({ frame.minY < $0.upperBound && frame.minY + frame.height > $0.lowerBound }) ?? true {
                    layouts[layout.rowID] = layout
                    if layout.content.codeLayout != nil { landedCode.append(layout.rowID) }
                }
            }
        }
        var parsedNearViewport = false
        if !newlyParsed.isEmpty {
            parsedNearViewport = applyParsedMessages(newlyParsed, keptWindow: keep)
        }
        setHeights(heights)
        host?.setNeedsRowPlacement()
        if parsedNearViewport { scheduleWork() }
        submitHighlights(forRowIDs: landedCode)
        alignInitialEndIfPossible()
        checkWarm()
    }

    /// Splices all newly parsed `.pendingMessage` rows in one batch into a
    /// single `changeGeometry` / `geometry.replaceRows` call (avoiding O(N^2)
    /// per-message dictionary rebuilds and AppKit frame updates during settle).
    private func applyParsedMessages(_ parsed: [ParsedBatchItem], keptWindow keep: ClosedRange<CGFloat>?) -> Bool {
        var byIndex: [Int: (rows: [TranscriptRow], heights: [CGFloat]?)] = [:]
        var anyNearViewport = false
        var needsFullRebuild = false
        var hasUnmeasuredOffscreen = false
        for item in parsed {
            guard let index = geometry.index(for: "\(item.messageID)#pending"),
                rows.indices.contains(index),
                case .pendingMessage(let currentSource) = rows[index].kind,
                currentSource == item.source
            else {
                if geometry.index(for: "\(item.messageID)#0") == nil { needsFullRebuild = true }
                continue
            }
            let frame = geometry.frame(at: index)
            let near =
                isAwaitingInitialEnd
                || (keep.map { frame.minY < $0.upperBound && frame.minY + frame.height > $0.lowerBound } ?? true)
            if near { anyNearViewport = true }
            if !near, item.measuredHeights == nil { hasUnmeasuredOffscreen = true }
            let blockRows = item.blocks.enumerated().map { offset, block in
                TranscriptRow(
                    id: "\(item.messageID)#\(offset)", sourceID: item.messageID,
                    kind: .markdownBlock(block, .of(offset, in: item.blocks)),
                    messageID: item.messageID, role: .assistant)
            }
            byIndex[index] = (blockRows, item.measuredHeights)
        }
        if needsFullRebuild {
            rebuildRows()
            return true
        }
        guard let firstIndex = byIndex.keys.min() else { return false }
        let width = columnWidth > 0 ? columnWidth : 600
        let currentStyleVersion = style.version
        var tailRows: [TranscriptRow] = []
        var tailIDs: [String] = []
        var tailSources: [String] = []
        var tailHeights: [CGFloat] = []
        tailRows.reserveCapacity(rows.count - firstIndex + byIndex.count * 4)
        tailIDs.reserveCapacity(rows.count - firstIndex + byIndex.count * 4)
        tailSources.reserveCapacity(rows.count - firstIndex + byIndex.count * 4)
        tailHeights.reserveCapacity(rows.count - firstIndex + byIndex.count * 4)

        for index in firstIndex..<rows.count {
            if let replacement = byIndex[index] {
                for (offset, blockRow) in replacement.rows.enumerated() {
                    let h: CGFloat
                    if let premeasured = replacement.heights, offset < premeasured.count {
                        h = premeasured[offset]
                        measuredKeys[blockRow.id] = RowLayoutKey(
                            contentVersion: blockRow.contentVersion, width: columnWidth,
                            styleVersion: currentStyleVersion)
                    } else {
                        h = HeightEstimator.estimate(blockRow.kind, width: width, style: style)
                    }
                    tailRows.append(blockRow)
                    tailIDs.append(blockRow.id)
                    tailSources.append(blockRow.sourceID)
                    tailHeights.append(h)
                }
            } else {
                let existing = rows[index]
                tailRows.append(existing)
                tailIDs.append(existing.id)
                tailSources.append(existing.sourceID)
                tailHeights.append(geometry.height(at: index))
            }
        }
        spliceTail(from: firstIndex, rows: tailRows, ids: tailIDs, sources: tailSources, heights: tailHeights)
        if hasUnmeasuredOffscreen, !isAwaitingInitialEnd {
            scheduleBackgroundSweep(after: .milliseconds(50))
        }
        return anyNearViewport
    }

    private func keptWindow() -> ClosedRange<CGFloat>? {
        guard let viewport = host?.viewport ?? lastViewport else { return nil }
        let screen = max(1, viewport.visibleHeight)
        let top = isAwaitingInitialEnd ? endTop(viewport) : viewportTop
        return (top - 2 * screen)...(top + 3 * screen)
    }

    /// Rule 9's readiness: the rows on the end screen are parsed and laid out
    /// at the current key. Waits at most a second; after that the host lays
    /// the screen out itself rather than stay blank.
    func isEndScreenReady(_ viewport: TranscriptViewport) -> Bool {
        guard configuration.laysOutRows else { return true }
        guard columnWidth > 0 else { return false }
        if openStarted.duration(to: .now) > .seconds(1) { return true }
        let top = max(0, endTop(viewport) - viewport.topInset)
        guard let range = geometry.indices(overlapping: top, endTop(viewport) + viewport.visibleHeight) else {
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
        if configuration.laysOutRows {
            scheduleBackgroundSweep(after: .milliseconds(50))
        }
    }

    /// Warm once every message is parsed and every row measured at the
    /// current key: the steady state the scroll benchmarks measure.
    func checkWarm() {
        guard configuration.laysOutRows, !isWarm, !rows.isEmpty, !isAwaitingInitialEnd else { return }
        for row in rows {
            if case .pendingMessage = row.kind { return }
            if measuredKeys[row.id] != currentKey(row) { return }
        }
        isWarm = true
        #if DEBUG
            ChatBenchmarkAutoRun.noteTranscriptWarm()
        #endif
    }
}
