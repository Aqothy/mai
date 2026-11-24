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
        let height: CGFloat
        switch kind {
        case .markdownBlock(let block, let position):
            let spacing = position.spacingAbove(style) + position.spacingBelow(style)
            switch block {
            case .code(_, let code):
                height = spacing + CodeLayout.height(for: code, style: style)
            case .table(let table):
                let rows = CGFloat(table.rows.count + 1)
                height =
                    spacing + style.tableToolbarHeight
                    + rows * (lineHeight + 2 * style.tableCellVerticalPadding + 1)
            default:
                height = spacing + lines(of: block, perLine: charactersPerLine) * lineHeight
            }
        case .userMessage(let source):
            let inner = max(12, (width - 2 * style.bubbleHorizontalPadding) / (body.pointSize * 0.52))
            height =
                2 * (style.messageVerticalInset + style.bubbleVerticalPadding)
                + scanLines(source, perLine: inner).lines * lineHeight
        case .pendingMessage(let source):
            let scan = scanLines(source, perLine: charactersPerLine)
            height = 2 * style.messageVerticalInset + scan.lines * lineHeight + scan.blocks * style.blockSpacing
        case .thought(let text):
            height = 8 + scanLines(text, perLine: charactersPerLine).lines * lineHeight
        case .notice(_, let text):
            height = 36 + (1 + scanLines(text ?? "", perLine: charactersPerLine).lines) * lineHeight
        case .activity:
            height = 8 + style.font(.callout).lineHeight
        case .working:
            height = 16 + style.font(.callout).lineHeight
        case .turnHeader:
            height = 17 + style.font(.callout).lineHeight
        case .turnActions:
            height = RowAccessory.size + 6
        }
        return max(1, ceil(height))
    }

    /// Single-pass UTF-8 scan counting wrapped lines and blank-line-separated
    /// blocks without allocating substrings. Handles LF and CRLF.
    private static func scanLines(_ text: String, perLine: CGFloat) -> (lines: CGFloat, blocks: CGFloat) {
        var totalLines: CGFloat = 0
        var blocks: CGFloat = 1
        var lineBytes = 0
        var previousLineWasBlank = false
        for byte in text.utf8 {
            if byte == 0x0A {
                totalLines += max(1, ceil(CGFloat(lineBytes) / perLine))
                let isBlank = lineBytes == 0
                if isBlank && !previousLineWasBlank { blocks += 1 }
                previousLineWasBlank = isBlank
                lineBytes = 0
            } else if byte != 0x0D {
                lineBytes += 1
            }
        }
        totalLines += max(1, ceil(CGFloat(lineBytes) / perLine))
        return (totalLines, blocks)
    }

    private static func lines(of block: MarkdownBlock, perLine: CGFloat) -> CGFloat {
        switch block {
        case .paragraph(let inlines), .heading(_, let inlines):
            var totalBytes = 0
            var totalLines: CGFloat = 0
            for inline in inlines {
                for byte in inline.text.utf8 {
                    if byte == 0x0A {
                        totalLines += max(1, ceil(CGFloat(totalBytes) / perLine))
                        totalBytes = 0
                    } else if byte != 0x0D {
                        totalBytes += 1
                    }
                }
            }
            return totalLines + max(1, ceil(CGFloat(totalBytes) / perLine))
        case .list(let list):
            return list.items.reduce(0) { sum, item in
                sum + item.blocks.reduce(0) { $0 + lines(of: $1, perLine: perLine) }
            }
        case .quote(let blocks):
            return blocks.reduce(0) { $0 + lines(of: $1, perLine: perLine) }
        case .code(_, let code):
            return scanLines(code, perLine: perLine).lines
        case .table:
            return 1
        case .rule:
            return 1
        }
    }
}
