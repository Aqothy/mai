import Foundation
import SwiftUI
import Testing
@testable import mai

struct ChatBetaIntegrationTests {
    @Test @MainActor
    func completionCursorRejectsMismatchedPasteAndDeletionRevisions() {
        let pasted = "Release QA\nStreaming café 👩🏽‍💻 stays intact.\n@file"
        let selection = TextSelection(insertionPoint: pasted.endIndex)
        #expect(PromptCompletionCursor.offset(for: selection, in: "") == nil)
        #expect(PromptCompletionCursor.offset(for: selection, in: "short") == nil)
        #expect(PromptCompletionCursor.offset(for: selection, in: pasted) == pasted.count)
        #expect(PromptCompletionCursor.offset(for: selection, in: "") == nil)
        #expect(PromptCompletionCursor.offset(for: nil, in: "") == 0)
    }

    @Test @MainActor
    func completionCursorCountsUnicodeCharactersAtEveryValidBoundary() {
        let text = "café e\u{301} 👩🏽‍💻\n@文件"
        for (offset, index) in text.indices.enumerated() {
            let selection = TextSelection(insertionPoint: index)
            #expect(PromptCompletionCursor.offset(for: selection, in: text) == offset)
        }
        #expect(PromptCompletionCursor.offset(for: nil, in: text) == text.count)
        let end = TextSelection(insertionPoint: text.endIndex)
        #expect(PromptCompletionCursor.offset(for: end, in: text) == text.count)
    }

    @Test @MainActor
    func completionCursorRejectsNonBoundaryIndicesAndSelectedText() {
        let old = "abc"
        let stale = TextSelection(insertionPoint: old.index(after: old.startIndex))
        #expect(PromptCompletionCursor.offset(for: stale, in: "👩🏽‍💻") == nil)
        #expect(PromptCompletionCursor.offset(for: stale, in: "e\u{301}") == nil)
        let selection = TextSelection(range: old.startIndex..<old.endIndex)
        #expect(PromptCompletionCursor.offset(for: selection, in: old) == nil)
    }

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

}
