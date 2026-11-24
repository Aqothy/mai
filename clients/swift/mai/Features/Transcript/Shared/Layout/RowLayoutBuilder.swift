import CoreGraphics
import Foundation

/// Lays one row out on a background worker (`LayoutQueue` or
/// `TranscriptStreamWorker`). Pure and thread-safe.
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
        switch kind {
        case .markdownBlock(let block, let position):
            let isCode: Bool
            if case .code = block { isCode = true } else { isCode = false }
            let top = position.spacingAbove(style, forCode: isCode)
            let bottom = position.spacingBelow(style)
            switch block {
            case .code(let language, let code):
                let prevCode = sameStyle ? previous?.layout.content.codeLayout : nil
                let display = position.joinsAbove ? "" : CodeLayout.displayName(language)
                let layout: CodeLayout
                if let prevCode, prevCode.code == code, prevCode.position == position,
                    prevCode.label.string == display,
                    prevCode.colors?.code == codeColors?.code, prevCode.colorsAreDark == codeColors?.isDark
                {
                    layout = prevCode.resized(toWidth: width)
                } else {
                    layout = CodeLayout.make(
                        code: code, language: language, colors: codeColors, width: width, style: style,
                        position: position, previous: prevCode)
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
            case .paragraph(let inlines):
                if sameStyle, let previous, previous.layout.key.width == width,
                    case .markdownBlock(.paragraph(let oldInlines), _) = previous.kind,
                    case .text(let prevText, _) = previous.layout.content,
                    !prevText.hasComplexBiDi
                {
                    let unchanged = Self.commonUTF16Prefix(oldInlines, inlines)
                    var keepCount = 0
                    while keepCount < prevText.lines.count, prevText.lines[keepCount].range.upperBound <= unchanged {
                        keepCount += 1
                    }
                    keepCount = max(0, keepCount - 1)
                    if keepCount >= 2, keepCount < prevText.lines.count {
                        let resumeLine = prevText.lines[keepCount]
                        let resumeUTF16 = resumeLine.range.lowerBound
                        let keptLinkCount =
                            prevText.runs[..<resumeLine.runs.lowerBound].compactMap(\.linkIndex).max().map { $0 + 1 }
                            ?? 0
                        let (suffix, links) = AttributedTextBuilder.paragraphSuffix(
                            inlines, fromUTF16: resumeUTF16, existingLinks: Array(prevText.links.prefix(keptLinkCount)),
                            style: style)
                        if suffix.length > 0 {
                            let prevUTF16 = prevText.string.utf16
                            let cutIdx = prevUTF16.index(prevUTF16.startIndex, offsetBy: resumeUTF16)
                            let fullString = String(prevText.string[..<cutIdx]) + suffix.string.string
                            if let layout = TextLayoutEngine.layoutSuffix(
                                fullString: fullString, suffix: suffix, links: links, width: width,
                                options: .init(lineSpacing: style.lineSpacing, quoteBarWidth: style.quoteBarWidth),
                                appendingTo: prevText, keepCount: keepCount)
                            {
                                return (top + layout.size.height + bottom, .text(layout, origin: CGPoint(x: 0, y: top)))
                            }
                        }
                    }
                }
                let layout = prose([block], width: width, style: style)
                return (top + layout.size.height + bottom, .text(layout, origin: CGPoint(x: 0, y: top)))
            default:
                let layout = prose([block], width: width, style: style)
                return (top + layout.size.height + bottom, .text(layout, origin: CGPoint(x: 0, y: top)))
            }
        case .userMessage(let source, let position):
            let inner = max(1, width - 2 * style.bubbleHorizontalPadding)
            let isChunked = position.joinsAbove || position.joinsBelow
            let layout =
                isChunked
                ? plain(source, role: .body, color: .primary, width: inner, style: style)
                : prose(MarkdownPlanner.blocks(from: source), width: inner, style: style)
            let bubbleWidth =
                isChunked ? width : min(width, ceil(layout.size.width) + 2 * style.bubbleHorizontalPadding)
            let topInset = position.joinsAbove ? 0 : style.messageVerticalInset
            let bottomInset = position.joinsBelow ? 0 : style.messageVerticalInset
            let topPad = position.joinsAbove ? style.lineSpacing : style.bubbleVerticalPadding
            let bottomPad = position.joinsBelow ? 0 : style.bubbleVerticalPadding
            let textHeight = isChunked && source.isEmpty ? style.font(.body).lineHeight : layout.size.height
            let bubble = CGRect(
                x: width - bubbleWidth, y: topInset, width: bubbleWidth,
                height: textHeight + topPad + bottomPad)
            return (
                topInset + bubble.height + bottomInset,
                .bubble(
                    layout, frame: bubble,
                    textOrigin: CGPoint(x: bubble.minX + style.bubbleHorizontalPadding, y: bubble.minY + topPad),
                    position: position)
            )
        case .pendingMessage:
            // Pending messages are parsed off-main and spliced into their
            // Markdown block rows; never lay out raw Markdown text.
            return (HeightEstimator.estimate(kind, width: width, style: style), .empty)
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
        case .turnActions(let turnID, let hasReply):
            return (
                RowAccessory.size + 6,
                .actions(turnID: turnID, hasReply: hasReply, origin: CGPoint(x: -4, y: 2))
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

    /// Exact UTF-16 length of the identical prefix of two inline arrays (same
    /// text, style, and link), used to keep finished lines during streaming.
    private static func commonUTF16Prefix(_ old: [MarkdownInline], _ new: [MarkdownInline]) -> Int {
        var total = 0
        let shared = min(old.count, new.count)
        for index in 0..<shared {
            let a = old[index]
            let b = new[index]
            guard a.style == b.style, a.link == b.link else { break }
            if a.text == b.text {
                total += a.text.utf16.count
                continue
            }
            if b.text.hasPrefix(a.text) {
                total += a.text.utf16.count
            } else {
                var aIdx = a.text.utf16.startIndex
                var bIdx = b.text.utf16.startIndex
                while aIdx < a.text.utf16.endIndex, bIdx < b.text.utf16.endIndex, a.text.utf16[aIdx] == b.text.utf16[bIdx] {
                    total += 1
                    a.text.utf16.formIndex(after: &aIdx)
                    b.text.utf16.formIndex(after: &bIdx)
                }
            }
            break
        }
        return total
    }
}
