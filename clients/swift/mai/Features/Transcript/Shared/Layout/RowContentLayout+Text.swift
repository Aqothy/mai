import CoreGraphics
import Foundation

/// A row's selectable text and how it maps to points (PLAN 5): every kind
/// that shows text gives its laid-out segments, so prose, code, tables and
/// messages all select through the same few functions. Whether a row's text
/// is selectable at all is the row kind's call (`TranscriptRowKind.isSelectable`).
nonisolated extension RowContentLayout {
    /// The laid-out pieces of the row's text, in reading order.
    var textSegments: [TextSegment] {
        switch self {
        case .text(let layout, let origin):
            return [TextSegment(layout: layout, origin: origin, start: 0, hitRect: nil)]
        case .bubble(let layout, _, let textOrigin, _, _):
            return [TextSegment(layout: layout, origin: textOrigin, start: 0, hitRect: nil)]
        case .notice(let layout, let frame, let textOrigin):
            return [
                TextSegment(
                    layout: layout, origin: CGPoint(x: frame.minX + textOrigin.x, y: textOrigin.y), start: 0,
                    hitRect: nil)
            ]
        case .code(let code, let frame):
            guard let body = code.materializedBody else { return [] }
            return [
                TextSegment(
                    layout: body,
                    origin: CGPoint(x: frame.minX + code.bodyOrigin.x, y: frame.minY + code.bodyOrigin.y), start: 0,
                    hitRect: nil)
            ]
        case .codeBody(let code):
            guard let body = code.materializedBody else { return [] }
            return [TextSegment(layout: body, origin: CGPoint(x: code.bodyOrigin.x, y: 0), start: 0, hitRect: nil)]
        case .table(let table, let frame):
            return Self.cellSegments(table, gridOrigin: CGPoint(x: frame.minX, y: frame.minY + table.toolbarHeight))
        case .tableBody(let table):
            return Self.cellSegments(table, gridOrigin: .zero)
        case .header, .actions, .empty:
            return []
        }
    }

    /// A table's cells in reading order, a tab after each but a row's last
    /// and a newline after that: the text pastes into a spreadsheet.
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

    private var codeBodyOrigin: (code: CodeLayout, origin: CGPoint)? {
        switch self {
        case .code(let code, let frame):
            (code, CGPoint(x: frame.minX + code.bodyOrigin.x, y: frame.minY + code.bodyOrigin.y))
        case .codeBody(let code):
            (code, CGPoint(x: code.bodyOrigin.x, y: 0))
        default:
            nil
        }
    }

    var virtualCodeBody: (body: VirtualCodeBody, origin: CGPoint)? {
        guard let (code, origin) = codeBodyOrigin, case .virtualized(let body) = code.storage else { return nil }
        return (body, origin)
    }

    /// The text offset closest to `point` (row coordinates): in the segment
    /// whose box holds the point (a table cell), else the nearest segment.
    func textOffset(closestTo point: CGPoint) -> Int? {
        if let (code, origin) = codeBodyOrigin {
            return code.offset(closestTo: CGPoint(x: point.x - origin.x, y: point.y - origin.y))
        }
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
        if let (code, origin) = codeBodyOrigin {
            return code.strictOffset(at: CGPoint(x: point.x - origin.x, y: point.y - origin.y))
        }
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

    /// Whether `point` (row coordinates) lies over selectable text geometry
    /// (for macOS I-beam hover cursor).
    func containsSelectablePoint(_ point: CGPoint) -> Bool {
        if let (code, origin) = codeBodyOrigin {
            return CGRect(origin: origin, size: code.bodySize).contains(point)
        }
        return textSegments.contains { segment in
            (segment.hitRect ?? CGRect(origin: segment.origin, size: segment.layout.size)).contains(point)
        }
    }

    /// Caret rect in row coordinates for `utf16Offset`, if present.
    func caretRect(for utf16Offset: Int) -> CGRect? {
        if let (code, origin) = codeBodyOrigin {
            return code.caretRect(for: utf16Offset)?.offsetBy(dx: origin.x, dy: origin.y)
        }
        for segment in textSegments where utf16Offset >= segment.start && utf16Offset <= segment.end {
            let local = utf16Offset - segment.start
            guard let line = segment.layout.lines.last(where: { $0.range.lowerBound <= local }) else { continue }
            let x = line.caretOffsets[min(local - line.range.lowerBound, line.caretOffsets.count - 1)]
            return CGRect(x: segment.origin.x + x, y: segment.origin.y + line.top, width: 2, height: line.height)
        }
        return nil
    }

    /// Highlight rects for `range` of the row's text, in row coordinates.
    func selectionRects(for range: Range<Int>) -> [CGRect] {
        if let (code, origin) = codeBodyOrigin {
            return code.selectionRects(for: range).map { $0.offsetBy(dx: origin.x, dy: origin.y) }
        }
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

    /// The link at `point` (row coordinates), if any.
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
        // Rows of text read top to bottom: the vertical distance decides.
        return dy * 1_000 + dx
    }
}
