import SwiftUI

/// A lightweight Markdown table. Individual cells are intentionally not
/// selectable; the explicit copy action copies the complete table.
struct ChatMarkdownTableView: View {
    let table: ChatMarkdownTable
    /// Identifies the table's prepared native layout on macOS.
    let layoutID: String
    let textLayoutStore: ChatTextLayoutStore

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
                .frame(
                    width: ChatRichBlockStyle.tableToolbarHeight,
                    height: ChatRichBlockStyle.tableToolbarHeight
                )
                .contentShape(.rect)
            }

            // On macOS the table is measured off the main actor and drawn
            // natively; the AppKit container also passes vertical wheel
            // gestures through to the enclosing chat timeline.
            #if os(macOS)
                ChatMacTableBlock(
                    layoutID: layoutID,
                    table: table,
                    layoutStore: textLayoutStore
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            #else
                ScrollView(.horizontal) {
                    ChatMarkdownTableGrid(table: table)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .scrollIndicators(.visible, axes: .horizontal)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
            #endif
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Markdown table")
        .accessibilityValue(table.tabSeparatedText)
    }
}

#if os(iOS)
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
                table: table
            )

            Divider()
                .gridCellUnsizedAxes(.horizontal)

            ForEach(table.rows.indices, id: \.self) { index in
                ChatMarkdownTableRow(
                    cells: table.rows[index],
                    table: table
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
    let cells: [ChatMarkdownText]
    let table: ChatMarkdownTable

    var body: some View {
        GridRow(alignment: .top) {
            ForEach(0..<table.columnCount, id: \.self) { column in
                ChatMarkdownTableCell(
                    content: cells.indices.contains(column)
                        ? Self.swiftUIText(cells[column])
                        : AttributedString(),
                    alignment: table.alignments.indices.contains(column)
                        ? table.alignments[column]
                        : .leading
                )
            }
        }
    }

    /// SwiftUI `Text` ignores UIKit attributes, so the renderer's cell text
    /// is carried over attribute by attribute; styling is decided only there.
    private static func swiftUIText(_ text: ChatMarkdownText) -> AttributedString {
        var result = AttributedString(text.string)
        text.value.enumerateAttributes(
            in: NSRange(location: 0, length: text.value.length)
        ) { attributes, range, _ in
            guard let range = Range(range, in: result) else { return }
            if let font = attributes[.font] as? UIFont {
                result[range].font = Font(font as CTFont)
            }
            if let color = attributes[.foregroundColor] as? UIColor {
                result[range].foregroundColor = Color(uiColor: color)
            }
            if attributes[.strikethroughStyle] != nil {
                result[range].strikethroughStyle = .single
            }
            if attributes[.underlineStyle] != nil {
                result[range].underlineStyle = .single
            }
            if let link = attributes[.link] as? URL {
                result[range].link = link
            }
        }
        return result
    }
}

private struct ChatMarkdownTableCell: View {
    let content: AttributedString
    let alignment: ChatMarkdownTable.ColumnAlignment

    var body: some View {
        Text(content)
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
#endif
