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

    var selectableLength: Int { textSegments.last?.end ?? 0 }

    /// The text offset closest to `point` (row coordinates): in the segment
    /// whose box holds the point (a table cell), else the nearest segment.
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

    /// Highlight rects for `range` of the row's text, in row coordinates.
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
