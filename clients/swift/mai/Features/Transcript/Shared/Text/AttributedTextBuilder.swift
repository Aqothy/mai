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
    private(set) var text = StyledText()

    init(style: TextStyle) {
        self.style = style
    }

    static func build(_ blocks: [MarkdownBlock], style: TextStyle) -> StyledText {
        var builder = AttributedTextBuilder(style: style)
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
        builder.text.append(string, font: style.font(role, bold: bold), style: TextRunStyle(color: color))
        return builder.text
    }

    mutating func append(_ block: MarkdownBlock, environment: Environment) {
        switch block {
        case .paragraph(let inlines):
            beginParagraph(environment)
            append(inlines, Inline())
        case .heading(let level, let inlines):
            beginParagraph(environment)
            append(inlines, Inline(role: style.headingRole(level: level), bold: true))
        case .quote(let blocks):
            var quoted = environment
            quoted.quoteBars.append(environment.indent)
            quoted.indent += style.quoteBarWidth + style.quoteIndent
            for child in blocks { append(child, environment: quoted) }
        case .list(let list):
            append(list, environment: environment)
        case .code(_, let code):
            beginParagraph(environment)
            text.append(code, font: style.font(.code), style: TextRunStyle())
        case .table(let table):
            appendNested(table, environment: environment)
        case .rule(let spelling):
            beginParagraph(environment, isRule: true)
            text.append(spelling, font: style.font(.body), style: TextRunStyle(color: .clear))
        }
    }

    private mutating func append(_ list: MarkdownList, environment: Environment) {
        var nested = environment
        nested.indent += style.listIndent
        nested.listDepth += 1
        nested.blockSpacing = style.listItemSpacing
        let depth = environment.listDepth
        for (offset, item) in list.items.enumerated() {
            for (blockIndex, child) in item.enumerated() {
                guard blockIndex == 0, case .paragraph(let inlines) = child else {
                    append(child, environment: nested)
                    continue
                }
                var first = environment
                first.blockSpacing = offset == 0 ? environment.blockSpacing : style.listItemSpacing
                beginParagraph(first, headIndent: nested.indent)
                if let start = list.startIndex {
                    text.append("\(start + offset). ", font: style.font(.body), style: TextRunStyle())
                } else {
                    let bullet = ["•", "◦", "▪"][depth % 3]
                    text.append("\(bullet)  ", font: style.font(.bullet), style: TextRunStyle())
                }
                append(inlines, Inline())
            }
        }
    }

    /// A table inside a list or quote: one line per row, cells separated.
    private mutating func appendNested(_ table: MarkdownTable, environment: Environment) {
        beginParagraph(environment)
        for (rowIndex, cells) in ([table.header] + table.rows).enumerated() {
            if rowIndex > 0 { text.append("\n", font: style.font(.body), style: TextRunStyle()) }
            for (column, cell) in cells.enumerated() {
                if column > 0 {
                    text.append("  │  ", font: style.font(.body), style: TextRunStyle(color: .secondary))
                }
                append(cell, Inline(bold: rowIndex == 0))
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
            text.append(inline.text, font: font, style: runStyle)
        }
    }

    /// Starts a block-level paragraph: a newline ends the one before, and the
    /// block spacing separates them.
    private mutating func beginParagraph(
        _ environment: Environment, headIndent: CGFloat? = nil, isRule: Bool = false
    ) {
        let isFirst = text.length == 0
        if !isFirst { text.append("\n", font: style.font(.body), style: TextRunStyle()) }
        text.paragraphs.append(
            StyledParagraph(
                start: text.length, firstLineIndent: environment.indent,
                headIndent: headIndent ?? environment.indent,
                spacingBefore: isFirst ? 0 : environment.blockSpacing,
                quoteBars: environment.quoteBars, isRule: isRule))
    }
}
