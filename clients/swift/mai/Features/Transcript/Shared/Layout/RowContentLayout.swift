import CoreGraphics
import Foundation

/// A row's laid-out content, in row coordinates (the column's top left).
nonisolated enum RowContentLayout: Sendable {
    case text(TextLayout, origin: CGPoint)
    /// A user message: its bubble and the text inside it.
    case bubble(TextLayout, frame: CGRect, textOrigin: CGPoint)
    case code(CodeLayout, frame: CGRect)
    /// A wide code block's lines alone, in its horizontal scroller.
    case codeBody(CodeLayout)
    /// A wide table's grid alone, in its horizontal scroller.
    case tableBody(TableLayout)
    case table(TableLayout, frame: CGRect)
    /// A turn header's title and the divider under it.
    case header(TextLayout, origin: CGPoint, dividerY: CGFloat)
    case notice(TextLayout, frame: CGRect, textOrigin: CGPoint)
    /// The actions under a finished turn, from `origin`: copy the reply's
    /// Markdown (resolved lazily on click when `hasReply` is true) and fork.
    case actions(turnID: String, hasReply: Bool, origin: CGPoint)
    case empty
}

nonisolated extension RowContentLayout {
    /// Memory held by this layout (prepared segments + fitted lines).
    var retainedBytes: Int {
        switch self {
        case .text(let layout, _), .bubble(let layout, _, _), .header(let layout, _, _), .notice(let layout, _, _):
            layout.retainedBytes
        case .code(let code, _), .codeBody(let code):
            code.retainedBytes
        case .table(let table, _), .tableBody(let table):
            table.cells.reduce(0) { $0 + $1.layout.retainedBytes }
        case .actions, .empty:
            0
        }
    }

    var isHighlighted: Bool {
        switch self {
        case .code(let layout, _), .codeBody(let layout): layout.isHighlighted
        default: false
        }
    }

    var codeLayout: CodeLayout? {
        switch self {
        case .code(let layout, _), .codeBody(let layout): layout
        default: nil
        }
    }

    var colorsAreDark: Bool? {
        switch self {
        case .code(let layout, _), .codeBody(let layout): layout.colorsAreDark
        default: nil
        }
    }

    /// Tightest integer rect (in row coordinates) that `RowPainter` draws
    /// pixels into, clamped to `(0, 0, rowWidth, rowHeight)`.
    func paintedBounds(drawsWideBody: Bool, rowWidth: CGFloat, rowHeight: CGFloat) -> CGRect {
        let rowRect = CGRect(x: 0, y: 0, width: max(0, rowWidth), height: max(0, rowHeight))
        guard !rowRect.isEmpty else { return .zero }
        func clamp(_ rect: CGRect) -> CGRect {
            var clipped = rect.integral.intersection(rowRect)
            guard !clipped.isNull, !clipped.isEmpty else { return .zero }
            if clipped.maxX > RowLayer.bandWidth {
                clipped = CGRect(x: 0, y: clipped.minY, width: clipped.maxX, height: clipped.height)
            }
            if clipped.maxY > RowLayer.bandHeight {
                clipped = CGRect(x: clipped.minX, y: 0, width: clipped.width, height: clipped.maxY)
            }
            return clipped
        }
        func textRect(_ layout: TextLayout, at origin: CGPoint) -> CGRect {
            guard !layout.lines.isEmpty else { return .zero }
            if layout.prepared.hasParagraphDecorations {
                return clamp(CGRect(x: 0, y: origin.y - 4, width: rowWidth, height: layout.size.height + 8))
            }
            let minLineX: CGFloat =
                if layout.lines.count <= 32 {
                    layout.lines.reduce(CGFloat.infinity) { min($0, $1.x) }
                } else {
                    0
                }
            let rect = CGRect(
                x: origin.x + minLineX - 4, y: origin.y - 2,
                width: max(0, layout.size.width - minLineX) + 8, height: layout.size.height + 4)
            return clamp(rect)
        }
        switch self {
        case .actions, .empty:
            return .zero
        case .text(let layout, let origin):
            return textRect(layout, at: origin)
        case .bubble(let layout, _, let textOrigin):
            return textRect(layout, at: textOrigin)
        case .notice(let layout, let frame, let textOrigin):
            return textRect(layout, at: CGPoint(x: frame.minX + textOrigin.x, y: textOrigin.y))
        case .header:
            return rowRect
        case .code(let code, let frame):
            let labelRect: CGRect =
                code.headerHeight > 0
                ? textRect(code.label, at: CGPoint(x: frame.minX + code.bodyOrigin.x, y: frame.minY + code.labelTop))
                : .zero
            guard drawsWideBody else { return labelRect }
            let bodyClip = CGRect(
                x: frame.minX, y: frame.minY + code.headerHeight,
                width: frame.width, height: max(0, frame.height - code.headerHeight))
            let bodyOrigin = CGPoint(x: frame.minX + code.bodyOrigin.x, y: frame.minY + code.bodyOrigin.y)
            let bodyRect = textRect(code.body, at: bodyOrigin).intersection(bodyClip)
            if labelRect.isEmpty { return bodyRect.isNull ? .zero : clamp(bodyRect) }
            if bodyRect.isNull || bodyRect.isEmpty { return labelRect }
            return clamp(labelRect.union(bodyRect))
        case .codeBody, .tableBody:
            return rowRect
        case .table(let table, let frame):
            guard drawsWideBody else { return .zero }
            return clamp(
                CGRect(
                    x: frame.minX, y: frame.minY + table.toolbarHeight,
                    width: min(frame.width, table.gridSize.width + 4),
                    height: table.gridSize.height + 1))
        }
    }

    var wideBody: WideBlockBody? {
        switch self {
        case .code(let code, let frame) where code.isWiderThanBlock:
            WideBlockBody(
                content: .codeBody(code),
                frame: CGRect(
                    x: frame.minX, y: frame.minY + code.headerHeight, width: frame.width,
                    height: max(1, frame.height - code.headerHeight)),
                contentWidth: code.contentWidth)
        case .table(let table, let frame) where table.isWiderThanBlock:
            WideBlockBody(
                content: .tableBody(table),
                frame: CGRect(
                    x: frame.minX, y: frame.minY + table.toolbarHeight, width: frame.width,
                    height: max(1, table.gridSize.height)),
                contentWidth: table.gridSize.width)
        default:
            nil
        }
    }
}
