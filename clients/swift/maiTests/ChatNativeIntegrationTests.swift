#if os(macOS)
    import AppKit
    import Testing
    @testable import mai

    struct ChatNativeIntegrationTests {
        @Test @MainActor
        func commentUsesSelectedQuoteAndOriginalMessageIdentity() throws {
            let model = ChatAnnotationModel()
            let view = try #require(
                ChatSelectableTextViewConfiguration.makeTextView() as? ChatAnnotationTextView)
            view.string = "Hello 🌍 from the transcript"
            let range = (view.string as NSString).range(of: "🌍 from")
            view.setSelectedRange(range)
            view.annotationContext = ChatAnnotationContext(
                messageID: "original-message", role: "assistant", model: model)
            let menu = NSMenu()
            view.appendComment(to: menu)
            let item = try #require(menu.items.last)
            #expect(item.title == "Comment…")
            view.comment(item)
            #expect(model.editorDraft?.quote == "🌍 from")
            #expect(model.editorDraft?.messageID == "original-message")

            model.cancelEditor()
            view.annotationContext = ChatAnnotationContext(
                messageID: "reused-message", role: "assistant", model: model)
            view.comment(item)
            #expect(model.editorDraft == nil)
            view.annotationContext = nil
            let detachedMenu = NSMenu()
            view.appendComment(to: detachedMenu)
            #expect(detachedMenu.items.isEmpty)
        }

        @Test @MainActor
        func recycledNativeProseReceivesFreshAnnotationContext() throws {
            let model = ChatAnnotationModel()
            let layouts = ChatTextLayoutStore()
            let host = ChatNativePreparedRow(
                frame: NSRect(x: 0, y: 0, width: 300, height: 100))
            for id in ["first", "second"] {
                host.update(
                    .init(id: id, content: .prose("Quote for \(id)"), top: 0, bottom: 0),
                    width: 300, store: layouts, theme: .light,
                    annotationContext: ChatAnnotationContext(
                        messageID: id, role: "assistant", model: model))
                host.layoutSubtreeIfNeeded()
                let prose = try #require(
                    host.subviews.compactMap { $0 as? ChatSelectableTextHostView }.first)
                let text = try #require(
                    prose.subviews.compactMap { $0 as? ChatAnnotationTextView }.first)
                text.setSelectedRange(NSRange(location: 0, length: 5))
                let menu = NSMenu()
                text.appendComment(to: menu)
                text.comment(try #require(menu.items.last))
                #expect(model.editorDraft?.messageID == id)
                model.cancelEditor()
            }
        }
    }
#endif
