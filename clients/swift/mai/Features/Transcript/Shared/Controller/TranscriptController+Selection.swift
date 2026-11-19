import CoreGraphics
import Foundation

/// The selection across rows (PLAN 5): positions are rows and offsets into
/// their text, so a selection holds while rows scroll away, stream and
/// re-lay out. Platform hosts turn input into positions here and draw what
/// `selectedRange(inRowAt:)` says.
extension TranscriptController {
    /// Replaces the selection. Starting one stops following (rule 10).
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
        guard let layout = layout(forRowAt: index, synchronously: true) else { return nil }
        var local = CGPoint(x: point.x - columnX, y: point.y - geometry.offset(at: index))
        if let body = layout.content.wideBody, local.y >= body.frame.minY { local.x += scrollX(rows[index].id) }
        guard let offset = layout.content.textOffset(closestTo: local) else { return nil }
        return TextPosition(rowID: rows[index].id, offset: offset)
    }

    /// The link at `point` (document coordinates), if any.
    func link(atDocumentPoint point: CGPoint, columnX: CGFloat) -> URL? {
        guard point.y >= 0, let index = geometry.index(at: point.y), let layout = layouts[rows[index].id] else {
            return nil
        }
        return layout.content.link(
            at: CGPoint(x: point.x - columnX, y: point.y - geometry.offset(at: index)))
    }

    /// The finished turn whose header is at `y` (document coordinates), if
    /// any: clicking or tapping it toggles its work (rule 6).
    func expandableTurn(atDocumentY y: CGFloat) -> String? {
        guard y >= 0, let index = geometry.index(at: y), case .turnHeader(let header) = rows[index].kind,
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

    /// The text from `start` to `end` (in order), rows joined by newlines.
    func text(from start: TextPosition, to end: TextPosition) -> String {
        guard let first = geometry.index(for: start.rowID), let last = geometry.index(for: end.rowID), first <= last
        else { return "" }
        var parts: [String] = []
        for index in first...last {
            guard let text = selectableText(ofRowAt: index) else { continue }
            let utf16 = text.utf16
            let from = index == first ? min(start.offset, utf16.count) : 0
            let to = index == last ? min(end.offset, utf16.count) : utf16.count
            guard from <= to else { continue }
            let lower = utf16.index(utf16.startIndex, offsetBy: from)
            let upper = utf16.index(utf16.startIndex, offsetBy: to)
            parts.append(String(text[lower..<upper]))
        }
        return parts.joined(separator: "\n")
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

    /// `position` moved by `offset` characters across rows; nil past either
    /// end.
    func position(from position: TextPosition, offset: Int) -> TextPosition? {
        guard var index = geometry.index(for: position.rowID) else { return nil }
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
                return TextPosition(rowID: rows[index].id, offset: offset)
            }
        }
    }

    /// The characters from `a` to `b`, negative when `b` comes first.
    func offset(from a: TextPosition, to b: TextPosition) -> Int {
        guard let first = geometry.index(for: a.rowID), let second = geometry.index(for: b.rowID) else { return 0 }
        if first == second { return b.offset - a.offset }
        if second < first { return -offset(from: b, to: a) }
        var count = (selectableLength(ofRowAt: first) ?? 0) - a.offset
        for index in (first + 1)..<second where rows[index].kind.isSelectable {
            count += 1 + (selectableLength(ofRowAt: index) ?? 0)
        }
        return count + 1 + b.offset
    }

    /// Highlight rects from `start` to `end` (document coordinates) for rows
    /// with layouts (those near the viewport, the only ones on screen).
    func selectionRects(
        from start: TextPosition, to end: TextPosition, columnX: CGFloat, scrollX: (String) -> CGFloat
    ) -> [CGRect] {
        guard let first = geometry.index(for: start.rowID), let last = geometry.index(for: end.rowID), first <= last
        else { return [] }
        var rects: [CGRect] = []
        for index in first...last where rows[index].kind.isSelectable {
            guard let layout = layouts[rows[index].id], let length = selectableLength(ofRowAt: index) else { continue }
            let from = index == first ? start.offset : 0
            let to = index == last ? end.offset : length
            guard from < to else { continue }
            var dx = columnX
            if layout.content.wideBody != nil { dx -= scrollX(rows[index].id) }
            let top = geometry.offset(at: index)
            for rect in layout.content.selectionRects(for: from..<to) { rects.append(rect.offsetBy(dx: dx, dy: top)) }
        }
        return rects
    }

    /// The caret before `position` (document coordinates), when its row has
    /// a layout.
    func caretRect(for position: TextPosition, columnX: CGFloat) -> CGRect? {
        guard let index = geometry.index(for: position.rowID), let layout = layouts[position.rowID] else { return nil }
        for segment in layout.content.textSegments where position.offset >= segment.start && position.offset <= segment.end {
            let local = position.offset - segment.start
            guard let line = segment.layout.lines.last(where: { $0.range.lowerBound <= local }) else { continue }
            let x = line.caretOffsets[min(local - line.range.lowerBound, line.caretOffsets.count - 1)]
            return CGRect(
                x: columnX + segment.origin.x + x, y: geometry.offset(at: index) + segment.origin.y + line.top,
                width: 2, height: line.height)
        }
        return nil
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

    /// Every selectable row's text, first to last.
    func selectAll() {
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
        let offset = min(max(0, position.offset), string.length - 1)
        var found: NSRange?
        let paragraph = string.paragraphRange(for: NSRange(location: offset, length: 0))
        string.enumerateSubstrings(in: paragraph, options: [.byWords, .substringNotRequired]) { _, range, _, stop in
            if NSLocationInRange(offset, range) {
                found = range
                stop.pointee = true
            }
        }
        let range = found ?? string.rangeOfComposedCharacterSequence(at: offset)
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
        return selectableText(ofRowAt: index)?.utf16.count
    }
}
