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
    /// Markdown (empty when it has none) and the fork menu.
    case actions(turnID: String, replyMarkdown: String, origin: CGPoint)
    case empty
}

nonisolated extension RowContentLayout {
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
