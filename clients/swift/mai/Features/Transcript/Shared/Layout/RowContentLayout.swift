import CoreGraphics
import Foundation

/// A row's laid-out content, in row coordinates (the column's top left).
nonisolated enum RowContentLayout: Sendable {
    case text(TextLayout, origin: CGPoint)
    /// A user message: its bubble (or chunk slice) and the text inside it.
    case bubble(TextLayout, frame: CGRect, textOrigin: CGPoint, position: TranscriptBlockPosition = .single)
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
    /// About how much memory the layout holds, which off-screen eviction
    /// budgets (Ghostty bounds scrollback in bytes, not lines, for the same
    /// reason: one line of a minified file holds megabytes of glyphs).
    var retainedBytes: Int {
        switch self {
        case .text(let layout, _), .bubble(let layout, _, _, _), .header(let layout, _, _), .notice(let layout, _, _):
            layout.retainedBytes
        case .code(let code, _), .codeBody(let code):
            code.body.retainedBytes + code.label.retainedBytes
        case .table(let table, _), .tableBody(let table):
            table.cells.reduce(0) { $0 + $1.layout.retainedBytes }
        case .actions, .empty:
            0
        }
    }

    /// Whether a code block carries its syntax colors.
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

    /// The theme of a code block's syntax colors, nil while plain.
    var colorsAreDark: Bool? {
        switch self {
        case .code(let layout, _), .codeBody(let layout): layout.colorsAreDark
        default: nil
        }
    }

    /// How far down from the row's top `RowPainter` paints into its bands:
    /// nothing for rows drawn only with layer shapes and controls, or whose
    /// whole grid is in a wide block's scroller; only the header for a wide
    /// code block, whose body is in its scroller.
    func paintedHeight(drawsWideBody: Bool, rowHeight: CGFloat) -> CGFloat {
        switch self {
        case .actions, .empty:
            0
        case .table where !drawsWideBody:
            0
        case .code(let code, let frame) where !drawsWideBody:
            code.headerHeight > 0 ? min(rowHeight, ceil(frame.minY + code.headerHeight)) : 0
        default:
            rowHeight
        }
    }

    /// The body of a code block or table wider than the row, which scrolls
    /// sideways in a scroller of its own; nil for everything else.
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
