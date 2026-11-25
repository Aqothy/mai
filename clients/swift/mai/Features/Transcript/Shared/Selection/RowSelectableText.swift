import CoreGraphics
import Foundation

/// A row's selectable text without its layout: what copy reads for rows far
/// from the viewport, whose layouts were dropped. Built by the same code the
/// layout's text comes from, so offsets agree (`RowContentLayout.selectableString`).
nonisolated enum RowSelectableText {
    static func string(for kind: TranscriptRowKind, style: TextStyle) -> String? {
        switch kind {
        case .markdownBlock(.code(_, let code), _):
            return code
        case .markdownBlock(.table(let table), _):
            return TableLayout.tabSeparatedText(table)
        case .markdownBlock(let block, _):
            return AttributedTextBuilder.build([block], style: style).string.string
        case .userMessage(let blocks):
            return AttributedTextBuilder.build(blocks, style: style).string.string
        case .thought(let blocks):
            return AttributedTextBuilder.build(blocks, style: style, color: .secondary).string.string
        case .pendingMessage(_, let source):
            return source
        case .notice(let title, let text):
            guard let text, !text.isEmpty else { return title }
            return title + "\n" + text
        case .activity, .turnHeader, .turnActions, .working:
            return nil
        }
    }

    /// Exact UTF-16 length of `string(for:style:)` without building an
    /// `NSAttributedString` or touching Core Text fonts. Matches
    /// `RowContentLayout.selectableLength` for every selectable row kind.
    static func utf16Length(for kind: TranscriptRowKind) -> Int? {
        switch kind {
        case .markdownBlock(.code(_, let code), _):
            return code.utf16.count
        case .markdownBlock(.table(let table), _):
            return tableUTF16Length(table)
        case .markdownBlock(let block, _):
            return blocksUTF16Length([block])
        case .userMessage(let blocks), .thought(let blocks):
            return blocksUTF16Length(blocks)
        case .pendingMessage(_, let source):
            return source.utf16.count
        case .notice(let title, let text):
            guard let text, !text.isEmpty else { return title.utf16.count }
            return title.utf16.count + 1 + text.utf16.count
        case .activity, .turnHeader, .turnActions, .working:
            return nil
        }
    }

    private static func tableUTF16Length(_ table: MarkdownTable) -> Int {
        let columns = table.columnCount
        let rowCount = 1 + table.rows.count
        var total = max(0, rowCount - 1) + rowCount * max(0, columns - 1)
        func addRow(_ row: [[MarkdownInline]]) {
            let limit = min(columns, row.count)
            for col in 0..<limit {
                for inline in row[col] { total += inline.text.utf16.count }
            }
        }
        addRow(table.header)
        for row in table.rows { addRow(row) }
        return total
    }

    private static func blocksUTF16Length(_ blocks: [MarkdownBlock]) -> Int {
        var total = 0
        func beginParagraph() {
            if total > 0 { total += 1 }
        }
        func appendInlines(_ inlines: [MarkdownInline]) {
            for inline in inlines { total += inline.text.utf16.count }
        }
        func decimalDigitCount(_ value: Int) -> Int {
            var remaining = value.magnitude
            var count = value < 0 ? 2 : 1
            while remaining >= 10 {
                remaining /= 10
                count += 1
            }
            return count
        }
        func appendBlock(_ block: MarkdownBlock) {
            switch block {
            case .quote(let children):
                for child in children { appendBlock(child) }
            case .list(let list):
                for (offset, item) in list.items.enumerated() {
                    for (blockIndex, child) in item.blocks.enumerated() {
                        if blockIndex == 0 {
                            beginParagraph()
                            if item.taskChecked == nil {
                                if let start = list.startIndex {
                                    // "\(start + offset). "
                                    total += decimalDigitCount(start + offset) + 2
                                } else {
                                    // "•  ", "◦  ", or "▪  " — 3 UTF-16 code units.
                                    total += 3
                                }
                            }
                            if case .paragraph(let inlines) = child {
                                appendInlines(inlines)
                                continue
                            }
                        }
                        appendBlock(child)
                    }
                }
            case .paragraph(let inlines), .heading(_, let inlines):
                beginParagraph()
                appendInlines(inlines)
            case .code(_, let code):
                beginParagraph()
                total += code.utf16.count
            case .table(let table):
                beginParagraph()
                var rowIndex = 0
                func addNestedRow(_ row: [[MarkdownInline]]) {
                    if rowIndex > 0 { total += 1 }
                    for (column, cell) in row.enumerated() {
                        if column > 0 { total += 5 }  // "  │  "
                        appendInlines(cell)
                    }
                    rowIndex += 1
                }
                addNestedRow(table.header)
                for row in table.rows { addNestedRow(row) }
            case .rule(let spelling):
                beginParagraph()
                total += spelling.utf16.count
            }
        }
        for block in blocks { appendBlock(block) }
        return total
    }
}
