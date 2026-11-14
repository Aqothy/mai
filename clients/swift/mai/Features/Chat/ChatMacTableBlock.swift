#if os(macOS)
    import AppKit
    import SwiftUI

    /// A Markdown table drawn from a prepared `ChatTableLayout` inside the
    /// horizontal scroller. Cells are deliberately not selectable; the copy
    /// button above the table copies it whole.
    struct ChatTableBlock: NSViewRepresentable {
        let layoutID: String
        let table: ChatMarkdownTable
        let layoutStore: ChatTextLayoutStore

        func makeNSView(context: Context) -> ChatMacTableHostView {
            ChatMacTableHostView()
        }

        func updateNSView(_ nsView: ChatMacTableHostView, context: Context) {
            nsView.update(
                layoutID: layoutID,
                table: table,
                layoutStore: layoutStore
            )
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            nsView: ChatMacTableHostView,
            context: Context
        ) -> CGSize? {
            guard let width = proposal.width, width > 0 else { return nil }
            let layout = layoutStore.tableLayout(id: layoutID, table: table)
            return CGSize(width: width, height: layout.size.height)
        }
    }
#endif
