import Foundation
import Markdown

/// Converts a swift-markdown document into the minimal value model needed by
/// chat. Parsing and conversion can run away from the main actor.
nonisolated enum ChatMarkdownRenderPlanner {
    struct ParsedBlock: Sendable {
        let utf8Offset: Int
        let block: ChatMarkdownRenderPlan.Block
    }

    static func plan(from source: String) -> ChatMarkdownRenderPlan {
        let parsed = parsedBlocks(from: source)
        if parsed.isEmpty, !source.isEmpty {
            return ChatMarkdownRenderPlan(
                blocks: [
                    .prose(
                        ChatMarkdownProseRun(
                            source: source,
                            pieces: [.text(AttributedString(source))]
                        )
                    )
                ]
            )
        }
        return ChatMarkdownRenderPlan(blocks: parsed.map(\.block))
    }

    static func parsedBlocks(from source: String) -> [ParsedBlock] {
        guard !source.isEmpty else { return [] }

        let bytes = Array(source.utf8)
        var lineStarts = [0]
        for (offset, byte) in bytes.enumerated() where byte == 0x0A {
            lineStarts.append(offset + 1)
        }

        let document = Markdown.Document(parsing: source)
        var locatedChildren: [(offset: Int, block: Markup)] = []
        locatedChildren.reserveCapacity(document.childCount)

        for child in document.children {
            guard let location = child.range?.lowerBound,
                lineStarts.indices.contains(location.line - 1)
            else { continue }

            let offset = lineStarts[location.line - 1] + location.column - 1
            guard offset <= bytes.count else { continue }
            locatedChildren.append((offset, child))
        }

        var result: [ParsedBlock] = []
        result.reserveCapacity(locatedChildren.count)
        for index in locatedChildren.indices {
            let child = locatedChildren[index]
            let endOffset = locatedChildren.indices.contains(index + 1)
                ? locatedChildren[index + 1].offset
                : bytes.count
            let blockSource = String(
                decoding: bytes[child.offset..<endOffset],
                as: UTF8.self
            )
            result.append(
                ParsedBlock(
                    utf8Offset: child.offset,
                    block: render(child.block, source: blockSource)
                )
            )
        }
        return result
    }

    private static func render(
        _ block: Markup,
        source: String
    ) -> ChatMarkdownRenderPlan.Block {
        switch block {
        case let quote as BlockQuote:
            return .prose(
                ChatMarkdownProseRun(
                    source: source,
                    pieces: [
                        .quote(
                            ChatMarkdownAttributedStringRenderer
                                .attributedString(fromQuoteContents: quote)
                        )
                    ]
                )
            )

        case let codeBlock as CodeBlock:
            return .code(
                ChatMarkdownCodeBlock(
                    code: removingOneTrailingNewline(from: codeBlock.code),
                    language: codeBlock.language,
                    kind: .fenced
                )
            )

        case let htmlBlock as HTMLBlock:
            return .code(
                ChatMarkdownCodeBlock(
                    code: removingOneTrailingNewline(from: htmlBlock.rawHTML),
                    language: "html",
                    kind: .html
                )
            )

        case let table as Markdown.Table:
            return .table(render(table))

        case is ThematicBreak:
            return .prose(
                ChatMarkdownProseRun(
                    source: source,
                    pieces: [.thematicBreak]
                )
            )

        default:
            return .prose(
                ChatMarkdownProseRun(
                    source: source,
                    pieces: [
                        .text(
                            ChatMarkdownAttributedStringRenderer
                                .attributedString(from: block)
                        )
                    ]
                )
            )
        }
    }

    private static func removingOneTrailingNewline(
        from source: String
    ) -> String {
        source.hasSuffix("\n") ? String(source.dropLast()) : source
    }

    private static func render(_ table: Markdown.Table) -> ChatMarkdownTable {
        let alignments = table.columnAlignments.map { alignment in
            switch alignment {
            case .center:
                ChatMarkdownTable.ColumnAlignment.center
            case .right:
                ChatMarkdownTable.ColumnAlignment.trailing
            case .left, nil:
                ChatMarkdownTable.ColumnAlignment.leading
            }
        }

        let header = renderCells(in: table.head.children)
        var rows: [[AttributedString]] = []
        rows.reserveCapacity(table.body.childCount)
        for child in table.body.children {
            guard let row = child as? Markdown.Table.Row else { continue }
            rows.append(renderCells(in: row.children))
        }

        return ChatMarkdownTable(
            alignments: alignments,
            header: header,
            rows: rows
        )
    }

    private static func renderCells(
        in children: MarkupChildren
    ) -> [AttributedString] {
        children.compactMap { child in
            guard let cell = child as? Markdown.Table.Cell else { return nil }
            return ChatMarkdownAttributedStringRenderer.attributedString(
                fromInlineChildren: cell.children
            )
        }
    }
}
