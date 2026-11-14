#if os(iOS)
    import SwiftUI
    import UIKit

    /// A Markdown table drawn from a prepared `ChatTableLayout` inside the
    /// horizontal scroller. Cells are deliberately not selectable; the copy
    /// button above the table copies it whole.
    struct ChatTableBlock: UIViewRepresentable {
        let layoutID: String
        let table: ChatMarkdownTable
        let layoutStore: ChatTextLayoutStore

        func makeUIView(context: Context) -> ChatTableHostView {
            ChatTableHostView()
        }

        func updateUIView(_ uiView: ChatTableHostView, context: Context) {
            uiView.update(layoutID: layoutID, table: table, layoutStore: layoutStore)
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiView: ChatTableHostView,
            context: Context
        ) -> CGSize? {
            guard let width = proposal.width, width > 0 else { return nil }
            let layout = layoutStore.tableLayout(id: layoutID, table: table)
            return CGSize(width: width, height: layout.size.height)
        }
    }
#endif
