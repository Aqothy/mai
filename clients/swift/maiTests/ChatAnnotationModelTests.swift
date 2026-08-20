import Testing
@testable import mai

struct ChatAnnotationModelTests {
    @Test
    func editorAddsNormalizedAnnotation() throws {
        let model = ChatAnnotationModel()
        model.beginComment(
            quote: "  Selected text\n",
            messageID: "message-1",
            role: "assistant"
        )
        model.editorDraft?.note = "  Please explain this.  "
        model.addEditorDraft()

        let annotation = try #require(model.annotations.first)
        #expect(annotation.quote == "Selected text")
        #expect(annotation.note == "Please explain this.")
        #expect(annotation.messageID == "message-1")
        #expect(annotation.role == "assistant")
        #expect(model.editorDraft == nil)

        let wireAnnotation = annotation.promptAnnotation
        #expect(wireAnnotation.id == annotation.id)
        #expect(wireAnnotation.quote == annotation.quote)
        #expect(wireAnnotation.note == annotation.note)
    }

    @Test
    func emptyCommentStillAttachesSelectedQuote() throws {
        let model = ChatAnnotationModel()
        model.beginComment(
            quote: "A useful quote",
            messageID: nil,
            role: nil
        )
        model.addEditorDraft()

        let annotation = try #require(model.annotations.first)
        #expect(annotation.note == nil)
        #expect(annotation.quote == "A useful quote")
    }

    @Test
    func removingSentAnnotationsPreservesNewerDrafts() throws {
        let model = ChatAnnotationModel()
        model.beginComment(quote: "First", messageID: "1", role: "assistant")
        model.addEditorDraft()
        let sentID = try #require(model.annotations.first?.id)

        model.beginComment(quote: "Second", messageID: "2", role: "user")
        model.addEditorDraft()
        model.removeSent(ids: [sentID])

        #expect(model.annotations.map(\.quote) == ["Second"])
    }

    @Test
    func summaryCollapsesWhitespaceAndTruncates() {
        let whitespace = ChatPendingAnnotation(
            id: "1",
            messageID: nil,
            quote: "one\n  two\tthree",
            role: nil,
            note: nil
        )
        #expect(ChatAnnotationFormatting.summary(for: whitespace) == "one two three")

        let long = ChatPendingAnnotation(
            id: "2",
            messageID: nil,
            quote: String(repeating: "界", count: 80),
            role: nil,
            note: nil
        )
        let summary = ChatAnnotationFormatting.summary(for: long)
        #expect(summary.count == 73)
        #expect(summary.hasSuffix("…"))
    }
}
