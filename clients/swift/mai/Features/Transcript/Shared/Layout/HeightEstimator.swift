import CoreGraphics
import Foundation

/// A row's height before its layout lands, from its kind and text length at
/// the column width. Close is enough: every correction is anchored (PLAN 3.1
/// rule 5), and rows near the viewport are measured before they show.
nonisolated enum HeightEstimator {
    static func estimate(_ kind: TranscriptRowKind, width: CGFloat, style: TextStyle) -> CGFloat {
        let body = style.font(.body)
        let lineHeight = body.lineHeight + style.lineSpacing
        let charactersPerLine = max(12, width / (body.pointSize * 0.52))
        func lines(_ text: String, width: CGFloat? = nil) -> CGFloat {
            let perLine = width.map { max(12, $0 / (body.pointSize * 0.52)) } ?? charactersPerLine
            var count: CGFloat = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                count += max(1, ceil(CGFloat(line.utf16.count) / perLine))
            }
            return count
        }
        switch kind {
        case .markdownBlock(let block, let position):
            let spacing = position.spacingAbove(style) + position.spacingBelow(style)
            switch block {
            case .code(_, let code):
                let count = CGFloat(code.reduce(into: 1) { $0 += $1 == "\n" ? 1 : 0 })
                return spacing + style.codeHeaderHeight + count * style.codeLineHeight + style.codeBottomInset
            case .table(let table):
                let rows = CGFloat(table.rows.count + 1)
                return spacing + style.tableToolbarHeight + rows * (lineHeight + 2 * style.tableCellVerticalPadding + 1)
            default:
                return spacing + lines(text(of: block)) * lineHeight
            }
        case .userMessage(let source):
            let inner = width - 2 * style.bubbleHorizontalPadding
            return 2 * (style.messageVerticalInset + style.bubbleVerticalPadding) + lines(source, width: inner) * lineHeight
        case .pendingMessage(let source):
            // Blocks add spacing between them; a blank line roughly marks one.
            let blocks = CGFloat(source.components(separatedBy: "\n\n").count)
            return 2 * style.messageVerticalInset + lines(source) * lineHeight + blocks * style.blockSpacing
        case .thought(let text):
            return 8 + lines(text) * lineHeight
        case .notice(_, let text):
            return 36 + (1 + lines(text ?? "")) * lineHeight
        case .activity, .working:
            return 8 + lineHeight
        case .turnHeader:
            return 17 + style.font(.callout).lineHeight
        case .turnActions:
            return RowAccessory.size + 6
        case .historyMarker:
            return 1
        }
    }

    private static func text(of block: MarkdownBlock) -> String {
        switch block {
        case .paragraph(let inlines), .heading(_, let inlines):
            return inlines.map(\.text).joined()
        case .list(let list):
            return list.items.map { $0.map(text(of:)).joined(separator: "\n") }.joined(separator: "\n")
        case .quote(let blocks):
            return blocks.map(text(of:)).joined(separator: "\n")
        case .code(_, let code):
            return code
        case .table:
            return ""
        case .rule(let spelling):
            return spelling
        }
    }
}
