import CoreGraphics
import Foundation

/// A row's selectable text and how it maps to points (PLAN 5): every kind
/// that shows text gives its unified `TextLayout` segments, so prose, code,
/// tables and messages all select through the same functions.
nonisolated extension RowContentLayout {
    /// The laid-out pieces of the row's text, in reading order.
    var textSegments: [TextSegment] {
        switch self {
        case .text(let layout, let origin):
            return [TextSegment(layout: layout, origin: origin, start: 0, hitRect: nil)]
        case .bubble(let layout, _, let textOrigin):
            return [TextSegment(layout: layout, origin: textOrigin, start: 0, hitRect: nil)]
        case .notice(let layout, let frame, let textOrigin):
            return [
                TextSegment(
                    layout: layout, origin: CGPoint(x: frame.minX + textOrigin.x, y: textOrigin.y), start: 0,
                    hitRect: nil)
            ]
        case .code(let code, let frame):
            return [
                TextSegment(
                    layout: code.body,
                    origin: CGPoint(x: frame.minX + code.bodyOrigin.x, y: frame.minY + code.bodyOrigin.y), start: 0,
                    hitRect: nil)
            ]
        case .codeBody(let code):
            return [TextSegment(layout: code.body, origin: CGPoint(x: code.bodyOrigin.x, y: 0), start: 0, hitRect: nil)]
        case .table(let table, let frame):
            return Self.cellSegments(table, gridOrigin: CGPoint(x: frame.minX, y: frame.minY + table.toolbarHeight))
        case .tableBody(let table):
            return Self.cellSegments(table, gridOrigin: .zero)
        case .header, .actions, .empty:
            return []
        }
    }

    private static func cellSegments(_ table: TableLayout, gridOrigin: CGPoint) -> [TextSegment] {
        var segments: [TextSegment] = []
        segments.reserveCapacity(table.cells.count)
        var start = 0
        for cell in table.cells {
            segments.append(
                TextSegment(
                    layout: cell.layout,
                    origin: CGPoint(x: gridOrigin.x + cell.origin.x, y: gridOrigin.y + cell.origin.y), start: start,
                    hitRect: cell.box.offsetBy(dx: gridOrigin.x, dy: gridOrigin.y)))
            start += cell.layout.length + 1
        }
        return segments
    }

    /// The row's text: its segments with their separators.
    var selectableString: String {
        switch self {
        case .code(let code, _), .codeBody(let code):
            return code.code
        case .table(let table, _), .tableBody(let table):
            var text = ""
            for (index, cell) in table.cells.enumerated() {
                if index > 0 { text += table.cells[index - 1].row == cell.row ? "\t" : "\n" }
                text += cell.layout.string
            }
            return text
        default:
            return textSegments.map(\.layout.string).joined()
        }
    }

    var selectableLength: Int {
        switch self {
        case .code(let code, _), .codeBody(let code): code.utf16Length
        default: textSegments.last?.end ?? 0
        }
    }

    /// The text offset closest to `point` (row coordinates).
    func textOffset(closestTo point: CGPoint) -> Int? {
        let segments = textSegments
        guard !segments.isEmpty else { return nil }
        let segment =
            segments.first { $0.hitRect?.contains(point) == true }
            ?? segments.min { distance(point, $0) < distance(point, $1) }
        guard let segment else { return nil }
        let local = CGPoint(x: point.x - segment.origin.x, y: point.y - segment.origin.y)
        return segment.start + segment.layout.offset(closestTo: local)
    }

    /// Strict text hit-test (returns nil on empty margins/whitespace).
    func strictTextOffset(at point: CGPoint) -> Int? {
        guard
            let segment = textSegments.first(where: { segment in
                (segment.hitRect ?? CGRect(origin: segment.origin, size: segment.layout.size)).contains(point)
            })
        else { return nil }
        let segmentLocal = CGPoint(x: point.x - segment.origin.x, y: point.y - segment.origin.y)
        if segment.hitRect == nil {
            guard let lineIdx = segment.layout.lineIndex(nearestY: segmentLocal.y) else { return nil }
            let line = segment.layout.lines[lineIdx]
            guard segmentLocal.y >= line.top, segmentLocal.y <= line.bottom,
                segmentLocal.x >= line.x, segmentLocal.x <= line.x + line.width
            else { return nil }
        }
        return segment.start + segment.layout.offset(closestTo: segmentLocal)
    }

    func containsSelectablePoint(_ point: CGPoint) -> Bool {
        textSegments.contains { segment in
            (segment.hitRect ?? CGRect(origin: segment.origin, size: segment.layout.size)).contains(point)
        }
    }

    func caretRect(for utf16Offset: Int) -> CGRect? {
        for segment in textSegments where utf16Offset >= segment.start && utf16Offset <= segment.end {
            let local = utf16Offset - segment.start
            if let rect = segment.layout.caretRect(for: local) {
                return rect.offsetBy(dx: segment.origin.x, dy: segment.origin.y)
            }
        }
        return nil
    }

    /// Whether the paragraph holding `utf16Offset` runs right to left.
    func isRightToLeft(at utf16Offset: Int) -> Bool {
        for segment in textSegments where utf16Offset >= segment.start && utf16Offset <= segment.end {
            if let isRightToLeft = segment.layout.isRightToLeft(at: utf16Offset - segment.start) {
                return isRightToLeft
            }
        }
        return false
    }

    func selectionRects(for range: Range<Int>) -> [CGRect] {
        var rects: [CGRect] = []
        for segment in textSegments {
            let from = max(range.lowerBound, segment.start)
            let to = min(range.upperBound, segment.end)
            guard from < to else { continue }
            for rect in segment.layout.selectionRects(for: (from - segment.start)..<(to - segment.start)) {
                rects.append(rect.offsetBy(dx: segment.origin.x, dy: segment.origin.y))
            }
        }
        return rects
    }

    func link(at point: CGPoint) -> URL? {
        for segment in textSegments where segment.hitRect.map({ $0.contains(point) }) ?? true {
            let local = CGPoint(x: point.x - segment.origin.x, y: point.y - segment.origin.y)
            if let url = segment.layout.link(at: local) { return url }
        }
        return nil
    }

    private func distance(_ point: CGPoint, _ segment: TextSegment) -> CGFloat {
        let box =
            segment.hitRect
            ?? CGRect(origin: segment.origin, size: segment.layout.size)
        let dx = max(box.minX - point.x, 0, point.x - box.maxX)
        let dy = max(box.minY - point.y, 0, point.y - box.maxY)
        return dy * 1_000 + dx
    }
}
