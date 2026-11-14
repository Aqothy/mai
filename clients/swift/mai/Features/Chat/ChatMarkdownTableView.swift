import SwiftUI

/// A lightweight Markdown table. Individual cells are intentionally not
/// selectable; the explicit copy action copies the complete table.
struct ChatMarkdownTableView: View {
    let table: ChatMarkdownTable
    /// Identifies the table's prepared native layout.
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

            // The table is measured off the main actor and drawn natively.
            ChatTableBlock(
                layoutID: layoutID,
                table: table,
                layoutStore: textLayoutStore
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Markdown table")
        .accessibilityValue(table.tabSeparatedText)
    }
}
