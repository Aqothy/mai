import CoreGraphics
import Foundation
import Testing

@testable import mai

/// Selection and copy across rows: rows a message is flattened into copy as
/// the message's text, a selection survives a pending message being parsed,
/// and iOS gets both grab handles when an end sits on a row boundary.
@MainActor
struct TranscriptSelectionRegressionTests {
    @MainActor @Test func flattenedParagraphAndJSONCopyMatchesSourceExactly() {
        let prose = Array(repeating: "configuration", count: 2_000).joined(separator: " ")
        let unbrokenToken = String(repeating: "configuration", count: 2_000)
        let jsonPrompt = "[" + String(repeating: #"{"config":"value","n":12345},"#, count: 1_000) + "]"

        for (kind, source) in [
            (TranscriptMessage.Kind.assistant, prose),
            (.assistant, unbrokenToken),
            (.user, jsonPrompt),
        ] {
            let message = TranscriptMessage(kind: kind, turnID: "t", ref: "r")
            let rows = message.rows(from: MarkdownPlanner.blocks(from: source))
            #expect(rows.count >= 2, "expected a payload over the slice size to split into slices")

            let controller = TranscriptController(configuration: .testing)
            controller.setRows(rows)
            controller.selectAll()
            let copied = controller.selectedText()
            #expect(copied == source, "copying across flattened slices must match the source verbatim")

            if let first = controller.firstTextPosition, let last = controller.lastTextPosition {
                #expect(controller.offset(from: first, to: last) == copied.utf16.count)
                let stepped = controller.position(from: first, offset: copied.utf16.count)
                #expect(stepped == last)
            }
        }
    }

    @Test func flattenedListPreservesExactItemSpacingAtSeam() {
        let style = TextStyle.current()
        let itemText = String(repeating: "item detail ", count: 30)
        let md = (0..<80).map { "- Item \($0): \(itemText)" }.joined(separator: "\n")
        let rows = TranscriptMessage(kind: .assistant, turnID: "t", ref: "l").rows(from: MarkdownPlanner.blocks(from: md))
        #expect(rows.count >= 2)
        if case .markdownBlock(_, let pos, let ctx) = rows[1].kind {
            #expect(ctx.joinsAbove)
            #expect(ctx.joinSpacingAbove == .tight)
            #expect(ctx.spacingAbove(pos, style: style) == style.lineSpacing + style.listItemSpacing)
        } else {
            Issue.record("expected flattened tight list continuation row")
        }
    }

    @MainActor @Test func selectAllSurvivesPendingParseAndCopiesRenderedMarkdownConsistently() {
        let controller = TranscriptController(configuration: .testing)
        let msg = TranscriptMessage(kind: .assistant, turnID: "t0", ref: "a0")
        let source = "Hello **there** and `code`!"
        let pending = msg.pendingRow(source: source)
        controller.setRows([pending])
        controller.selectAll()
        #expect(controller.hasValidSelection)

        // Copying before parsing must match copying after parsing (rendered plain text).
        let copiedBeforeParse = controller.selectedText()
        #expect(copiedBeforeParse == "Hello there and code!")

        // Splicing parsed rows must remap selection instead of dropping it.
        let parsedRows = msg.rows(from: MarkdownPlanner.blocks(from: source))
        controller.replaceRows(0..<1, with: parsedRows, heights: [:])
        #expect(controller.hasValidSelection)
        #expect(controller.selectedText() == copiedBeforeParse)
    }

    @MainActor @Test func iosBoundarySelectionRectsAlwaysEmitStartAndEndHandleTags() {
        let controller = TranscriptController(configuration: .testing)
        controller.columnWidth = 400
        let rows = [
            TranscriptRow(id: "r0", kind: .markdownBlock(.paragraph([MarkdownInline(text: "First row")]), .single)),
            TranscriptRow(id: "r1", kind: .markdownBlock(.paragraph([MarkdownInline(text: "Second row")]), .single)),
        ]
        controller.setRows(rows)
        var heights: [String: CGFloat] = [:]
        for row in controller.rows {
            let layout = RowLayoutBuilder.layout(controller.request(row))
            controller.storeLayout(layout)
            heights[row.id] = layout.height
        }
        controller.setHeights(heights)

        // Start at exact end of row 0, end inside row 1.
        let rectsStartBoundary = controller.taggedSelectionRects(
            from: TextPosition(rowID: "r0", offset: 9),
            to: TextPosition(rowID: "r1", offset: 6),
            columnX: 0, scrollX: { _ in 0 })
        #expect(rectsStartBoundary.contains { $0.isStart })
        #expect(rectsStartBoundary.contains { $0.isEnd })

        // Start inside row 0, end at exact start of row 1.
        let rectsEndBoundary = controller.taggedSelectionRects(
            from: TextPosition(rowID: "r0", offset: 2),
            to: TextPosition(rowID: "r1", offset: 0),
            columnX: 0, scrollX: { _ in 0 })
        #expect(rectsEndBoundary.contains { $0.isStart })
        #expect(rectsEndBoundary.contains { $0.isEnd })
    }
}
