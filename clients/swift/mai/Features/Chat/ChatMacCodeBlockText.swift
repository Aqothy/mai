#if os(macOS)
    import AppKit
    import SwiftUI

    // Native macOS rendering for settled rich Markdown blocks. These views
    // present a layout measured off the main actor by `ChatTextLayoutStore`
    // instead of nesting another hosting view per block, so realizing a row
    // is a frame assignment and its height is known before it exists.

    /// A fenced code block as one selectable, horizontally scrolling
    /// `NSTextView` whose text and size were prepared off the main actor.
    struct ChatCodeBlockText: NSViewRepresentable {
        @Environment(\.chatAnnotationContext) private var annotationContext
        let layoutID: String
        let block: ChatMarkdownCodeBlock
        let theme: ChatCodeHighlightTheme
        let layoutStore: ChatTextLayoutStore

        func makeNSView(context: Context) -> ChatMacCodeBlockHostView {
            ChatMacCodeBlockHostView()
        }

        func updateNSView(
            _ nsView: ChatMacCodeBlockHostView,
            context: Context
        ) {
            (nsView.documentView as? ChatAnnotationTextView)?.annotationContext = annotationContext
            nsView.update(
                layoutID: layoutID,
                block: block,
                theme: theme,
                layoutStore: layoutStore
            )
        }

        static func dismantleNSView(
            _ nsView: ChatMacCodeBlockHostView,
            coordinator: Void
        ) {
            nsView.dismantle()
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            nsView: ChatMacCodeBlockHostView,
            context: Context
        ) -> CGSize? {
            guard let width = proposal.width, width > 0 else { return nil }
            let layout = layoutStore.codeLayout(
                id: layoutID,
                block: block,
                theme: theme
            ).layout
            return CGSize(
                width: width,
                height: layout.height + ChatCodeBlockStyle.bottomInset
            )
        }
    }
#endif
