import CoreGraphics
import Foundation

/// Lays one row out: the function every layout task runs, and the
/// synchronous fallback runs on the main thread for a row about to show
/// without a layout (PLAN D3). Pure and thread-safe.
nonisolated enum RowLayoutBuilder {
    static func layout(_ request: RowLayoutRequest) -> RowLayout {
        let style = request.style
        let width = request.key.width
        let (height, content) = body(
            request.kind, width: width, style: style, codeColors: request.codeColors,
            previousCode: request.previousCode)
        return RowLayout(rowID: request.rowID, key: request.key, height: max(1, ceil(height)), content: content)
    }

    private static func body(
        _ kind: TranscriptRowKind, width: CGFloat, style: TextStyle, codeColors: CodeColors?,
        previousCode: CodeLayout?
    ) -> (CGFloat, RowContentLayout) {
        switch kind {
        case .markdownBlock(let block, let position):
            let top = position.spacingAbove(style)
            let bottom = position.spacingBelow(style)
            switch block {
            case .code(let language, let code):
                let layout =
                    previousCode.flatMap { previous in
                        previous.code == code && previous.colors?.code == codeColors?.code
                            && previous.colorsAreDark == codeColors?.isDark
                            ? previous.resized(toWidth: width) : nil
                    }
                    ?? CodeLayout.make(
                        code: code, language: language, colors: codeColors, width: width, style: style)
                return (
                    top + layout.size.height + bottom,
                    .code(layout, frame: CGRect(origin: CGPoint(x: 0, y: top), size: layout.size))
                )
            case .table(let table):
                let layout = TableLayout.make(table, width: width, style: style)
                return (
                    top + layout.size.height + bottom,
                    .table(layout, frame: CGRect(origin: CGPoint(x: 0, y: top), size: layout.size))
                )
            default:
                let layout = prose([block], width: width, style: style)
                return (top + layout.size.height + bottom, .text(layout, origin: CGPoint(x: 0, y: top)))
            }
        case .userMessage(let source):
            let inner = max(1, width - 2 * style.bubbleHorizontalPadding)
            let layout = prose(MarkdownPlanner.blocks(from: source), width: inner, style: style)
            let bubbleWidth = min(width, ceil(layout.size.width) + 2 * style.bubbleHorizontalPadding)
            let bubble = CGRect(
                x: width - bubbleWidth, y: style.messageVerticalInset, width: bubbleWidth,
                height: layout.size.height + 2 * style.bubbleVerticalPadding)
            return (
                bubble.height + 2 * style.messageVerticalInset,
                .bubble(
                    layout, frame: bubble,
                    textOrigin: CGPoint(
                        x: bubble.minX + style.bubbleHorizontalPadding, y: bubble.minY + style.bubbleVerticalPadding))
            )
        case .pendingMessage(let source):
            // Only a row the controller could not parse in time gets here;
            // it shows as written until its blocks replace it.
            let layout = prose(
                [.paragraph([MarkdownInline(text: source)])], width: width, style: style)
            let top = style.messageVerticalInset
            return (top + layout.size.height + top, .text(layout, origin: CGPoint(x: 0, y: top)))
        case .thought(let text):
            let layout = plain(text, role: .body, color: .secondary, width: width, style: style)
            return (layout.size.height + 8, .text(layout, origin: CGPoint(x: 0, y: 4)))
        case .activity(let summary):
            let layout = plain(summary, role: .callout, color: .secondary, width: width, style: style)
            return (layout.size.height + 8, .text(layout, origin: CGPoint(x: 0, y: 4)))
        case .turnHeader(let header):
            let chevron = header.isRunning ? "" : (header.isExpanded ? "  ⌄" : "  ›")
            let layout = plain(header.title + chevron, role: .callout, color: .secondary, width: width, style: style)
            let dividerY = 6 + layout.size.height + 8
            return (dividerY + 1 + 2, .header(layout, origin: CGPoint(x: 0, y: 6), dividerY: dividerY))
        case .turnActions(let turnID, let replyMarkdown):
            return (
                RowAccessory.size + 6,
                .actions(turnID: turnID, replyMarkdown: replyMarkdown, origin: CGPoint(x: -4, y: 2))
            )
        case .working(let phrase):
            let layout = plain("✦  " + phrase, role: .callout, color: .secondary, width: width, style: style)
            return (layout.size.height + 16, .text(layout, origin: CGPoint(x: 0, y: 8)))
        case .notice(let title, let text):
            var styled = AttributedTextBuilder.plain(title, role: .callout, color: .primary, bold: true, style: style)
            if let text, !text.isEmpty {
                styled.append("\n" + text, font: style.font(.callout), style: TextRunStyle(color: .secondary))
            }
            let layout = TextLayoutEngine.layout(
                styled, width: max(1, width - 24), options: .init(lineSpacing: style.lineSpacing))
            let frame = CGRect(x: 0, y: 6, width: width, height: layout.size.height + 24)
            return (frame.height + 12, .notice(layout, frame: frame, textOrigin: CGPoint(x: 12, y: 18)))
        }
    }

    static func prose(_ blocks: [MarkdownBlock], width: CGFloat, style: TextStyle) -> TextLayout {
        TextLayoutEngine.layout(
            AttributedTextBuilder.build(blocks, style: style), width: width,
            options: .init(lineSpacing: style.lineSpacing, quoteBarWidth: style.quoteBarWidth))
    }

    private static func plain(
        _ text: String, role: TextStyle.FontRole, color: TextColor, width: CGFloat, style: TextStyle
    ) -> TextLayout {
        TextLayoutEngine.layout(
            AttributedTextBuilder.plain(text, role: role, color: color, style: style), width: width,
            options: .init(lineSpacing: style.lineSpacing))
    }
}
