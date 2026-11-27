import CoreGraphics
import Foundation

/// Markdown blocks to `StyledText`, with the chat's prose styling: body text,
/// the compact heading scale, list markers and indents, quote bars, inline
/// code in the code font, links underlined in the text color, thematic
/// breaks drawn as lines over their source spelling. Rich top-level blocks
/// (code, tables) have their own layouts; nested in a list or quote they
/// render inline here.
nonisolated struct AttributedTextBuilder {
    struct Environment {
        var indent: CGFloat = 0
        var quoteBars: [CGFloat] = []
        /// Lists this one is nested in: picks its bullet. Not derived from
        /// `indent`, which quotes also add to.
        var listDepth = 0
        var blockSpacing: CGFloat
    }

    private struct Inline {
        var role: TextStyle.FontRole = .body
        var bold = false
        var color: TextColor = .primary
    }

    let style: TextStyle
    let baseColor: TextColor
    private(set) var text: StyledText
    /// The font of the last text appended: the newline ending its paragraph
    /// takes it, since a line is as tall as its tallest run.
    private var lastFont: TranscriptFont?

    init(style: TextStyle, color: TextColor = .primary, existingLinks: [URL] = []) {
        self.style = style
        baseColor = color
        text = StyledText(existingLinks: existingLinks)
    }

    static func build(
        _ blocks: [MarkdownBlock], style: TextStyle, color: TextColor = .primary
    ) -> StyledText {
        var builder = AttributedTextBuilder(style: style, color: color)
        let root = Environment(blockSpacing: style.blockSpacing)
        for block in blocks { builder.append(block, environment: root) }
        return builder.text
    }

    /// Plain text in one font and color, its line breaks kept.
    static func plain(
        _ string: String, role: TextStyle.FontRole, color: TextColor, bold: Bool = false, style: TextStyle
    ) -> StyledText {
        var builder = AttributedTextBuilder(style: style)
        builder.beginParagraph(Environment(blockSpacing: 0))
        builder.appendRun(string, font: style.font(role, bold: bold), style: TextRunStyle(color: color))
        return builder.text
    }

    /// Quotes and lists recurse through here and `append(_:environment:)` for
    /// lists, a frame each per nesting level, so leaves and item markers are
    /// built out of line: a level costs only these small frames (layout runs
    /// on workers' 512 KB stacks, as deep as the parser's `maxNesting`).
    mutating func append(_ block: MarkdownBlock, environment: Environment) {
        switch block {
        case .quote(let blocks):
            var quoted = environment
            quoted.quoteBars.append(environment.indent)
            quoted.indent += style.quoteBarWidth + style.quoteIndent
            for child in blocks { append(child, environment: quoted) }
        case .list(let list):
            append(list, environment: environment)
        default:
            appendLeaf(block, environment: environment)
        }
    }

    @inline(never)
    private mutating func appendLeaf(_ block: MarkdownBlock, environment: Environment) {
        switch block {
        case .paragraph(let inlines):
            beginParagraph(environment)
            append(inlines, Inline(color: baseColor))
        case .heading(let level, let inlines):
            beginParagraph(environment)
            append(inlines, Inline(role: style.headingRole(level: level), bold: true, color: baseColor))
        case .code(_, let code):
            beginParagraph(environment)
            let start = text.length
            appendRun(code, font: style.font(.code), style: TextRunStyle(color: baseColor))
            text.setTabInterval(style.codeTabInterval, in: NSRange(location: start, length: text.length - start))
        case .table(let table):
            appendNested(table, environment: environment)
        case .rule(let spelling):
            beginParagraph(environment, isRule: true)
            appendRun(spelling, font: style.font(.body), style: TextRunStyle(color: .clear))
        case .quote, .list:
            append(block, environment: environment)
        }
    }

    private mutating func append(_ list: MarkdownList, environment: Environment) {
        var nested = environment
        nested.indent += style.listIndent
        nested.listDepth += 1
        nested.blockSpacing = list.isTight ? style.listItemSpacing : style.blockSpacing
        for (offset, item) in list.items.enumerated() {
            for (blockIndex, child) in item.blocks.enumerated() {
                if blockIndex == 0,
                    beginItem(item, at: offset, of: list, first: child, environment: environment, nested: nested)
                {
                    continue
                }
                append(child, environment: nested)
            }
        }
    }

    @inline(never)
    private mutating func beginItem(
        _ item: MarkdownList.Item, at offset: Int, of list: MarkdownList, first child: MarkdownBlock,
        environment: Environment, nested: Environment
    ) -> Bool {
        var first = environment
        first.blockSpacing = offset == 0 ? environment.blockSpacing : nested.blockSpacing
        if let checked = item.taskChecked {
            first.indent = nested.indent
            beginParagraph(
                first, headIndent: nested.indent,
                taskMarker: StyledParagraph.TaskMarker(x: environment.indent, checked: checked))
        } else {
            beginParagraph(first, headIndent: nested.indent)
            if let start = list.startIndex {
                appendRun("\(start + offset). ", font: style.font(.body), style: TextRunStyle(color: baseColor))
            } else {
                let bullet = ["•", "◦", "▪"][environment.listDepth % 3]
                appendRun("\(bullet)  ", font: style.font(.bullet), style: TextRunStyle(color: baseColor))
            }
        }
        guard case .paragraph(let inlines) = child else { return false }
        append(inlines, Inline(color: baseColor))
        return true
    }

    /// A table inside a list or quote: one line per row, cells separated.
    private mutating func appendNested(_ table: MarkdownTable, environment: Environment) {
        beginParagraph(environment)
        for (rowIndex, cells) in ([table.header] + table.rows).enumerated() {
            if rowIndex > 0 { appendRun("\n", font: style.font(.body), style: TextRunStyle(color: baseColor)) }
            for (column, cell) in cells.enumerated() {
                if column > 0 {
                    appendRun("  │  ", font: style.font(.body), style: TextRunStyle(color: .secondary))
                }
                append(cell, Inline(bold: rowIndex == 0, color: baseColor))
            }
        }
    }

    private mutating func append(_ inlines: [MarkdownInline], _ base: Inline) {
        for inline in inlines {
            let role: TextStyle.FontRole = inline.style.contains(.code) ? .code : base.role
            let font = style.font(
                role, bold: base.bold || inline.style.contains(.strong), italic: inline.style.contains(.emphasis))
            var runStyle = TextRunStyle(color: base.color)
            runStyle.isInlineCode = inline.style.contains(.code)
            runStyle.isStruck = inline.style.contains(.strikethrough)
            if let url = inline.link {
                runStyle.isUnderlined = true
                runStyle.linkIndex = text.link(url)
            }
            appendRun(inline.text, font: font, style: runStyle)
        }
    }

    private mutating func appendRun(_ string: String, font: TranscriptFont, style: TextRunStyle) {
        guard !string.isEmpty else { return }
        text.append(string, font: font, style: style)
        lastFont = font
    }

    private mutating func beginParagraph(
        _ environment: Environment, headIndent: CGFloat? = nil, isRule: Bool = false,
        taskMarker: StyledParagraph.TaskMarker? = nil
    ) {
        let isFirst = text.length == 0
        if !isFirst { text.append("\n", font: lastFont ?? style.font(.body), style: TextRunStyle()) }
        text.paragraphs.append(
            StyledParagraph(
                start: text.length, firstLineIndent: environment.indent,
                headIndent: headIndent ?? environment.indent,
                spacingBefore: isFirst ? 0 : environment.blockSpacing,
                quoteBars: environment.quoteBars, isRule: isRule, taskMarker: taskMarker))
    }
}
