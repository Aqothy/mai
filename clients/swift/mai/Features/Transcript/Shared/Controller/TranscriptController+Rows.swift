import CoreGraphics
import Foundation
import Observation

/// The rows from the store: observes the selected thread, rebuilds rows on
/// structural changes, and streams live messages once per frame.
extension TranscriptController {
    /// Shows `threadID`'s turns from `store`, following its changes.
    /// Safe to call again (a view appearing again): only the first call
    /// starts observing.
    func start(store: ThreadStore, threadID: String) {
        guard self.store == nil else { return }
        self.store = store
        self.threadID = threadID
        openStarted = .now
        if let saved = store.savedTranscriptPlace(for: threadID) {
            restoreSavedPlace(saved)
        }
        rememberedHeights = store.transcriptMeasuredHeights(for: threadID)
        observeStore()
        // Rule 9's readiness waits at most a second; check again then even
        // if nothing else arrives.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.05))
            self?.alignInitialEndIfPossible()
        }
    }

    /// Re-armed after every change: the store publishes structural changes
    /// (entries, turns), not each streamed chunk. Unchanged prefix turns keep
    /// their copied `TranscriptTurn`s and built rows so live tool updates stay
    /// O(changed tail) regardless of chat size.
    private func observeStore() {
        guard let store, let threadID else { return }
        let thread = withObservationTracking {
            store.selectedThread
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeStore() }
        }
        guard let thread, thread.id == threadID else { return }
        hasOlderTurns = thread.older != nil

        let planChanged = !Self.samePlan(plan, thread.plan)
        plan = thread.plan

        let canDiffPrefix =
            lastSnapshotID == thread.snapshotID
            && thread.turnRevisions.count == thread.turns.count
            && turnRevisions.count == turns.count
            && turns.count <= thread.turns.count

        if canDiffPrefix {
            var firstChanged = 0
            while firstChanged < turns.count,
                turns[firstChanged].id == thread.turns[firstChanged].id,
                turnRevisions[firstChanged] == thread.turnRevisions[firstChanged]
            {
                firstChanged += 1
            }
            if firstChanged == thread.turns.count && turns.count == thread.turns.count && !planChanged {
                loadOlderTurnsIfNearTop()
                return
            }
            if firstChanged < turns.count {
                turns.removeSubrange(firstChanged...)
            }
            for index in firstChanged..<thread.turns.count {
                turns.append(TranscriptTurn(thread.turns[index]))
            }
            turnRevisions = thread.turnRevisions
            updateWorkingPhrase()
            updateStreams()
            rebuildRows(fromTurnIndex: firstChanged)
        } else {
            // Copied out so the store's turns are not shared past this call.
            lastSnapshotID = thread.snapshotID
            turns = thread.turns.map(TranscriptTurn.init)
            turnRevisions = thread.turnRevisions
            updateWorkingPhrase()
            updateStreams()
            rebuildRows()
        }
        loadOlderTurnsIfNearTop()
    }

    /// Asks the store for the turns before the first loaded one when the
    /// viewport nears the top: once per loaded history, again after the
    /// reader leaves the top and returns. They arrive as rows prepended
    /// above the reader, whose place holds (rule 4).
    func loadOlderTurnsIfNearTop() {
        guard hasOlderTurns, let store, !isAwaitingInitialEnd, let viewport = lastViewport else { return }
        guard viewportTop < max(240, viewport.visibleHeight) else {
            requestedOlderBefore = nil
            return
        }
        guard let oldest = turns.first?.id, requestedOlderBefore != oldest else { return }
        requestedOlderBefore = oldest
        Task { await store.loadOlderTurns() }
    }

    /// Builds the rows from the turns and what is parsed or streaming, and
    /// replaces only the range that changed. When `firstChangedTurn > 0`,
    /// skips unchanged older turns so live tail updates never scan history.
    func rebuildRows(fromTurnIndex firstChangedTurn: Int = 0) {
        let builder = TranscriptBuilder(
            blocks: { [self] messageID, source in blocks(forMessage: messageID, source: source) },
            metrics: { [self] messageID in streams[messageID]?.metrics ?? parsedMessages[messageID]?.metrics },
            expandedTurnIDs: expandedTurnIDs, workingPhrase: workingPhrase, plan: plan)
        guard !rows.isEmpty else {
            setRows(builder.rows(for: turns))
            return
        }
        let startRow: Int
        let replacement: [TranscriptRow]
        if firstChangedTurn > 0, firstChangedTurn <= turns.count,
            let lastPrevRow = rows.lastIndex(where: { $0.turnID == turns[firstChangedTurn - 1].id })
        {
            startRow = lastPrevRow + 1
            replacement = builder.rows(
                for: turns[firstChangedTurn...], hasRunningTurn: turns.contains(where: \.isRunning))
        } else {
            startRow = 0
            replacement = builder.rows(for: turns)
        }
        let oldCount = rows.count - startRow
        let shorter = min(oldCount, replacement.count)
        func same(_ old: Int, _ new: Int) -> Bool {
            rows[old].id == replacement[new].id && rows[old].kind == replacement[new].kind
        }
        var prefix = 0
        while prefix < shorter, same(startRow + prefix, prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, same(rows.count - 1 - suffix, replacement.count - 1 - suffix) { suffix += 1 }
        guard prefix < oldCount || prefix < replacement.count else { return }
        replaceRows(
            (startRow + prefix)..<(rows.count - suffix),
            with: Array(replacement[prefix..<(replacement.count - suffix)]), heights: [:])
    }

    private func blocks(forMessage messageID: String, source: String) -> [MarkdownBlock]? {
        if let stream = streams[messageID] { return stream.blocks }
        if let parsed = parsedMessages[messageID], parsed.source == source { return parsed.blocks }
        return nil
    }

    /// Expands or collapses a finished turn's work (rule 6).
    func toggleExpansion(turnID: String) {
        noteExpansion()
        if expandedTurnIDs.remove(turnID) == nil { expandedTurnIDs.insert(turnID) }
        rebuildRows()
    }

    /// Picks a new verb for the working row when the running turn's latest
    /// entry changes.
    private func updateWorkingPhrase() {
        guard let turn = turns.last(where: \.isRunning) else { return }
        let key = "\(turn.id)|\(turn.entries.last?.ref ?? "")"
        guard key != workingActivityKey else { return }
        if workingActivityKey != nil { workingPhrase = ChatWorkingPhrases.next(after: workingPhrase) }
        workingActivityKey = key
    }

    // MARK: Streaming

    /// Assistant messages of the running turn stream; a message whose turn
    /// ended gets one final parse.
    private func updateStreams() {
        guard let store, let threadID else { return }
        var live: Set<String> = []
        for turn in turns where turn.isRunning {
            for entry in turn.entries where entry.kind == .assistantMessage {
                let messageID = "\(turn.id)|\(entry.ref)"
                live.insert(messageID)
                var stream = streams[messageID] ?? TranscriptStream(text: nil, entryText: entry.text)
                stream.text = store.streamingText(threadID: threadID, rowID: messageID)
                stream.entryText = entry.text
                streams[messageID] = stream
            }
        }
        for (messageID, stream) in streams where !live.contains(messageID) && !stream.isFinishing {
            var finishing = stream
            finishing.isFinishing = true
            finishing.entryText = finalText(of: messageID) ?? stream.currentText
            finishing.text = nil
            streams[messageID] = finishing
        }
        updateFrameUpdates()
    }

    private static func samePlan(_ lhs: [PlanEntry], _ rhs: [PlanEntry]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) where a.content != b.content || a.status != b.status || a.priority != b.priority {
            return false
        }
        return true
    }

    private func finalText(of messageID: String) -> String? {
        for turn in turns {
            for entry in turn.entries where "\(turn.id)|\(entry.ref)" == messageID { return entry.text }
        }
        return nil
    }

    func updateFrameUpdates() {
        host?.setNeedsFrameUpdates(!streams.isEmpty || endJump != nil)
    }

    /// Once per display frame while a message streams: sends each stream's
    /// new text to the worker, one update in flight per stream.
    func frameDidTick() {
        if endJump != nil { stepEndJump() }
        guard columnWidth > 0 else { return }
        let reducesMotion = TranscriptMotion.isReduced
        for (messageID, var stream) in streams where !stream.isInFlight {
            let text = stream.currentText
            guard stream.isFinishing || stream.releasedLength < text.utf8.count else { continue }
            let shown = stream.releasedLength
            let released = String(stream.release(text, reducesMotion: reducesMotion || isAwaitingInitialEnd))
            guard stream.isFinishing || stream.releasedLength > shown else { continue }
            stream.isInFlight = true
            streams[messageID] = stream
            let drawing = palette.map { palette in
                TranscriptStreamWorker.Drawing(
                    palette: palette, scale: host?.scale ?? 2, colorSpace: host?.colorSpace ?? RowLayer.colorSpace)
            }
            let update = TranscriptStreamWorker.Update(
                messageID: messageID, text: released, isFinished: stream.isFinishing, width: columnWidth, style: style,
                codeColors: [:], isDark: palette?.isDark, drawing: drawing)
            let worker = streamWorker
            Task { [weak self] in
                let result = await worker.run(update)
                self?.applyStream(result)
            }
        }
    }

    private func applyStream(_ result: TranscriptStreamWorker.Result) {
        updating { applyStreamResult(result) }
    }

    private func applyStreamResult(_ result: TranscriptStreamWorker.Result) {
        guard var stream = streams[result.messageID] else { return }
        stream.isInFlight = false
        if result.isFinished {
            streams[result.messageID] = nil
            cacheParsedMessage(
                id: result.messageID, source: stream.entryText, blocks: result.blocks, metrics: result.metrics)
            updateFrameUpdates()
        } else {
            guard result.textLength >= stream.shownLength else {
                streams[result.messageID] = stream
                return
            }
            stream.blocks = result.blocks
            stream.metrics = result.metrics
            stream.shownLength = result.textLength
            streams[result.messageID] = stream
        }
        applyStreamRows(result)
    }

    /// Puts a stream result's blocks into the message's rows: in place when
    /// only content changed (the tail growing), as one structural change
    /// when blocks were added.
    private func applyStreamRows(_ result: TranscriptStreamWorker.Result) {
        let messageID = result.messageID
        // The message's rows are contiguous from its first block.
        var existing: [Int] = []
        if let first = geometry.index(for: "\(messageID)#0") {
            var index = first
            while index < rows.count, rows[index].sourceID == messageID, rows[index].role == .assistant {
                existing.append(index)
                index += 1
            }
        }
        let turnID = existing.first.flatMap { rows[$0].turnID } ?? messageID.split(separator: "|", maxSplits: 1).first.map(String.init)
        let kinds = TranscriptBlockFlattener.kinds(for: result.blocks, kind: .assistant)
        let newRows = kinds.enumerated().map { index, kind in
            let rowMetrics = index < result.metrics.count ? result.metrics[index] : nil
            return TranscriptRow(
                id: "\(messageID)#\(index)", sourceID: messageID,
                kind: kind,
                messageID: messageID, role: .assistant, turnID: turnID, metrics: rowMetrics)
        }
        let selectionFollows = selectionEnd(atEndOf: existing)
        let selectionTouchesStream: Bool = {
            guard let ordered = orderedSelection(), let first = existing.first, let last = existing.last else {
                return false
            }
            return ordered.start.index <= last && ordered.end.index >= first
        }()
        if selectionTouchesStream { host?.selectedTextWillChange() }
        // Laid out at a width or text size the column no longer has (a resize
        // or Dynamic Type change meanwhile): the rows still change, their
        // layouts come from the layout queue.
        let laidOut = result.width == columnWidth && result.styleVersion == style.version ? result.rows : []
        var heights: [String: CGFloat] = [:]
        for row in laidOut where row.index < newRows.count && newRows[row.index].kind == row.kind {
            heights[newRows[row.index].id] = row.layout.height
            measuredRowHeights[newRows[row.index].id] = row.layout.height
        }
        let sameIDs = existing.count == newRows.count && zip(existing, newRows).allSatisfy { rows[$0].id == $1.id }
        if sameIDs {
            // Only the blocks the worker laid out changed (finished blocks
            // never do): the rest are not compared again every frame.
            let changed = result.rows.compactMap { row in
                row.index < newRows.count ? (existing[row.index], newRows[row.index]) : nil
            }
            updateRows(changed, heights: heights)
        } else if let first = existing.first, let last = existing.last {
            replaceRows(first..<(last + 1), with: newRows, heights: heights)
        } else {
            rebuildRows()
            setHeights(heights)
        }
        if laidOut.isEmpty, !result.rows.isEmpty { scheduleWork() }
        for row in laidOut where row.index < newRows.count {
            let id = newRows[row.index].id
            guard let rowIndex = geometry.index(for: id), rows[rowIndex].kind == row.kind else { continue }
            let key = currentKey(rows[rowIndex])
            let layout = RowLayout(rowID: id, key: key, height: row.layout.height, content: row.layout.content)
            storeLayout(layout)
            if let drawn = row.drawn { preDrawnBands[id] = (layout, drawn) }
        }
        if isAwaitingInitialEnd { alignInitialEndIfPossible() }
        if let selectionFollows, let last = newRows.last, let index = geometry.index(for: last.id),
            let length = selectableLength(ofRowAt: index), var selection
        {
            // A selection that reached the streamed text's end grows with
            // it, as text selected to the end of a page does in a browser.
            let end = TextPosition(rowID: last.id, offset: length)
            if selectionFollows == .anchor { selection.anchor = end } else { selection.focus = end }
            self.selection = selection
            host?.setNeedsSelectionDisplay()
        }
        if selectionTouchesStream { host?.selectedTextDidChange() }
        host?.setNeedsRowPlacement()
    }

    private enum SelectionEnd { case anchor, focus }

    /// Which end of the selection, if any, sits at the end of the text of
    /// the rows at `indices` (a streamed message's).
    private func selectionEnd(atEndOf indices: [Int]) -> SelectionEnd? {
        guard let selection, !selection.isEmpty, let last = indices.last,
            let length = selectableLength(ofRowAt: last)
        else { return nil }
        let end = TextPosition(rowID: rows[last].id, offset: length)
        guard let ordered = orderedSelection(), ordered.end.index == last, ordered.end.offset == length else {
            return nil
        }
        return selection.focus == end ? .focus : .anchor
    }
}
