import CoreGraphics
import Foundation

/// Lays one row out on any thread (`LayoutQueue`, `TranscriptStreamWorker`, or
/// synchronous in-frame resize/draw). Pure and thread-safe.
nonisolated enum RowLayoutBuilder {
    static func layout(_ request: RowLayoutRequest) -> RowLayout {
        let style = request.style
        let width = request.key.width
        let (height, content) = body(
            request.kind, width: width, style: style, codeColors: request.codeColors, previous: request.previous)
        return RowLayout(rowID: request.rowID, key: request.key, height: max(1, ceil(height)), content: content)
    }

    private static func body(
        _ kind: TranscriptRowKind, width: CGFloat, style: TextStyle, codeColors: CodeColors?,
        previous: (kind: TranscriptRowKind, layout: RowLayout)?
    ) -> (CGFloat, RowContentLayout) {
        let sameStyle = previous?.layout.key.styleVersion == style.version
        let sameKind = sameStyle && previous?.kind == kind
        switch kind {
        case .markdownBlock(let block, let position):
            let top = position.spacingAbove(style)
            let bottom = position.spacingBelow(style)
            switch block {
            case .code(let language, let code):
                let prevCode = sameStyle ? previous?.layout.content.codeLayout : nil
                let display = CodeLayout.displayName(language)
                let layout: CodeLayout
                if let prevCode, prevCode.code == code,
                    prevCode.label.string == display,
                    prevCode.colors?.code == codeColors?.code, prevCode.colorsAreDark == codeColors?.isDark
                {
                    layout = prevCode.resized(toWidth: width)
                } else {
                    layout = CodeLayout.make(
                        code: code, language: language, colors: codeColors, width: width, style: style,
                        previous: prevCode)
                }
                return (
                    top + layout.size.height + bottom,
                    .code(layout, frame: CGRect(origin: CGPoint(x: 0, y: top), size: layout.size))
                )
            case .table(let table):
                let prevTable: TableLayout?
                if sameStyle, case .table(let existing, _) = previous?.layout.content {
                    prevTable = existing
                } else {
                    prevTable = nil
                }
                let layout: TableLayout
                if let prevTable, prevTable.source == table {
                    layout = prevTable.resized(toWidth: width)
                } else {
                    layout = TableLayout.make(table, width: width, style: style, previous: prevTable)
                }
                return (
                    top + layout.size.height + bottom,
                    .table(layout, frame: CGRect(origin: CGPoint(x: 0, y: top), size: layout.size))
                )
            default:
                if sameKind, case .text(let prevText, _) = previous?.layout.content {
                    let layout = prevText.resized(toWidth: width)
                    return (top + layout.size.height + bottom, .text(layout, origin: CGPoint(x: 0, y: top)))
                }
                let prevPrepared: PreparedText? =
                    if sameStyle, case .text(let prevText, _) = previous?.layout.content {
                        prevText.prepared
                    } else {
                        nil
                    }
                let layout = prose([block], width: width, style: style, previous: prevPrepared)
                return (top + layout.size.height + bottom, .text(layout, origin: CGPoint(x: 0, y: top)))
            }
        case .userMessage(let blocks):
            let inner = max(1, width - 2 * style.bubbleHorizontalPadding)
            let layout: TextLayout
            if sameKind, case .bubble(let prevText, _, _) = previous?.layout.content {
                layout = prevText.resized(toWidth: inner)
            } else {
                let prevPrepared: PreparedText? =
                    if sameStyle, case .bubble(let prevText, _, _) = previous?.layout.content {
                        prevText.prepared
                    } else {
                        nil
                    }
                layout = prose(blocks, width: inner, style: style, alignsRTLToWidth: false, previous: prevPrepared)
            }
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
        case .pendingMessage:
            return (HeightEstimator.estimate(kind, width: width, style: style), .empty)
        case .thought(let blocks):
            let layout: TextLayout
            if sameKind, case .text(let prevText, _) = previous?.layout.content {
                layout = prevText.resized(toWidth: width)
            } else {
                let prevPrepared: PreparedText? =
                    if sameStyle, case .text(let prevText, _) = previous?.layout.content {
                        prevText.prepared
                    } else {
                        nil
                    }
                layout = prose(blocks, width: width, style: style, color: .secondary, previous: prevPrepared)
            }
            return (layout.size.height + 8, .text(layout, origin: CGPoint(x: 0, y: 4)))
        case .activity(let summary):
            let layout: TextLayout
            if sameKind, case .text(let prevText, _) = previous?.layout.content {
                layout = prevText.resized(toWidth: width)
            } else {
                layout = plain(summary, role: .callout, color: .secondary, width: width, style: style)
            }
            return (layout.size.height + 8, .text(layout, origin: CGPoint(x: 0, y: 4)))
        case .turnHeader(let header):
            let layout: TextLayout
            if sameKind, case .header(let prevText, _, _) = previous?.layout.content {
                layout = prevText.resized(toWidth: width)
            } else {
                let chevron = header.isRunning ? "" : (header.isExpanded ? "  ⌄" : "  ›")
                layout = plain(header.title + chevron, role: .callout, color: .secondary, width: width, style: style)
            }
            let dividerY = 6 + layout.size.height + 8
            return (dividerY + 1 + 2, .header(layout, origin: CGPoint(x: 0, y: 6), dividerY: dividerY))
        case .turnActions(let turnID, let hasReply):
            return (
                RowAccessory.size + 6,
                .actions(turnID: turnID, hasReply: hasReply, origin: CGPoint(x: -4, y: 2))
            )
        case .working(let phrase):
            let layout: TextLayout
            if sameKind, case .text(let prevText, _) = previous?.layout.content {
                layout = prevText.resized(toWidth: width)
            } else {
                layout = plain("✦  " + phrase, role: .callout, color: .secondary, width: width, style: style)
            }
            return (layout.size.height + 16, .text(layout, origin: CGPoint(x: 0, y: 8)))
        case .notice(let title, let text):
            let inner = max(1, width - 24)
            let layout: TextLayout
            if sameKind, case .notice(let prevText, _, _) = previous?.layout.content {
                layout = prevText.resized(toWidth: inner)
            } else {
                var styled = AttributedTextBuilder.plain(title, role: .callout, color: .primary, bold: true, style: style)
                if let text, !text.isEmpty {
                    styled.append("\n" + text, font: style.font(.callout), style: TextRunStyle(color: .secondary))
                }
                layout = TextLayoutEngine.layout(styled, width: inner, options: .init(lineSpacing: style.lineSpacing))
            }
            let frame = CGRect(x: 0, y: 6, width: width, height: layout.size.height + 24)
            return (frame.height + 12, .notice(layout, frame: frame, textOrigin: CGPoint(x: 12, y: 18)))
        }
    }

    static func prose(
        _ blocks: [MarkdownBlock], width: CGFloat, style: TextStyle, color: TextColor = .primary,
        alignsRTLToWidth: Bool = true, previous: PreparedText? = nil
    ) -> TextLayout {
        TextLayoutEngine.layout(
            AttributedTextBuilder.build(blocks, style: style, color: color), width: width,
            options: .init(
                lineSpacing: style.lineSpacing, quoteBarWidth: style.quoteBarWidth,
                alignsRTLToWidth: alignsRTLToWidth),
            previous: previous)
    }

    private static func plain(
        _ text: String, role: TextStyle.FontRole, color: TextColor, width: CGFloat, style: TextStyle
    ) -> TextLayout {
        TextLayoutEngine.layout(
            AttributedTextBuilder.plain(text, role: role, color: color, style: style), width: width,
            options: .init(lineSpacing: style.lineSpacing))
    }
}
