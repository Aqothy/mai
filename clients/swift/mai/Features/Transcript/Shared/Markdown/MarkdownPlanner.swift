import CoreGraphics
import Foundation
import Markdown

/// Turns Markdown source into `MarkdownBlock` values, one per top-level
/// block. Runs on any thread; swift-markdown's tree never leaves the call.
nonisolated enum MarkdownPlanner {
    /// The blocks of a whole message. Source with no blocks (whitespace
    /// aside) shows as written.
    static func blocks(from source: String) -> [MarkdownBlock] {
        let parsed = parseBlocks(from: source)
        if parsed.isEmpty, source.contains(where: { !$0.isWhitespace }) {
            return [.paragraph([MarkdownInline(text: source)])]
        }
        return parsed
    }

    /// Top-level blocks of `source` without the whole-message whitespace
    /// fallback (for prefixes and tails of a streaming message).
    static func parseBlocks(from source: String) -> [MarkdownBlock] {
        guard !source.isEmpty else { return [] }
        // Smart punctuation would turn quotes, `--` and `...` into
        // typographic characters, so displayed and copied text would no
        // longer match commands and flags in the source.
        let document = Document(parsing: source, options: .disableSmartOpts)
        var lines: MarkdownSourceLines?
        var result: [MarkdownBlock] = []
        result.reserveCapacity(document.childCount)
        for child in document.children {
            result.append(block(child, source: source, lines: &lines))
        }
        return result
    }

    private static func block(
        _ markup: Markup, source: String, lines: inout MarkdownSourceLines?
    ) -> MarkdownBlock {
        switch markup {
        case let paragraph as Paragraph:
            return .paragraph(inlines(paragraph.children))
        case let heading as Heading:
            return .heading(level: max(1, min(6, heading.level)), inlines(heading.children))
        case let quote as BlockQuote:
            return .quote(quote.children.map { block($0, source: source, lines: &lines) })
        case let list as UnorderedList:
            return .list(MarkdownList(startIndex: nil, items: items(list.listItems, source: source, lines: &lines)))
        case let list as OrderedList:
            return .list(
                MarkdownList(
                    startIndex: Int(list.startIndex), items: items(list.listItems, source: source, lines: &lines)))
        case let code as CodeBlock:
            return .code(language: code.language, code: removingOneTrailingNewline(code.code))
        case let html as HTMLBlock:
            return .code(language: "html", code: removingOneTrailingNewline(html.rawHTML))
        case let table as Markdown.Table:
            return .table(self.table(table))
        case let rule as ThematicBreak:
            let resolved = lines ?? {
                let built = MarkdownSourceLines(source)
                lines = built
                return built
            }()
            return .rule(spelling: resolved.spelling(of: rule) ?? rule.format())
        default:
            // A future or custom node shows as its source rather than vanishing.
            return .paragraph([MarkdownInline(text: markup.format())])
        }
    }

    private static func items(
        _ items: some Sequence<ListItem>, source: String, lines: inout MarkdownSourceLines?
    ) -> [[MarkdownBlock]] {
        items.map { item in item.children.map { block($0, source: source, lines: &lines) } }
    }

    private static func table(_ table: Markdown.Table) -> MarkdownTable {
        let alignments: [MarkdownTable.Alignment] = table.columnAlignments.map {
            switch $0 {
            case .center: .center
            case .right: .trailing
            case .left, nil: .leading
            }
        }
        let header = table.head.children.compactMap { ($0 as? Markdown.Table.Cell).map { inlines($0.children) } }
        let rows = table.body.children.compactMap { row in
            (row as? Markdown.Table.Row)?.children.compactMap {
                ($0 as? Markdown.Table.Cell).map { inlines($0.children) }
            }
        }
        return MarkdownTable(alignments: alignments, header: header, rows: rows)
    }

    // MARK: Inline

    static func inlines(_ nodes: some Sequence<Markup>) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        appendInlines(nodes, style: [], link: nil, to: &result)
        return result
    }

    private static func appendInlines(
        _ nodes: some Sequence<Markup>, style: MarkdownInline.Style, link: URL?,
        to result: inout [MarkdownInline]
    ) {
        for node in nodes {
            switch node {
            case let text as Markdown.Text:
                append(text.string, style: style, link: link, to: &result)
            case let emphasis as Emphasis:
                appendInlines(emphasis.children, style: style.union(.emphasis), link: link, to: &result)
            case let strong as Strong:
                appendInlines(strong.children, style: style.union(.strong), link: link, to: &result)
            case let struck as Strikethrough:
                appendInlines(struck.children, style: style.union(.strikethrough), link: link, to: &result)
            case let code as InlineCode:
                append(code.code, style: style.union(.code), link: link, to: &result)
            case let markdownLink as Markdown.Link:
                appendInlines(
                    markdownLink.children, style: style,
                    link: TranscriptLinkPolicy.url(for: markdownLink.destination), to: &result)
            case let image as Markdown.Image:
                // Images stay literal Markdown; their source is never fetched.
                append(image.format(), style: style.union(.code), link: link, to: &result)
            case let html as InlineHTML:
                // Inline HTML is inert source text.
                append(html.rawHTML, style: style.union(.code), link: link, to: &result)
            case is SoftBreak, is LineBreak:
                // Chat text keeps the line breaks its author typed.
                append("\n", style: style, link: link, to: &result)
            default:
                append(node.format(), style: style, link: link, to: &result)
            }
        }
    }

    /// Joins text into the previous run when the style and link match, so a
    /// paragraph is as few runs as its styling allows.
    private static func append(
        _ text: String, style: MarkdownInline.Style, link: URL?, to result: inout [MarkdownInline]
    ) {
        guard !text.isEmpty else { return }
        // In place: a copy of the last run would share its text's storage,
        // so appending to it would copy the run's text every time.
        if let last = result.indices.last, result[last].style == style, result[last].link == link {
            result[last].text += text
        } else {
            result.append(MarkdownInline(text: text, style: style, link: link))
        }
    }

    private static func removingOneTrailingNewline(_ text: String) -> String {
        text.hasSuffix("\n") ? String(text.dropLast()) : text
    }
}
