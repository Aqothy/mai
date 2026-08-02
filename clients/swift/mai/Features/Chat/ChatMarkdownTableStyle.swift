import MarkdownView
import SwiftUI

/// Adds the one behavior missing from MarkdownView's built-in table styles:
/// horizontal scrolling at narrow chat widths.
struct ChatMarkdownTableStyle: MarkdownTableStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChatMarkdownTable(configuration: configuration)
    }
}

private struct ChatMarkdownTable: View {
    let configuration: MarkdownTableStyleConfiguration

    var body: some View {
        let rows = configuration.table.rows

        ScrollView(.horizontal) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                configuration.table.header
                    .bold()

                // MarkdownView exposes opaque rows without stable keys.
                ForEach(rows.indices, id: \.self) { index in
                    rows[index]
                }
            }
            .markdownTableCellPadding(.vertical, 8)
            .markdownTableCellPadding(.horizontal, 10)
            .markdownTableCellOverlay {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(
            "Markdown table with \((rows.count + 1).formatted()) rows"
        )
        .accessibilityHint("Scroll horizontally to read all columns.")
    }
}
