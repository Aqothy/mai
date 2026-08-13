import SwiftUI

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

/// A small SwiftUI table whose copy control stays pinned to the visible
/// top-right edge while wide content scrolls underneath it.
struct ChatMarkdownTableView: View {
    let table: ChatMarkdownTable

    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal) {
                ChatMarkdownTableGrid(table: table)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.top, 32)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(
                "Copy table",
                systemImage: copied ? "checkmark" : "square.on.square",
                action: copyTable
            )
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
            .background(.background)
            .accessibilityHint("Copies the table to the Clipboard")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Markdown table")
        .accessibilityValue(table.tabSeparatedText)
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
        }
    }

    private func copyTable() {
        #if os(iOS)
            UIPasteboard.general.string = table.tabSeparatedText
        #elseif os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                table.tabSeparatedText,
                forType: .string
            )
        #endif

        copied = true
        copyResetTask?.cancel()
        copyResetTask = Task {
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            copied = false
        }
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
