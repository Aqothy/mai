import CoreGraphics
import Foundation

/// A Markdown table: one `TextLayout` per cell, columns sized to their
/// content between the chat's minimum and maximum widths, 24 points between
/// columns, 12 above and below each row's text, a hairline between rows,
/// under a toolbar for its copy button. Wider than the row, it scrolls
/// horizontally.
nonisolated struct TableLayout: Sendable {
    struct Cell: Sendable {
        let layout: TextLayout
        let origin: CGPoint
        /// The cell's box in the grid: its column's width, its row's height.
        let box: CGRect
        let row: Int
        let column: Int
    }

    let cells: [Cell]
    let dividers: [CGRect]
    /// The grid's size, below the toolbar.
    let gridSize: CGSize
    let toolbarHeight: CGFloat
    /// The block's size: the row's width, the toolbar plus the grid.
    let size: CGSize

    var isWiderThanBlock: Bool { gridSize.width > size.width + 0.5 }

    static func make(_ table: MarkdownTable, width: CGFloat, style: TextStyle) -> TableLayout {
        let columns = table.columnCount
        let rows = [table.header] + table.rows
        var measured: [[TextLayout]] = []
        var columnWidths = [CGFloat](repeating: style.tableMinimumColumnWidth, count: columns)
        for (rowIndex, row) in rows.enumerated() {
            var line: [TextLayout] = []
            for column in 0..<columns {
                let inlines = row.indices.contains(column) ? row[column] : []
                var builder = AttributedTextBuilder(style: style)
                builder.append(
                    .paragraph(rowIndex == 0 ? inlines.map(Self.bold) : inlines),
                    environment: .init(blockSpacing: 0))
                let layout = TextLayoutEngine.layout(
                    builder.text, width: style.tableMaximumColumnWidth, options: .init(lineSpacing: style.lineSpacing))
                columnWidths[column] = max(columnWidths[column], min(style.tableMaximumColumnWidth, layout.size.width))
                line.append(layout)
            }
            measured.append(line)
        }
        var columnOrigins: [CGFloat] = []
        var x: CGFloat = 0
        for columnWidth in columnWidths {
            columnOrigins.append(x)
            x += columnWidth + style.tableColumnSpacing
        }
        let gridWidth = max(0, x - style.tableColumnSpacing)
        let emptyLineHeight = style.font(.body).lineHeight
        var cells: [Cell] = []
        var dividers: [CGRect] = []
        var y: CGFloat = 0
        for (rowIndex, line) in measured.enumerated() {
            let rowHeight = line.map { $0.lines.isEmpty ? emptyLineHeight : $0.size.height }.max() ?? emptyLineHeight
            for (column, layout) in line.enumerated() {
                let alignment = table.alignments.indices.contains(column) ? table.alignments[column] : .leading
                let slack = columnWidths[column] - layout.size.width
                let offset: CGFloat =
                    switch alignment {
                    case .leading: 0
                    case .center: (slack / 2).rounded()
                    case .trailing: slack
                    }
                // Boxes meet halfway between columns and end at the grid's
                // edges, where there is no spacing to share.
                let leadingPad = column == 0 ? 0 : style.tableColumnSpacing / 2
                let trailingPad = column == columns - 1 ? 0 : style.tableColumnSpacing / 2
                cells.append(
                    Cell(
                        layout: layout,
                        origin: CGPoint(x: columnOrigins[column] + offset, y: y + style.tableCellVerticalPadding),
                        box: CGRect(
                            x: columnOrigins[column] - leadingPad, y: y,
                            width: columnWidths[column] + leadingPad + trailingPad,
                            height: rowHeight + 2 * style.tableCellVerticalPadding),
                        row: rowIndex, column: column))
            }
            y += rowHeight + 2 * style.tableCellVerticalPadding
            if rowIndex < measured.count - 1 {
                dividers.append(CGRect(x: 0, y: y, width: gridWidth, height: 1))
                y += 1
            }
        }
        let gridSize = CGSize(width: ceil(gridWidth), height: ceil(y))
        return TableLayout(
            cells: cells, dividers: dividers, gridSize: gridSize, toolbarHeight: style.tableToolbarHeight,
            size: CGSize(width: width, height: style.tableToolbarHeight + gridSize.height))
    }

    private static func bold(_ inline: MarkdownInline) -> MarkdownInline {
        var bolded = inline
        bolded.style.insert(.strong)
        return bolded
    }

    /// The table as tab-separated rows, which paste into spreadsheets.
    static func tabSeparatedText(_ table: MarkdownTable) -> String {
        ([table.header] + table.rows).map { row in
            (0..<table.columnCount).map { column in
                row.indices.contains(column) ? row[column].map(\.text).joined() : ""
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }
}
