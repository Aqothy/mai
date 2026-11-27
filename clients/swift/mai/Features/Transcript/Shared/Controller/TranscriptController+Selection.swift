import CoreGraphics
import Foundation

/// The selection across rows (PLAN 5): positions are rows and offsets into
/// their text, so a selection holds while rows scroll away, stream and
/// re-lay out. Platform hosts turn input into positions here and draw what
/// `selectedRange(inRowAt:)` says.
extension TranscriptController {
    /// Replaces the selection; following is unaffected, as in browsers.
    func setSelection(_ newSelection: TranscriptSelection?) {
        guard newSelection != selection else { return }
        selection = newSelection
        host?.setNeedsSelectionDisplay()
    }

    /// The text position nearest `point` (document coordinates) in a column
    /// starting at `columnX`. A point over chrome (headers, actions) lands at
    /// the end of the selectable row above it, or the start of the one below.
    /// `scrollX` is how far a wide block's body is scrolled, by row ID.
    func textPosition(
        atDocumentPoint point: CGPoint, columnX: CGFloat, scrollX: (String) -> CGFloat = { _ in 0 }
    ) -> TextPosition? {
        let y = min(max(0, point.y), geometry.totalHeight - 1)
        guard let index = geometry.index(at: y) else { return nil }
        if rows[index].kind.isSelectable,
            let position = position(inRowAt: index, point: point, columnX: columnX, scrollX: scrollX)
        {
            return position
        }
        var above = index - 1
        while above >= 0 {
            if rows[above].kind.isSelectable, let length = selectableLength(ofRowAt: above) {
                return TextPosition(rowID: rows[above].id, offset: length)
            }
            above -= 1
        }
        var below = index + 1
        while below < rows.count {
            if rows[below].kind.isSelectable { return TextPosition(rowID: rows[below].id, offset: 0) }
            below += 1
        }
        return nil
    }

    private func position(
        inRowAt index: Int, point: CGPoint, columnX: CGFloat, scrollX: (String) -> CGFloat
    ) -> TextPosition? {
        guard let layout = layouts[rows[index].id] else { return nil }
        var local = CGPoint(x: point.x - columnX, y: point.y - geometry.offset(at: index))
        if let body = layout.content.wideBody, local.y >= body.frame.minY { local.x += scrollX(rows[index].id) }
        guard let offset = layout.content.textOffset(closestTo: local) else { return nil }
        return TextPosition(rowID: rows[index].id, offset: offset)
    }

    private func strictLocalPoint(
        for point: CGPoint, inRowAt index: Int, layout: RowLayout, columnX: CGFloat, scrollX: (String) -> CGFloat
    ) -> CGPoint? {
        var local = CGPoint(x: point.x - columnX, y: point.y - geometry.offset(at: index))
        if let body = layout.content.wideBody, local.y >= body.frame.minY {
            guard local.x >= body.frame.minX, local.x <= body.frame.maxX else { return nil }
            local.x += scrollX(rows[index].id)
        }
        return local
    }

    /// Strict text hit test: returns a position only when `point` actually
    /// lands inside a selectable row's text segment (never snapping from
    /// margins or chrome to an adjacent row). Used for right-click context
    /// menus and Force-Touch Look Up.
    func strictTextPosition(
        atDocumentPoint point: CGPoint, columnX: CGFloat, scrollX: (String) -> CGFloat = { _ in 0 }
    ) -> TextPosition? {
        guard point.y >= 0, point.y < geometry.totalHeight, let index = geometry.index(at: point.y),
            rows[index].kind.isSelectable, let layout = layouts[rows[index].id],
            let local = strictLocalPoint(for: point, inRowAt: index, layout: layout, columnX: columnX, scrollX: scrollX),
            let offset = layout.content.strictTextOffset(at: local)
        else { return nil }
        return TextPosition(rowID: rows[index].id, offset: offset)
    }

    /// The link at `point` (document coordinates), if any.
    func link(
        atDocumentPoint point: CGPoint, columnX: CGFloat, scrollX: (String) -> CGFloat = { _ in 0 }
    ) -> URL? {
        guard point.y >= 0, let index = geometry.index(at: point.y), let layout = layouts[rows[index].id],
            let local = strictLocalPoint(for: point, inRowAt: index, layout: layout, columnX: columnX, scrollX: scrollX)
        else { return nil }
        return layout.content.link(at: local)
    }

    /// The finished turn whose header is at `point` (document coordinates)
    /// inside the transcript column, if any: clicking or tapping it toggles
    /// its work (rule 6).
    func expandableTurn(atDocumentPoint point: CGPoint, columnX: CGFloat) -> String? {
        guard point.y >= 0, point.x >= columnX, point.x <= columnX + columnWidth,
            let index = geometry.index(at: point.y), case .turnHeader(let header) = rows[index].kind,
            !header.isRunning
        else { return nil }
        return header.turnID
    }

    // MARK: Ranges

    /// The selection's ends in document order, as row indices and offsets;
    /// nil without a selection or when a row it ends in is gone.
    func orderedSelection() -> (start: (index: Int, offset: Int), end: (index: Int, offset: Int))? {
        guard let selection, let anchor = geometry.index(for: selection.anchor.rowID),
            let focus = geometry.index(for: selection.focus.rowID)
        else { return nil }
        let a = (index: anchor, offset: selection.anchor.offset)
        let b = (index: focus, offset: selection.focus.offset)
        return (a.index, a.offset) <= (b.index, b.offset) ? (a, b) : (b, a)
    }

    /// Whether there is a non-empty selection whose rows are still present.
    var hasValidSelection: Bool {
        guard let ends = orderedSelection() else { return false }
        return ends.start.index != ends.end.index || ends.start.offset != ends.end.offset
    }

    /// The selected part of row `index`'s text.
    func selectedRange(inRowAt index: Int) -> Range<Int>? {
        guard selection != nil, rows[index].kind.isSelectable, let ends = orderedSelection(),
            index >= ends.start.index, index <= ends.end.index
        else { return nil }
        let from = index == ends.start.index ? ends.start.offset : 0
        let to: Int
        if index == ends.end.index {
            to = ends.end.offset
        } else {
            guard let length = selectableLength(ofRowAt: index) else { return nil }
            to = length
        }
        return from < to ? from..<to : nil
    }

    /// The selected text as plain text: rows joined by newlines, code
    /// verbatim, tables tab-separated (PLAN 5).
    func selectedText() -> String {
        guard let selection, let anchorFirst = isBefore(selection.anchor, selection.focus) else { return "" }
        return anchorFirst
            ? text(from: selection.anchor, to: selection.focus) : text(from: selection.focus, to: selection.anchor)
    }

    /// The text from `start` to `end` (in order), rows joined by their
    /// separators. Unparsed `.pendingMessage` rows render their Markdown on
    /// demand so copied text never depends on scroll history.
    func text(from start: TextPosition, to end: TextPosition) -> String {
        guard let first = geometry.index(for: start.rowID), let last = geometry.index(for: end.rowID), first <= last
        else { return "" }
        var result = ""
        var hasPart = false
        for index in first...last {
            let row = rows[index]
            guard row.kind.isSelectable else { continue }
            let text: String
            let from: Int
            let to: Int
            if case .pendingMessage(let message, let source) = row.kind {
                text = RowSelectableText.renderedPendingString(message: message, source: source, style: style)
                let renderedCount = text.utf16.count
                let sourceCount = source.utf16.count
                from = index == first ? min(start.offset, renderedCount) : 0
                to = index == last ? (end.offset >= sourceCount ? renderedCount : min(end.offset, renderedCount)) : renderedCount
            } else {
                guard let rowText = selectableText(ofRowAt: index) else { continue }
                text = rowText
                let count = text.utf16.count
                from = index == first ? min(start.offset, count) : 0
                to = index == last ? min(end.offset, count) : count
            }
            guard from <= to else { continue }
            let utf16 = text.utf16
            let lower = utf16.index(utf16.startIndex, offsetBy: from)
            let upper = utf16.index(utf16.startIndex, offsetBy: to)
            if hasPart { result += "\n" }
            result += text[lower..<upper]
            hasPart = true
        }
        return result
    }

    // MARK: Positions as one text

    /// The transcript's selectable rows read as one text, rows joined by a
    /// newline: what UIKit's text system walks (iOS `UITextInput`).
    var firstTextPosition: TextPosition? {
        rows.firstIndex(where: \.kind.isSelectable).map { TextPosition(rowID: rows[$0].id, offset: 0) }
    }

    var lastTextPosition: TextPosition? {
        guard let index = rows.lastIndex(where: \.kind.isSelectable), let length = selectableLength(ofRowAt: index)
        else { return nil }
        return TextPosition(rowID: rows[index].id, offset: length)
    }

    /// `position` moved by `offset` UTF-16 units across rows, snapped in the
    /// direction of motion so a step never lands inside an Apple composed
    /// character sequence (`TextLayoutEngine.startsCluster`); nil past either
    /// end.
    func position(from position: TextPosition, offset: Int) -> TextPosition? {
        guard var index = geometry.index(for: position.rowID) else { return nil }
        let direction = offset
        var offset = position.offset + offset
        while true {
            guard let length = selectableLength(ofRowAt: index) else { return nil }
            if offset < 0 {
                guard let previous = rows[..<index].lastIndex(where: \.kind.isSelectable),
                    let previousLength = selectableLength(ofRowAt: previous)
                else { return nil }
                offset += previousLength + 1
                index = previous
            } else if offset > length {
                guard let next = rows[(index + 1)...].firstIndex(where: \.kind.isSelectable) else { return nil }
                offset -= length + 1
                index = next
            } else {
                if direction != 0, offset > 0, offset < length, let text = selectableText(ofRowAt: index) {
                    let ns = text as NSString
                    if !TextLayoutEngine.startsCluster(ns, at: offset) {
                        let cluster = TextLayoutEngine.clusterRange(in: ns, at: offset)
                        offset = direction > 0 ? NSMaxRange(cluster) : cluster.location
                    }
                }
                return TextPosition(rowID: rows[index].id, offset: offset)
            }
        }
    }

    /// Moves `position` vertically by `lineOffset` visual lines (negative =
    /// up, positive = down), preserving the caret's horizontal x coordinate.
    func positionVertically(
        from position: TextPosition, lineOffset: Int, columnX: CGFloat, scrollX: (String) -> CGFloat = { _ in 0 }
    ) -> TextPosition? {
        guard var rowIndex = geometry.index(for: position.rowID),
            let caret = caretRect(for: position, columnX: columnX, scrollX: scrollX)
        else { return nil }
        guard lineOffset != 0 else { return position }
        let targetX = caret.minX
        var remaining = abs(lineOffset)
        let step = lineOffset > 0 ? 1 : -1

        func columnKey(of segment: TextSegment) -> CGFloat {
            segment.hitRect?.minX ?? segment.origin.x
        }

        func rowLines(
            in rowIndex: Int, matchingColumnX: CGFloat? = nil
        ) -> [(segment: TextSegment, line: TextLine, top: CGFloat, bottom: CGFloat)]? {
            guard let layout = layouts[rows[rowIndex].id] else { return nil }
            let rowTop = geometry.offset(at: rowIndex)
            let segments = layout.content.textSegments
            let activeColumnX: CGFloat?
            if let matchingColumnX {
                activeColumnX = matchingColumnX
            } else if segments.count > 1 {
                let localX = targetX - columnX + (layout.content.wideBody != nil ? scrollX(rows[rowIndex].id) : 0)
                activeColumnX = segments.min { a, b in
                    let aDist = a.hitRect.map { localX < $0.minX ? $0.minX - localX : (localX > $0.maxX ? localX - $0.maxX : 0) }
                        ?? abs(a.origin.x - localX)
                    let bDist = b.hitRect.map { localX < $0.minX ? $0.minX - localX : (localX > $0.maxX ? localX - $0.maxX : 0) }
                        ?? abs(b.origin.x - localX)
                    return aDist < bDist
                }.map(columnKey(of:))
            } else {
                activeColumnX = nil
            }
            var result: [(TextSegment, TextLine, CGFloat, CGFloat)] = []
            for segment in segments {
                if let colX = activeColumnX, segments.count > 1, abs(columnKey(of: segment) - colX) > 1 {
                    continue
                }
                for line in segment.layout.lines {
                    let top = rowTop + segment.origin.y + line.top
                    result.append((segment, line, top, top + line.height))
                }
            }
            return result.isEmpty ? nil : result
        }

        let currentColumnX: CGFloat? = {
            guard let segments = layouts[rows[rowIndex].id]?.content.textSegments, segments.count > 1,
                let seg = segments.first(where: { position.offset >= $0.start && position.offset <= $0.end })
            else { return nil }
            return columnKey(of: seg)
        }()

        guard var currentLines = rowLines(in: rowIndex, matchingColumnX: currentColumnX),
            var lineIdx = currentLines.lastIndex(where: {
                position.offset >= $0.segment.start + $0.line.range.lowerBound
                    && position.offset <= $0.segment.start + $0.line.range.upperBound
            })
        else { return nil }

        while remaining > 0 {
            let count = currentLines.count
            let avail = step > 0 ? (count - 1 - lineIdx) : lineIdx
            if remaining <= avail {
                lineIdx += step * remaining
                remaining = 0
            } else {
                remaining -= avail + 1
                var nextRow = rowIndex + step
                while rows.indices.contains(nextRow), !rows[nextRow].kind.isSelectable { nextRow += step }
                guard rows.indices.contains(nextRow) else {
                    let boundary = step < 0 ? firstTextPosition : lastTextPosition
                    return boundary == position ? nil : boundary
                }
                guard let nextLines = rowLines(in: nextRow) else {
                    let length = selectableLength(ofRowAt: nextRow) ?? 0
                    return TextPosition(rowID: rows[nextRow].id, offset: step < 0 ? length : 0)
                }
                rowIndex = nextRow
                currentLines = nextLines
                lineIdx = step > 0 ? 0 : nextLines.count - 1
            }
        }

        let chosen = currentLines[lineIdx]
        let docPoint = CGPoint(x: targetX, y: (chosen.top + chosen.bottom) / 2)
        return self.position(inRowAt: rowIndex, point: docPoint, columnX: columnX, scrollX: scrollX)
    }

    /// The valid offset bounds of the logical block (row, or single table cell)
    /// containing `position`, used to clamp iOS word/sentence tokenization so
    /// selection never bleeds across rows or table cells.
    func tokenBoundaryRange(for position: TextPosition) -> Range<Int>? {
        guard let index = geometry.index(for: position.rowID), rows[index].kind.isSelectable else { return nil }
        if let layout = layouts[position.rowID] {
            let segments = layout.content.textSegments
            if segments.count > 1,
                let segment = segments.first(where: { position.offset >= $0.start && position.offset <= $0.end })
            {
                return segment.start..<segment.end
            }
        }
        guard let length = selectableLength(ofRowAt: index) else { return nil }
        return 0..<length
    }

    /// The characters from `a` to `b`, negative when `b` comes first.
    /// O(log n) via `TranscriptGeometry`'s selectable-span Fenwick tree.
    func offset(from a: TextPosition, to b: TextPosition) -> Int {
        guard let first = geometry.index(for: a.rowID), let second = geometry.index(for: b.rowID) else { return 0 }
        if first == second { return b.offset - a.offset }
        if second < first { return -offset(from: b, to: a) }
        let startTail = (selectableLength(ofRowAt: first) ?? 0) - a.offset
        let middle = geometry.selectableSpan(in: (first + 1)..<second)
        return startTail + middle + 1 + b.offset
    }

    /// Highlight rects from `start` to `end` (document coordinates) for rows
    /// with layouts, clipped to wide blocks' horizontal scroller frames.
    ///
    /// `isStart` is true only on the first rect of `start`'s actual row, and
    /// `isEnd` only on the last rect of `end`'s actual row — so when either
    /// endpoint scrolls off-screen and loses its layout, UIKit never attaches a
    /// start/end grab handle to a mid-selection visible row. When an endpoint
    /// sits exactly on a row boundary (`from == to`), a zero-width caret rect
    /// carries the `isStart`/`isEnd` tag so iOS still draws its grab handle.
    func taggedSelectionRects(
        from start: TextPosition, to end: TextPosition, columnX: CGFloat, scrollX: (String) -> CGFloat
    ) -> [(rect: CGRect, isStart: Bool, isEnd: Bool)] {
        guard let first = geometry.index(for: start.rowID), let last = geometry.index(for: end.rowID), first <= last
        else { return [] }

        var result: [(rect: CGRect, isStart: Bool, isEnd: Bool)] = []
        for index in first...last where rows[index].kind.isSelectable {
            guard let layout = layouts[rows[index].id], let length = selectableLength(ofRowAt: index) else { continue }
            let top = geometry.offset(at: index)
            let wideBody = layout.content.wideBody
            let clip = wideBody.map { $0.frame.offsetBy(dx: columnX, dy: top) }
            // A selection made before the text shrank (a re-parse) ends past it.
            let from = index == first ? min(start.offset, length) : 0
            let to = index == last ? min(end.offset, length) : length
            guard from < to else {
                if first < last {
                    let isStartEndpoint = index == first
                    let endpoint = isStartEndpoint ? start : end
                    if isStartEndpoint || index == last,
                        let caret = caretRect(for: endpoint, columnX: columnX, scrollX: scrollX)
                    {
                        let handleRect = CGRect(x: caret.minX, y: caret.minY, width: 0, height: caret.height)
                        if clip.map({ handleRect.minX >= $0.minX && handleRect.minX <= $0.maxX }) ?? true {
                            result.append((rect: handleRect, isStart: isStartEndpoint, isEnd: !isStartEndpoint))
                        }
                    }
                }
                continue
            }
            let dx = columnX - (wideBody != nil ? scrollX(rows[index].id) : 0)
            var rowRects: [CGRect] = []
            for rect in layout.content.selectionRects(for: from..<to) {
                var shifted = rect.offsetBy(dx: dx, dy: top)
                if let clip {
                    shifted = shifted.intersection(clip)
                    guard !shifted.isNull, shifted.width > 0 else { continue }
                }
                rowRects.append(shifted)
            }
            for (rectIndex, rect) in rowRects.enumerated() {
                result.append((
                    rect: rect,
                    isStart: index == first && rectIndex == 0,
                    isEnd: index == last && rectIndex == rowRects.count - 1
                ))
            }
        }
        return result
    }

    func selectionRects(
        from start: TextPosition, to end: TextPosition, columnX: CGFloat, scrollX: (String) -> CGFloat
    ) -> [CGRect] {
        taggedSelectionRects(from: start, to: end, columnX: columnX, scrollX: scrollX).map(\.rect)
    }

    /// Highlight rects for the current selection in document order.
    func currentSelectionRects(columnX: CGFloat, scrollX: (String) -> CGFloat) -> [CGRect] {
        guard let selection, !selection.isEmpty, let anchorFirst = isBefore(selection.anchor, selection.focus) else {
            return []
        }
        let start = anchorFirst ? selection.anchor : selection.focus
        let end = anchorFirst ? selection.focus : selection.anchor
        return selectionRects(from: start, to: end, columnX: columnX, scrollX: scrollX)
    }

    /// The caret before `position` (document coordinates), when its row has
    /// a layout.
    func caretRect(
        for position: TextPosition, columnX: CGFloat, scrollX: (String) -> CGFloat = { _ in 0 }
    ) -> CGRect? {
        guard let index = geometry.index(for: position.rowID), let layout = layouts[position.rowID],
            let local = layout.content.caretRect(for: position.offset)
        else { return nil }
        let dx = columnX - (layout.content.wideBody != nil ? scrollX(position.rowID) : 0)
        return local.offsetBy(dx: dx, dy: geometry.offset(at: index))
    }

    /// The message a Comment on the selection belongs to (PLAN Q4): one
    /// message's id and role; across messages no id, and a role only when
    /// they all share it.
    func selectionCommentTarget() -> (messageID: String?, role: String?) {
        guard let ends = orderedSelection() else { return (nil, nil) }
        var messageIDs: Set<String> = []
        var roles: Set<TranscriptRole> = []
        for index in ends.start.index...ends.end.index where selectedRange(inRowAt: index) != nil {
            if let messageID = rows[index].messageID { messageIDs.insert(messageID) }
            if let role = rows[index].role { roles.insert(role) }
        }
        let role = roles.count == 1 ? roles.first?.rawValue : nil
        return (messageIDs.count == 1 ? messageIDs.first : nil, role)
    }

    /// Whether `a` comes before `b` in the transcript; nil when either row
    /// is gone.
    func isBefore(_ a: TextPosition, _ b: TextPosition) -> Bool? {
        guard let first = geometry.index(for: a.rowID), let second = geometry.index(for: b.rowID) else { return nil }
        return (first, a.offset) < (second, b.offset)
    }

    // MARK: Granularity

    /// Selects the entire current message (user or assistant) when a selection
    /// is active inside a message; otherwise selects every selectable row in
    /// the transcript (e.g. Cmd+A with no active selection).
    func selectAll() {
        if let selection, let anchorIdx = geometry.index(for: selection.anchor.rowID),
            rows.indices.contains(anchorIdx), let messageID = rows[anchorIdx].messageID,
            let first = rows.firstIndex(where: { $0.messageID == messageID && $0.kind.isSelectable }),
            let last = rows.lastIndex(where: { $0.messageID == messageID && $0.kind.isSelectable }),
            let length = selectableLength(ofRowAt: last)
        {
            setSelection(
                TranscriptSelection(
                    anchor: TextPosition(rowID: rows[first].id, offset: 0),
                    focus: TextPosition(rowID: rows[last].id, offset: length)))
            return
        }
        guard let first = rows.firstIndex(where: \.kind.isSelectable),
            let last = rows.lastIndex(where: \.kind.isSelectable), let length = selectableLength(ofRowAt: last)
        else { return }
        setSelection(
            TranscriptSelection(
                anchor: TextPosition(rowID: rows[first].id, offset: 0),
                focus: TextPosition(rowID: rows[last].id, offset: length)))
    }

    /// The word (or run of whitespace or punctuation) around `position`.
    func wordRange(around position: TextPosition) -> TranscriptSelection? {
        guard let index = geometry.index(for: position.rowID), let text = selectableText(ofRowAt: index) else {
            return nil
        }
        let string = text as NSString
        guard string.length > 0 else { return TranscriptSelection(caret: position) }
        let offset = min(position.offset, string.length - 1)
        var found: NSRange?
        let paragraph = string.paragraphRange(for: NSRange(location: offset, length: 0))
        string.enumerateSubstrings(in: paragraph, options: [.byWords, .substringNotRequired]) { _, range, _, stop in
            if NSLocationInRange(offset, range) {
                found = range
                stop.pointee = true
            }
        }
        // Whole clusters, as browsers snap words: the tokenizer can cut a
        // letter from its combining marks (`n` + U+0308 next to kana).
        let range = found.map { TextLayoutEngine.clusterRange(in: string, for: $0) }
            ?? TextLayoutEngine.clusterRange(in: string, at: offset)
        return TranscriptSelection(
            anchor: TextPosition(rowID: position.rowID, offset: range.location),
            focus: TextPosition(rowID: position.rowID, offset: NSMaxRange(range)))
    }

    /// The composed character sequence (whole emoji / surrogate pair) at
    /// `position`.
    func characterRange(around position: TextPosition) -> TranscriptSelection? {
        guard let index = geometry.index(for: position.rowID), let text = selectableText(ofRowAt: index) else {
            return nil
        }
        let string = text as NSString
        guard string.length > 0 else { return TranscriptSelection(caret: position) }
        let offset = min(position.offset, string.length - 1)
        let range = TextLayoutEngine.clusterRange(in: string, at: offset)
        return TranscriptSelection(
            anchor: TextPosition(rowID: position.rowID, offset: range.location),
            focus: TextPosition(rowID: position.rowID, offset: NSMaxRange(range)))
    }

    /// The paragraph (line of the row's text, without its newline) around
    /// `position`.
    func paragraphRange(around position: TextPosition) -> TranscriptSelection? {
        guard let index = geometry.index(for: position.rowID), let text = selectableText(ofRowAt: index) else {
            return nil
        }
        let string = text as NSString
        var range = string.paragraphRange(for: NSRange(location: min(position.offset, string.length), length: 0))
        while range.length > 0, string.character(at: NSMaxRange(range) - 1) == 0x0A { range.length -= 1 }
        return TranscriptSelection(
            anchor: TextPosition(rowID: position.rowID, offset: range.location),
            focus: TextPosition(rowID: position.rowID, offset: NSMaxRange(range)))
    }

    // MARK: Row text

    /// Row `index`'s selectable text: from its layout when it has one (any
    /// width: the text does not depend on it), else built from its content.
    func selectableText(ofRowAt index: Int) -> String? {
        let row = rows[index]
        guard row.kind.isSelectable else { return nil }
        if let layout = layouts[row.id], layout.key.contentVersion == row.contentVersion {
            return layout.content.selectableString
        }
        return RowSelectableText.string(for: row.kind, style: style)
    }

    func selectableLength(ofRowAt index: Int) -> Int? {
        let row = rows[index]
        guard row.kind.isSelectable else { return nil }
        if let layout = layouts[row.id], layout.key.contentVersion == row.contentVersion {
            return layout.content.selectableLength
        }
        if let precomputed = row.metrics.selectableUTF16 { return precomputed }
        return RowSelectableText.utf16Length(for: row.kind)
    }
}
