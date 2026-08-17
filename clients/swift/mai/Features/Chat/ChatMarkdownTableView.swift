import SwiftUI

/// A lightweight Markdown table. Individual cells are intentionally not
/// selectable; the explicit copy action copies the complete table.
struct ChatMarkdownTableView: View {
    let table: ChatMarkdownTable

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                ChatCopyButton(
                    title: "Copy table",
                    accessibilityHint: "Copies the table to the Clipboard",
                    text: table.tabSeparatedText
                )
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
            }

            ScrollView(.horizontal) {
                ChatMarkdownTableGrid(table: table)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .scrollIndicators(.visible, axes: .horizontal)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Markdown table")
        .accessibilityValue(table.tabSeparatedText)
    }
}

private struct ChatMarkdownTableGrid: View {
    let table: ChatMarkdownTable

    var body: some View {
        Grid(
            alignment: .leading,
            horizontalSpacing: 24,
            verticalSpacing: 0
        ) {
            ChatMarkdownTableRow(
                cells: table.header,
                table: table,
                isHeader: true
            )

            Divider()
                .gridCellUnsizedAxes(.horizontal)

            ForEach(table.rows.indices, id: \.self) { index in
                ChatMarkdownTableRow(
                    cells: table.rows[index],
                    table: table,
                    isHeader: false
                )

                if index < table.rows.count - 1 {
                    Divider()
                        .gridCellUnsizedAxes(.horizontal)
                }
            }
        }
    }
}

private struct ChatMarkdownTableRow: View {
    let cells: [AttributedString]
    let table: ChatMarkdownTable
    let isHeader: Bool

    var body: some View {
        GridRow(alignment: .top) {
            ForEach(0..<table.columnCount, id: \.self) { column in
                ChatMarkdownTableCell(
                    content: cells.indices.contains(column)
                        ? cells[column]
                        : AttributedString(),
                    alignment: table.alignments.indices.contains(column)
                        ? table.alignments[column]
                        : .leading,
                    isHeader: isHeader
                )
            }
        }
    }
}

private struct ChatMarkdownTableCell: View {
    let content: AttributedString
    let alignment: ChatMarkdownTable.ColumnAlignment
    let isHeader: Bool

    var body: some View {
        Text(content)
            .bold(isHeader)
            .multilineTextAlignment(textAlignment)
            .frame(
                minWidth: 96,
                maxWidth: 280,
                alignment: frameAlignment
            )
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 12)
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case .leading:
            .leading
        case .center:
            .center
        case .trailing:
            .trailing
        }
    }

    private var textAlignment: TextAlignment {
        switch alignment {
        case .leading:
            .leading
        case .center:
            .center
        case .trailing:
            .trailing
        }
    }
}
