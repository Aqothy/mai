#if os(macOS)
    import AppKit
    import SwiftUI

    /// Native macOS range selection for chat prose.
    struct ChatSelectableText: NSViewRepresentable {
        @Environment(\.chatAnnotationContext) private var annotationContext
        let layoutID: String
        let content: ChatTextContent
        let layoutStore: ChatTextLayoutStore

        func makeNSView(context: Context) -> ChatSelectableTextHostView {
            ChatSelectableTextHostView()
        }

        func updateNSView(
            _ nsView: ChatSelectableTextHostView,
            context: Context
        ) {
            nsView.annotationContext = annotationContext
            nsView.update(layoutID: layoutID, content: content, layoutStore: layoutStore)
        }

        static func dismantleNSView(
            _ nsView: ChatSelectableTextHostView,
            coordinator: Void
        ) {
            nsView.dismantle()
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            nsView: ChatSelectableTextHostView,
            context: Context
        ) -> CGSize? {
            guard let width = proposal.width, width > 0 else { return nil }
            let layout = layoutStore.layout(id: layoutID, content: content, width: width)
            return CGSize(width: width, height: layout.height)
        }
    }
#endif
