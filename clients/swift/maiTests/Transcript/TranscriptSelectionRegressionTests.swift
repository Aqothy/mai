import CoreGraphics
import Foundation
import Testing

@testable import mai

/// Selection and copy across rows: rows a message is flattened into copy as
/// the message's text, a selection survives a pending message being parsed,
/// and iOS gets both grab handles when an end sits on a row boundary.
struct TranscriptSelectionRegressionTests {
    @Test func flattenedParagraphAndJSONCopyMatchesSourceExactly() {
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

    @Test func selectAllSurvivesPendingParseAndCopiesRenderedMarkdownConsistently() {
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

    @Test func iosBoundarySelectionRectsAlwaysEmitStartAndEndHandleTags() {
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

    /// Vertical arrow navigation stays in a right-aligned table column across
    /// varying cell widths, returns `self` for `lineOffset == 0`, and returns
    /// `nil` when already at document boundaries.
    @Test func positionVerticallyStaysInRightAlignedTableColumnAndReturnsNilAtDocumentEnds() throws {
        let controller = TranscriptController(configuration: .testing)
        controller.columnWidth = 400
        let table = MarkdownTable(
            alignments: [.leading, .trailing],
            header: [[MarkdownInline(text: "Item")], [MarkdownInline(text: "1234567890")]],
            rows: [
                [[MarkdownInline(text: "Row1")], [MarkdownInline(text: "5")]],
                [[MarkdownInline(text: "Row2")], [MarkdownInline(text: "99999")]],
            ])
        let row = TranscriptRow(id: "t0", kind: .markdownBlock(.table(table), .single))
        controller.setRows([row])
        let layout = RowLayoutBuilder.layout(controller.request(row))
        controller.storeLayout(layout)
        controller.setHeights(["t0": layout.height])

        // Start in header's right-aligned column ("1234567890" -> segment index 1).
        let segments = layout.content.textSegments
        let col1Header = TextPosition(rowID: "t0", offset: segments[1].start + 2)
        #expect(controller.positionVertically(from: col1Header, lineOffset: 0, columnX: 0) == col1Header)
        let row1Pos = try #require(controller.positionVertically(from: col1Header, lineOffset: 1, columnX: 0))
        #expect(row1Pos.offset >= segments[3].start && row1Pos.offset <= segments[3].end)
        let row2Pos = try #require(controller.positionVertically(from: row1Pos, lineOffset: 1, columnX: 0))
        #expect(row2Pos.offset >= segments[5].start && row2Pos.offset <= segments[5].end)

        // Already at document start / end returns nil.
        let first = try #require(controller.firstTextPosition)
        let last = try #require(controller.lastTextPosition)
        #expect(controller.positionVertically(from: first, lineOffset: -1, columnX: 0) == nil)
        #expect(controller.positionVertically(from: last, lineOffset: 1, columnX: 0) == nil)
    }

    /// A boundary handle on a horizontally scrolled wide code block must be
    /// clipped away when scrolled out of the horizontal viewport.
    @Test func taggedSelectionRectsClipsOffscreenWideBlockBoundaryHandle() throws {
        let controller = TranscriptController(configuration: .testing)
        controller.columnWidth = 300
        let wideCode = String(repeating: "x", count: 160)
        let rows = [
            TranscriptRow(id: "c0", kind: .markdownBlock(.code(language: nil, code: wideCode), .single)),
            TranscriptRow(id: "p1", kind: .markdownBlock(.paragraph([MarkdownInline(text: "Below")]), .single)),
        ]
        controller.setRows(rows)
        var heights: [String: CGFloat] = [:]
        for row in controller.rows {
            let layout = RowLayoutBuilder.layout(controller.request(row))
            controller.storeLayout(layout)
            heights[row.id] = layout.height
        }
        controller.setHeights(heights)

        // Start at exact end of wide code block (x > 1000 pt) with scrollX == 0:
        // handle is past wideBody.frame.maxX and must not float outside.
        let rects = controller.taggedSelectionRects(
            from: TextPosition(rowID: "c0", offset: wideCode.utf16.count),
            to: TextPosition(rowID: "p1", offset: 3),
            columnX: 0, scrollX: { _ in 0 })
        #expect(!rects.contains { $0.isStart })
        #expect(rects.contains { $0.isEnd })
    }
}
