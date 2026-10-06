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
    }
#endif
