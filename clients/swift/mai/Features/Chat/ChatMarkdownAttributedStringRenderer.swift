import Foundation
import Markdown
import SwiftUI

/// Builds the SwiftUI attributed-string fallback used for isolated rich
/// blocks and document-wide edge cases. The main iOS prose path uses
/// `ChatProseMarkdownRenderer` and TextKit for true range selection.
nonisolated enum ChatMarkdownAttributedStringRenderer {
    static func attributedString(from source: String) -> AttributedString {
        guard !source.isEmpty else { return AttributedString() }

        var builder = ChatMarkdownAttributedStringBuilder()
        let result = builder.render(
            document: Markdown.Document(parsing: source)
        )

        // Reference definitions and other non-rendering nodes can produce an
        // empty document. Never make non-empty message source disappear.
        return result.characters.isEmpty ? AttributedString(source) : result
    }

    /// Renders an already-parsed root block without parsing its source again.
    static func attributedString(from block: Markup) -> AttributedString {
        var builder = ChatMarkdownAttributedStringBuilder()
        let result = builder.render(block: block)
        return result.characters.isEmpty
            ? AttributedString(block.format())
            : result
    }

    /// Table cells contain inline children rather than standalone documents.
    static func attributedString(
        fromInlineChildren children: MarkupChildren
    ) -> AttributedString {
        var builder = ChatMarkdownAttributedStringBuilder()
        return builder.renderInlineChildren(children)
    }
}

private nonisolated struct ChatMarkdownAttributedStringBuilder {
    private struct InlineEnvironment {
        var presentationIntent: InlinePresentationIntent = []
        var font: Font?
        var foregroundColor: Color?
        var link: URL?
        var isUnderlined = false
    }

    mutating func render(document: Markdown.Document) -> AttributedString {
        joined(
            document.children.map { render(block: $0, listDepth: 0) },
            separator: "\n\n"
        )
    }

    mutating func render(block: Markup) -> AttributedString {
        render(block: block, listDepth: 0)
    }

    mutating func renderInlineChildren(
        _ children: MarkupChildren
    ) -> AttributedString {
        renderInline(children)
    }

    private mutating func render(
        block: Markup,
        listDepth: Int
    ) -> AttributedString {
        switch block {
        case let paragraph as Paragraph:
            return renderInline(paragraph.children)

        case let heading as Heading:
            var environment = InlineEnvironment()
            environment.font = ChatMarkdownProseStyle.headingFont(
                level: heading.level
            )
            environment.presentationIntent.insert(.stronglyEmphasized)
            var result = renderInline(
                heading.children,
                environment: environment
            )
            if let level = AttributeScopes.AccessibilityAttributes
                .HeadingLevelAttribute.HeadingLevel(
                    rawValue: max(1, min(6, heading.level))
                )
            {
                result.accessibilityHeadingLevel = level
            }
            return result

        case let quote as BlockQuote:
            return renderQuote(quote, listDepth: listDepth)

        case let list as UnorderedList:
            return render(
                items: list.listItems,
                startingAt: nil,
                listDepth: listDepth
            )

        case let list as OrderedList:
            return render(
                items: list.listItems,
                startingAt: Int(list.startIndex),
                listDepth: listDepth
            )

        case let codeBlock as CodeBlock:
            return code(codeBlock.code)

        case is ThematicBreak:
            var result = AttributedString("────────────")
            result.foregroundColor = .secondary
            return result

        case let html as HTMLBlock:
            return code(html.rawHTML)

        case let table as Markdown.Table:
            return render(table: table)

        default:
            if block.childCount > 0 {
                return joined(
                    block.children.map {
                        render(block: $0, listDepth: listDepth)
                    },
                    separator: "\n\n"
                )
            }
            return AttributedString(block.format())
        }
    }

    private mutating func renderQuote(
        _ quote: BlockQuote,
        listDepth: Int
    ) -> AttributedString {
        let content = joined(
            quote.children.map {
                render(block: $0, listDepth: listDepth)
            },
            separator: "\n\n"
        )
        return prefixLines(in: content, with: "▏  ")
    }

    private mutating func render(
        items: some Sequence<ListItem>,
        startingAt firstOrdinal: Int?,
        listDepth: Int
    ) -> AttributedString {
        let renderedItems = items.enumerated().map { offset, item in
            let marker: String
            if item.checkbox != nil {
                // Match the ChatGPT prose treatment. Interactive task state can
                // become a dedicated rich block later.
                marker = bullet(for: listDepth)
            } else if let firstOrdinal {
                marker = "\(firstOrdinal + offset)."
            } else {
                marker = bullet(for: listDepth)
            }
            return render(
                item: item,
                marker: marker,
                listDepth: listDepth
            )
        }
        return joined(renderedItems, separator: "\n")
    }

    private mutating func render(
        item: ListItem,
        marker: String,
        listDepth: Int
    ) -> AttributedString {
        let indentation = String(repeating: "    ", count: listDepth)
        var result = AttributedString(indentation + marker + "  ")

        var childIndex = 0
        if item.childCount > 0,
            let paragraph = item.child(at: 0) as? Paragraph
        {
            result.append(renderInline(paragraph.children))
            childIndex = 1
        }

        while childIndex < item.childCount {
            guard let child = item.child(at: childIndex) else {
                childIndex += 1
                continue
            }
            result.append(AttributedString("\n"))
            if child is OrderedList || child is UnorderedList {
                result.append(
                    render(block: child, listDepth: listDepth + 1)
                )
            } else {
                result.append(AttributedString(indentation + "    "))
                result.append(
                    render(block: child, listDepth: listDepth + 1)
                )
            }
            childIndex += 1
        }
        return result
    }

    private mutating func render(
        table: Markdown.Table
    ) -> AttributedString {
        var rows: [AttributedString] = []

        var header = render(cells: table.head.children)
        header.inlinePresentationIntent = .stronglyEmphasized
        rows.append(header)

        for child in table.body.children {
            guard let row = child as? Markdown.Table.Row else { continue }
            rows.append(render(cells: row.children))
        }
        return joined(rows, separator: "\n")
    }

    private mutating func render(cells: MarkupChildren) -> AttributedString {
        var renderedCells: [AttributedString] = []
        for child in cells {
            guard let cell = child as? Markdown.Table.Cell else { continue }
            renderedCells.append(renderInline(cell.children))
        }

        var separator = AttributedString("  │  ")
        separator.foregroundColor = .secondary
        return joined(renderedCells, separator: separator)
    }

    private mutating func renderInline(
        _ nodes: MarkupChildren,
        environment: InlineEnvironment = InlineEnvironment()
    ) -> AttributedString {
        var result = AttributedString()
        for node in nodes {
            switch node {
            case let text as Markdown.Text:
                result.append(attributed(text.string, environment: environment))

            case let emphasis as Emphasis:
                var nested = environment
                nested.presentationIntent.insert(.emphasized)
                result.append(
                    renderInline(emphasis.children, environment: nested)
                )

            case let strong as Strong:
                var nested = environment
                nested.presentationIntent.insert(.stronglyEmphasized)
                result.append(renderInline(strong.children, environment: nested))

            case let strikethrough as Strikethrough:
                var nested = environment
                nested.presentationIntent.insert(.strikethrough)
                result.append(
                    renderInline(strikethrough.children, environment: nested)
                )

            case let inlineCode as InlineCode:
                var nested = environment
                nested.presentationIntent.insert(.code)
                nested.font = .system(.body, design: .monospaced)
                result.append(
                    attributed(inlineCode.code, environment: nested)
                )

            case let link as Markdown.Link:
                var nested = environment
                nested.link = link.destination.flatMap(URL.init(string:))
                nested.isUnderlined = true
                result.append(renderInline(link.children, environment: nested))

            case let image as Markdown.Image:
                // Never fetch remote media through the prose renderer. Keep
                // useful, selectable alt text instead.
                var nested = environment
                nested.presentationIntent.insert(.code)
                nested.font = .system(.body, design: .monospaced)
                result.append(attributed("[Image: ", environment: nested))
                result.append(renderInline(image.children, environment: nested))
                result.append(attributed("]", environment: nested))

            case let html as InlineHTML:
                // Inline HTML is inert source text, not executable markup.
                result.append(
                    attributed(html.rawHTML, environment: environment)
                )

            case is SoftBreak:
                result.append(attributed(" ", environment: environment))

            case is LineBreak:
                result.append(attributed("\n", environment: environment))

            default:
                if node.childCount > 0 {
                    result.append(
                        renderInline(node.children, environment: environment)
                    )
                } else {
                    result.append(
                        attributed(node.format(), environment: environment)
                    )
                }
            }
        }
        return result
    }

    private func attributed(
        _ text: String,
        environment: InlineEnvironment
    ) -> AttributedString {
        var result = AttributedString(text)
        if !environment.presentationIntent.isEmpty {
            result.inlinePresentationIntent = environment.presentationIntent
        }
        result.font = environment.font
        result.foregroundColor = environment.foregroundColor
        result.link = environment.link
        if environment.isUnderlined {
            result.underlineStyle = .single
        }
        return result
    }

    private func code(_ source: String) -> AttributedString {
        var result = AttributedString(
            source.trimmingCharacters(in: .newlines)
        )
        result.font = .system(.body, design: .monospaced)
        result.backgroundColor = .primary.opacity(0.06)
        return result
    }

    private mutating func prefixLines(
        in source: AttributedString,
        with prefix: String
    ) -> AttributedString {
        guard !source.characters.isEmpty else { return source }

        var result = AttributedString()
        var lineStart = source.startIndex
        while lineStart < source.endIndex {
            var marker = AttributedString(prefix)
            marker.foregroundColor = .secondary
            marker.font = .system(.body, design: .monospaced)
            result.append(marker)

            if let newline = source.characters[lineStart...]
                .firstIndex(of: "\n")
            {
                let afterNewline = source.characters.index(after: newline)
                result.append(
                    AttributedString(source[lineStart..<afterNewline])
                )
                lineStart = afterNewline
            } else {
                result.append(
                    AttributedString(source[lineStart..<source.endIndex])
                )
                break
            }
        }
        return result
    }

    private func bullet(for depth: Int) -> String {
        let bullets = ["•", "◦", "▪"]
        return bullets[depth % bullets.count]
    }

    private func joined(
        _ values: some Sequence<AttributedString>,
        separator: String
    ) -> AttributedString {
        joined(values, separator: AttributedString(separator))
    }

    private func joined(
        _ values: some Sequence<AttributedString>,
        separator: AttributedString
    ) -> AttributedString {
        var result = AttributedString()
        for value in values where !value.characters.isEmpty {
            if !result.characters.isEmpty {
                result.append(separator)
            }
            result.append(value)
        }
        return result
    }
}
