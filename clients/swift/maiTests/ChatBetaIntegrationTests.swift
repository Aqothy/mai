import Foundation
import Testing
@testable import mai

struct ChatBetaIntegrationTests {
    @Test @MainActor
    func referenceDocumentKeepsAnnotationsAndPlatformSelectionPath() throws {
        let annotation = PromptAnnotation(
            id: "comment", messageID: "earlier", note: "Explain this", quote: "quoted", role: "assistant")
        var message = Message(
            annotations: [annotation], attachments: nil, createdAt: .now,
            id: "reference-message", role: "assistant",
            text: "[Guide][ref]\n\n```swift\nlet value = 42\n```\n\n[ref]: https://example.com/guide",
            turnID: nil, updatedAt: .now)
        let cache = ChatMarkdownSegmentCache()
        let annotated = ChatTimeline.renderRows(
            [.message(message)], streamingTurnID: nil, segmentCache: cache)
        #expect(annotated.count == 1)
        guard case .standard(.message(let preserved)) = try #require(annotated.first) else {
            Issue.record("Annotated reference documents must keep their metadata")
            return
        }
        #expect(preserved.annotations?.first?.quote == "quoted")

        message.annotations = nil
        let rows = ChatTimeline.renderRows(
            [.message(message)], streamingTurnID: nil, segmentCache: cache)
        #if os(macOS)
            #expect(rows.count == 2)
            let model = ChatAnnotationModel()
            #expect(rows.allSatisfy { $0.annotationContext(model: model)?.messageID == message.id })
        #else
            #expect(rows.count == 1)
            guard case .standard = try #require(rows.first) else {
                Issue.record("iOS must retain the complete document selection action")
                return
            }
        #endif
    }

    @Test @MainActor
    func sendingAnnotationsOnlyRemovesSubmittedDrafts() throws {
        let model = ChatAnnotationModel()
        model.beginComment(quote: "  First 🌍 quote\n", messageID: "first", role: "assistant")
        model.editorDraft?.note = "  Clarify this  "
        model.addEditorDraft()
        let submitted = try #require(model.annotations.first)
        #expect(submitted.quote == "First 🌍 quote")
        #expect(submitted.note == "Clarify this")
        model.beginComment(quote: "Added while sending", messageID: "second", role: "assistant")
        model.addEditorDraft()
        model.removeSent(ids: [submitted.id])
        #expect(model.annotations.count == 1)
        #expect(model.annotations.first?.messageID == "second")
        model.beginComment(quote: "Cancelled", messageID: "third", role: "assistant")
        model.cancelEditor()
        #expect(model.annotations.count == 1)
        model.beginComment(quote: " \n ", messageID: nil, role: nil)
        #expect(model.editorDraft == nil)
    }

    @Test @MainActor
    func completionPreservesUnicodeSuffixAndRejectsStaleText() throws {
        for trigger in ["@", "/", "$"] {
            let text = "👨‍👩‍👧‍👦 Review \(trigger)rea後続"
            let cursor = "👨‍👩‍👧‍👦 Review \(trigger)rea".count
            let context = try #require(PromptCompletionInsertionContext.detect(in: text, cursorOffset: cursor))
            #expect(context.query(in: text, cursorOffset: cursor) == "rea")
            let edit = try #require(context.edit(replacingWith: "readme", appendsTrailingSpace: true, in: text))
            #expect(edit.text == "👨‍👩‍👧‍👦 Review \(trigger)readme 後続")
            #expect(edit.cursorOffset == "👨‍👩‍👧‍👦 Review \(trigger)readme ".count)
            #expect(context.edit(replacingWith: "bad", appendsTrailingSpace: true, in: "Changed \(text)") == nil)
        }
        #expect(PromptCompletionInsertionContext.detect(in: "mail@example.com", cursorOffset: 16) == nil)
    }

    @Test @MainActor
    func revealDoesNotRestartOlderBatchesAndResetsOnReplacement() {
        let time = Date(timeIntervalSince1970: 100)
        let identity = ChatStreamingTextRevealTarget.Identity(
            stableBlockCount: 0, blockIndex: 0, content: .proseText(pieceIndex: 0))
        var state = ChatStreamingTextRevealState()
        for index in 0..<4 {
            state.observe(
                target: .init(identity: identity, characterCount: index * 10), updateID: index,
                sourceIsAppendOnly: true, at: time.addingTimeInterval(Double(index) * 0.05))
        }
        #expect(state.batches.map(\.characterCount) == [10, 10, 10])
        #expect(state.batches.first?.startedAt == time.addingTimeInterval(0.05))
        state.observe(target: .init(identity: identity, characterCount: 5), updateID: 4,
                      sourceIsAppendOnly: false, at: time.addingTimeInterval(0.16))
        #expect(state.batches.isEmpty)
        state.observe(target: .init(identity: identity, characterCount: 10_000), updateID: 5,
                      sourceIsAppendOnly: true, at: time.addingTimeInterval(0.17))
        #expect(state.batches.reduce(0) { $0 + $1.characterCount } <= 512)
    }
}
