#if os(iOS)
    import SwiftUI
    import UIKit

    /// A fenced code block as one selectable, horizontally scrolling text
    /// view whose text and size were prepared off the main actor.
    struct ChatCodeBlockText: UIViewRepresentable {
        @Environment(\.chatAnnotationContext) private var annotationContext
        let layoutID: String
        let block: ChatMarkdownCodeBlock
        let theme: ChatCodeHighlightTheme
        let layoutStore: ChatTextLayoutStore

        func makeUIView(context: Context) -> ChatCodeBlockHostView {
            ChatCodeBlockHostView()
        }

        func updateUIView(_ uiView: ChatCodeBlockHostView, context: Context) {
            uiView.annotationContext = annotationContext
            uiView.update(layoutID: layoutID, block: block, theme: theme, layoutStore: layoutStore)
        }

        static func dismantleUIView(_ uiView: ChatCodeBlockHostView, coordinator: Void) {
            uiView.dismantle()
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiView: ChatCodeBlockHostView,
            context: Context
        ) -> CGSize? {
            guard let width = proposal.width, width > 0 else { return nil }
            let layout = layoutStore.codeLayout(id: layoutID, block: block, theme: theme).layout
            return CGSize(width: width, height: layout.height + ChatCodeBlockStyle.bottomInset)
        }
    }
#endif
