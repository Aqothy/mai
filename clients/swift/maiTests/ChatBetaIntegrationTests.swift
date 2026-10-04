import Foundation
import SwiftUI
import Testing
@testable import mai

struct ChatBetaIntegrationTests {
    @Test @MainActor
    func acceptedCompletionStaysClosedAcrossDelayedCursorUpdates() throws {
        let model = PromptCompletionModel(store: ThreadStore(), scope: .workingDirectory("/qa"))
        model.updateCatalog(commands: [SlashCommand(description: nil, hasInput: false, inputHint: nil, name: "review")], skills: [])
        model.update(text: "/", cursorOffset: 1)
        let edit = try #require(model.editBySelectingCurrentMatch(in: "/"))
        #expect(edit.text == "/review")
        // The actual text field reports new text with its old cursor first.
        for cursor in [1, edit.cursorOffset, 3] {
            model.update(text: edit.text, cursorOffset: cursor)
            #expect(!model.isPresented)
        }
        model.update(text: "/revie", cursorOffset: 6)
        #expect(model.isPresented)
        #expect(model.dismiss())
        model.update(text: "/revie", cursorOffset: 6)
        #expect(!model.isPresented)
        // Escape still suppresses only the dismissed text/cursor pair.
        model.update(text: "/revie", cursorOffset: 5)
        #expect(model.isPresented)
    }

    @Test @MainActor
    func completionRejectsAnObsoleteChoiceAfterCatalogRefresh() throws {
        let model = PromptCompletionModel(store: ThreadStore(), scope: .workingDirectory("/qa"))
        let old = Skill(description: nil, enabled: true, name: "old", path: "/qa/skill", scope: nil, shortDescription: nil)
        let refreshed = old.with(name: "new")
        model.updateCatalog(commands: [], skills: [old])
        model.update(text: "$", cursorOffset: 1)
        let oldChoice = try #require(model.selectedMatch)
        model.updateCatalog(commands: [], skills: [refreshed])
        #expect(model.selectedMatch?.id == oldChoice.id)
        #expect(model.selectedMatch?.insertionValue == "new")
        #expect(model.edit(selecting: oldChoice, in: "$") == nil)
        #expect(model.isPresented)
        #expect(model.editBySelectingCurrentMatch(in: "$")?.text == "$new ")
    }

    @Test @MainActor
    func staticCompletionsFilterNavigateDismissAndRespectCapabilities() throws {
        let model = PromptCompletionModel(store: ThreadStore(), scope: .workingDirectory(""))
        model.update(text: "/", cursorOffset: 1)
        #expect(!model.isPresented)
        model.updateCatalog(commands: [
            SlashCommand(description: "Inspect changes", hasInput: false, inputHint: nil, name: "review"),
            SlashCommand(description: "Choose a model", hasInput: true, inputHint: "model name", name: "model")
        ], skills: [
            Skill(description: "Résumé documents", enabled: true, name: "writer", path: "/qa/writer", scope: "project", shortDescription: nil),
            Skill(description: nil, enabled: false, name: "disabled", path: nil, scope: nil, shortDescription: nil)
        ])
        #expect(model.isPresented)
        #expect(model.selectedMatch?.insertionValue == "review")
        #expect(model.moveSelection(by: -1))
        #expect(model.selectedMatch?.insertionValue == "model")
        #expect(model.moveSelection(by: 1))
        #expect(model.selectedMatch?.insertionValue == "review")
        model.update(text: "/MODEL", cursorOffset: 6)
        #expect(model.matches.count == 1)
        #expect(model.editBySelectingCurrentMatch(in: "/MODEL")?.text == "/model ")
        #expect(model.cursorRequest?.cursorOffset == 7)
        #expect(!model.isPresented)
        model.update(text: "/review", cursorOffset: 7)
        #expect(model.editBySelectingCurrentMatch(in: "/review")?.text == "/review")
        model.update(text: "/review", cursorOffset: 7)
        #expect(!model.isPresented)
        model.update(text: "$resume", cursorOffset: 7)
        #expect(model.matches.map(\.insertionValue) == ["writer"])
        #expect(model.dismiss())
        model.updateCatalog(commands: [], skills: [
            Skill(description: "Résumé documents", enabled: true, name: "writer", path: "/qa/writer", scope: nil, shortDescription: nil)
        ])
        #expect(!model.isPresented)
        model.update(text: "$resum", cursorOffset: 6)
        #expect(model.isPresented)
        model.updateCatalog(commands: [], skills: [])
        #expect(!model.isPresented)
        model.update(text: "@", cursorOffset: 1)
        #expect(!model.isFileCompletionAvailable)
        #expect(!model.isPresented)
        #expect(!model.moveSelection(by: 1))
    }

    @Test @MainActor
    func completionCursorRejectsMismatchedPasteAndDeletionRevisions() {
        let pasted = "Release QA\nStreaming café 👩🏽‍💻 stays intact.\n@file"
        let selection = TextSelection(insertionPoint: pasted.endIndex)
        #expect(PromptCompletionCursor.offset(for: selection, in: "") == nil)
        #expect(PromptCompletionCursor.offset(for: selection, in: "short") == nil)
        #expect(PromptCompletionCursor.offset(for: selection, in: pasted) == pasted.count)
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
    func resolvedReferenceRowsKeepAttachmentsAndAvoidTextOnlyNativeHosts() throws {
        let attachment = Attachment(data: nil, kind: "image", mimeType: "image/png", name: "QA attachment", uri: "https://example.invalid/qa.png")
        var message = Message(
            annotations: nil, attachments: [attachment], createdAt: .now,
            id: "reference-with-attachment", role: "assistant",
            text: "[Guide][ref]\n\n```swift\nlet value = 42\n```\n\n[ref]: https://example.com/guide",
            turnID: "turn", updatedAt: .now)
        let cache = ChatMarkdownSegmentCache()
        let rows = ChatTimeline.renderRows([.message(message)], streamingTurnID: nil, segmentCache: cache)
        #if os(macOS)
            #expect(rows.count == 2)
            let resolved = rows.compactMap { row -> ChatResolvedMarkdownBlockRowModel? in
                if case .resolvedMarkdown(let block) = row { return block }
                return nil
            }
            #expect(resolved.count == 2)
            #expect(resolved.first?.attachments == nil)
            #expect(resolved.last?.attachments?.count == 1)
            #expect(resolved.last?.attachments?.first?.uri == attachment.uri)
            #expect(ChatNativePreparedRow.descriptor(for: try #require(rows.first)) != nil)
            #expect(ChatNativePreparedRow.descriptor(for: try #require(rows.last)) == nil)
        #else
            #expect(rows.count == 1)
            guard case .standard(.message(let retained)) = try #require(rows.first) else {
                Issue.record("iOS reference document lost its standard selection renderer")
                return
            }
            #expect(retained.attachments?.first?.uri == attachment.uri)
        #endif
        message.annotations = [PromptAnnotation(id: "note", messageID: "original", note: "Explain", quote: "Guide", role: "assistant")]
        let annotated = ChatTimeline.renderRows([.message(message)], streamingTurnID: nil, segmentCache: cache)
        #expect(annotated.count == 1)
        guard case .standard(.message(let retained)) = try #require(annotated.first) else {
            Issue.record("Annotated reference document lost its metadata renderer")
            return
        }
        #expect(retained.attachments?.first?.uri == attachment.uri)
        #expect(retained.annotations?.first?.messageID == "original")
        #expect(retained.annotations?.first?.quote == "Guide")
    }

    @Test
    func textSelectionFromReplacedTextIsInvalid() {
        let typed = "Prompt café 🧪 tail"
        let caret = TextSelection(insertionPoint: typed.endIndex)
        #expect(caret.isValid(in: typed))
        #expect(!caret.isValid(in: ""))
        #expect(!caret.isValid(in: "short"))
        let emoji = typed.firstIndex(of: "🧪") ?? typed.endIndex
        let range = TextSelection(range: typed.startIndex..<emoji)
        #expect(range.isValid(in: typed + " longer"))
        #expect(TextSelection(insertionPoint: "".startIndex).isValid(in: ""))
    }

    @Test
    func prosePunctuationMatchesTheSource() {
        let source = #"Run git push --force with "quoted" and 'single' args... then `code "x"`"#
        let shown = #"Run git push --force with "quoted" and 'single' args... then code "x""#
        #expect(String(ChatMarkdownAttributedStringRenderer.attributedString(from: source).characters) == shown)
        #expect(ChatProseMarkdownRenderer.attributedString(from: source).string == shown)
    }

    @Test
    func singleNewlinesStayLineBreaks() {
        let source = "First line\nsecond line\n\nNext paragraph"
        #expect(String(ChatMarkdownAttributedStringRenderer.attributedString(from: source).characters).hasPrefix("First line\nsecond line"))
        #expect(ChatProseMarkdownRenderer.attributedString(from: source).string.hasPrefix("First line\nsecond line"))
    }

    @Test @MainActor
    func removingAnAnnotationKeepsOthers() throws {
        let model = ChatAnnotationModel()
        model.beginComment(quote: "  First 🌍 quote\n", messageID: "first", role: "assistant")
        model.editorDraft?.note = "  Clarify this  "
        model.addEditorDraft()
        let submitted = try #require(model.annotations.first)
        #expect(submitted.quote == "First 🌍 quote")
        #expect(submitted.note == "Clarify this")
        model.beginComment(quote: "Added while sending", messageID: "second", role: "assistant")
        model.addEditorDraft()
        model.remove(id: submitted.id)
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
