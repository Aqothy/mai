#if os(iOS)
    import SwiftUI
    import UIKit

    /// Selectable prose in a SwiftUI row, whose attributed content and
    /// measured height can be prepared before the row is mounted.
    struct ChatSelectableText: UIViewRepresentable {
        @Environment(\.chatAnnotationContext) private var annotationContext

        let layoutID: String
        let content: ChatTextContent
        let layoutStore: ChatTextLayoutStore

        func makeUIView(context: Context) -> ChatSelectableTextHostView {
            ChatSelectableTextHostView()
        }

        func updateUIView(_ uiView: ChatSelectableTextHostView, context: Context) {
            uiView.annotationContext = annotationContext
            uiView.update(layoutID: layoutID, content: content, layoutStore: layoutStore)
        }

        static func dismantleUIView(
            _ uiView: ChatSelectableTextHostView,
            coordinator: Void
        ) {
            uiView.dismantle()
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            uiView: ChatSelectableTextHostView,
            context: Context
        ) -> CGSize? {
            guard let width = proposal.width, width > 0 else { return nil }
            let layout = layoutStore.layout(id: layoutID, content: content, width: width)
            return CGSize(width: width, height: layout.height)
        }
    }
#endif
