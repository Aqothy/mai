#if os(macOS)
    import AppKit

    /// Adds the shared annotation editor to native text without changing
    /// NSTextView's cursor tracking or selection behavior.
    final class ChatAnnotationTextView: NSTextView {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        var annotationContext: ChatAnnotationContext?

        private struct CommentSelection {
            let quote: String
            let context: ChatAnnotationContext
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = super.menu(for: event) ?? NSMenu()
            appendComment(to: menu)
            return menu
        }

        func appendComment(to menu: NSMenu) {
            let range = selectedRange()
            guard let annotationContext, let textStorage,
                range.location != NSNotFound, range.length > 0,
                range.location <= textStorage.length,
                range.length <= textStorage.length - range.location
            else { return }
            let item = NSMenuItem(
                title: "Comment…", action: #selector(comment(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = CommentSelection(
                quote: textStorage.attributedSubstring(from: range).string,
                context: annotationContext)
            menu.addItem(.separator())
            menu.addItem(item)
        }

        @objc func comment(_ sender: NSMenuItem) {
            guard let selection = sender.representedObject as? CommentSelection,
                let annotationContext,
                annotationContext.messageID == selection.context.messageID,
                annotationContext.model === selection.context.model
            else { return }
            selection.context.model.beginComment(
                quote: selection.quote,
                messageID: selection.context.messageID,
                role: selection.context.role)
        }
    }
#endif
