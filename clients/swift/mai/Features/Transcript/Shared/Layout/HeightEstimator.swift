import CoreGraphics
import Foundation

/// A row's height before its layout lands, from its kind and precomputed text
/// size (`TranscriptRow.metrics`) at the column width — strictly O(1), never
/// scanning text on the main thread. Close is enough: every correction is
/// anchored (PLAN 3.1 rule 5), and rows near the viewport are measured before
/// they show.
nonisolated enum HeightEstimator {
    static func estimate(_ row: TranscriptRow, width: CGFloat, style: TextStyle) -> CGFloat {
        estimate(row.kind, metrics: row.metrics, width: width, style: style)
    }

    static func estimate(
        _ kind: TranscriptRowKind, metrics: TextMetrics? = nil, width: CGFloat, style: TextStyle
    ) -> CGFloat {
        let body = style.font(.body)
        let lineHeight = body.lineHeight + style.lineSpacing
        let characterWidth = body.pointSize * 0.52
        let perLine = Double(max(12, width / characterWidth))
        let metrics = metrics ?? TextMetrics(kind)
        let height: CGFloat
        switch kind {
        case .markdownBlock(let block, let position, let context):
            let spacing = context.spacingAbove(position, style: style) + context.spacingBelow(position, style: style)
            if context.presentation == .userBubble {
                let inner = Double(max(12, (width - 2 * style.bubbleHorizontalPadding) / characterWidth))
                let topPad = context.joinsAbove ? 0 : style.bubbleVerticalPadding
                let bottomPad = context.joinsBelow ? 0 : style.bubbleVerticalPadding
                height = spacing + topPad + bottomPad + CGFloat(metrics.wrappedLines(perLine: inner)) * lineHeight
            } else if !context.isNestedInContainer {
                switch block {
                case .code:
                    height = spacing + CodeLayout.height(lines: metrics.lines, style: style)
                case .table(let table):
                    let rows = CGFloat(table.rows.count + 1)
                    height =
                        spacing + style.tableToolbarHeight
                        + rows * (lineHeight + 2 * style.tableCellVerticalPadding + 1)
                default:
                    height = spacing + CGFloat(metrics.wrappedLines(perLine: perLine)) * lineHeight
                }
            } else {
                height = spacing + CGFloat(metrics.wrappedLines(perLine: perLine)) * lineHeight
            }
        case .userMessage:
            let inner = Double(max(12, (width - 2 * style.bubbleHorizontalPadding) / characterWidth))
            height =
                2 * style.messageVerticalInset + 2 * style.bubbleVerticalPadding
                + blockGaps(metrics, style) + CGFloat(metrics.wrappedLines(perLine: inner)) * lineHeight
        case .thought:
            height = 8 + blockGaps(metrics, style) + CGFloat(metrics.wrappedLines(perLine: perLine)) * lineHeight
        case .pendingMessage:
            // O(1) from byte length alone before the message is parsed off-main.
            height = 2 * style.messageVerticalInset + CGFloat(1 + Double(metrics.bytes) / perLine) * lineHeight
        case .notice:
            height = 36 + CGFloat(1 + Double(metrics.bytes) / perLine) * lineHeight
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

    /// Space between top-level blocks laid out inside one row.
    private static func blockGaps(_ metrics: TextMetrics, _ style: TextStyle) -> CGFloat {
        CGFloat(max(0, metrics.blocks - 1)) * style.blockSpacing
    }
}
