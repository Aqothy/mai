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
        observeStore()
        // Rule 9's readiness waits at most a second; check again then even
        // if nothing else arrives.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.05))
            self?.alignInitialEndIfPossible()
        }
    }

    /// Re-armed after every change: the store publishes structural changes
    /// (entries, turns), not each streamed chunk.
    private func observeStore() {
        guard let store, let threadID else { return }
        let thread = withObservationTracking {
            store.selectedThread
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeStore() }
        }
        guard let thread, thread.id == threadID else { return }
        // Copied out so the store's turns are not shared past this call.
        turns = thread.turns.map(TranscriptTurn.init)
        hasOlderTurns = thread.older != nil
        updateWorkingPhrase()
        updateStreams()
        rebuildRows()
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
    /// replaces only the range that changed: a new entry, a turn ending or a
    /// parsed message touches a few rows of thousands.
    func rebuildRows() {
        let builder = TranscriptBuilder(
            blocks: { [self] messageID, source in blocks(forMessage: messageID, source: source) },
            expandedTurnIDs: expandedTurnIDs, workingPhrase: workingPhrase)
        let newRows = builder.rows(for: turns)
        guard !rows.isEmpty else {
            setRows(newRows)
            return
        }
        func same(_ old: Int, _ new: Int) -> Bool {
            rows[old].id == newRows[new].id && rows[old].kind == newRows[new].kind
        }
        let shorter = min(rows.count, newRows.count)
        var prefix = 0
        while prefix < shorter, same(prefix, prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, same(rows.count - 1 - suffix, newRows.count - 1 - suffix) { suffix += 1 }
        guard prefix < rows.count || prefix < newRows.count else { return }
        replaceRows(
            prefix..<(rows.count - suffix), with: Array(newRows[prefix..<(newRows.count - suffix)]), heights: [:])
        rowsDidChange()
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

    private func finalText(of messageID: String) -> String? {
        for turn in turns {
            for entry in turn.entries where "\(turn.id)|\(entry.ref)" == messageID { return entry.text }
        }
        return nil
    }

    /// Whether `row` belongs to a message still streaming: it grows at its
    /// bottom.
    func isStreaming(_ row: TranscriptRow) -> Bool {
        guard let messageID = row.messageID, !streams.isEmpty else { return false }
        return streams[messageID] != nil
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
            // A closed block laid out again (a new width) keeps its colors.
            var codeColors: [String: CodeColors] = [:]
            for (index, block) in stream.blocks.enumerated() {
                guard case .code = block, let colors = layouts["\(messageID)#\(index)"]?.content.codeLayout?.colors
                else { continue }
                codeColors["\(messageID)#\(index)"] = colors
            }
            let drawing = palette.map { palette in
                TranscriptStreamWorker.Drawing(
                    palette: palette, scale: host?.scale ?? 2, colorSpace: host?.colorSpace ?? RowLayer.colorSpace)
            }
            let update = TranscriptStreamWorker.Update(
                messageID: messageID, text: released, isFinished: stream.isFinishing, width: columnWidth, style: style,
                codeColors: codeColors, isDark: palette?.isDark, drawing: drawing)
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
            parsedMessages[result.messageID] = (stream.entryText, result.blocks)
            updateFrameUpdates()
        } else {
            guard result.textLength >= stream.shownLength else {
                streams[result.messageID] = stream
                return
            }
            stream.blocks = result.blocks
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
        let newRows = result.blocks.enumerated().map { index, block in
            TranscriptRow(
                id: "\(messageID)#\(index)", sourceID: messageID,
                kind: .markdownBlock(
                    block, .of(index, in: result.blocks)),
                messageID: messageID, role: .assistant)
        }
        // The message's rows are contiguous from its first block.
        var existing: [Int] = []
        if let first = geometry.index(for: "\(messageID)#0") {
            var index = first
            while index < rows.count, rows[index].sourceID == messageID, rows[index].role == .assistant {
                existing.append(index)
                index += 1
            }
        }
        let selectionFollows = selectionEnd(atEndOf: existing)
        // Laid out at a width or text size the column no longer has (a resize
        // or Dynamic Type change meanwhile): the rows still change, their
        // layouts come from the layout queue.
        let laidOut = result.width == columnWidth && result.styleVersion == style.version ? result.rows : []
        var heights: [String: CGFloat] = [:]
        for row in laidOut where row.index < newRows.count && newRows[row.index].kind == row.kind {
            heights[newRows[row.index].id] = row.layout.height
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
            layouts[id] = layout
            measuredKeys[id] = key
            if let drawn = row.drawn { streamedBands[id] = (layout, drawn) }
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
        // Code the stream closed (or the end of the turn did) gets its
        // colors; the open block stays plain until then.
        submitHighlights(forRowIDs: newRows.compactMap { row in
            if case .markdownBlock(.code, _) = row.kind { row.id } else { nil }
        })
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
