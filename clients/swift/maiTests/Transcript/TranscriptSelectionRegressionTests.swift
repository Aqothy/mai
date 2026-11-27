import CoreGraphics
import Foundation
import Testing

@testable import mai

/// Selection and copy across rows: rows a message is flattened into copy as
/// the message's text, a selection survives a pending message being parsed,
/// and iOS gets both grab handles when an end sits on a row boundary.
struct TranscriptSelectionRegressionTests {
    @Test func giantParagraphAndJSONStayOneRowAndCopyMatchesSourceExactly() {
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
            #expect(rows.count == 1, "expected one row per block with no slicing")

            let controller = TranscriptController(configuration: .testing)
            controller.setRows(rows)
            controller.selectAll()
            let copied = controller.selectedText()
            #expect(copied == source, "copying must match the source verbatim")

            if let first = controller.firstTextPosition, let last = controller.lastTextPosition {
                #expect(controller.offset(from: first, to: last) == copied.utf16.count)
                let stepped = controller.position(from: first, offset: copied.utf16.count)
                #expect(stepped == last)
            }
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

    /// Multi-row selections keep ragged-right per-line rects with exact
    /// `isStart`/`isEnd` endpoint tags, and O(log n) `offset(from:to:)` matches
    /// the exact sum of selectable row lengths + newline separators.
    @Test func crossRowSelectionKeepsRaggedRectsAndOffsetIsExact() throws {
        let controller = TranscriptController(configuration: .testing)
        controller.columnWidth = 320
        let rows = (0..<80).map { i in
            TranscriptRow(
                id: "p\(i)",
                kind: .markdownBlock(
                    .paragraph([MarkdownInline(text: "Paragraph \(i) with enough words to wrap across lines.")]),
                    .single))
        }
        controller.setRows(rows)
        var heights: [String: CGFloat] = [:]
        for row in controller.rows {
            let layout = RowLayoutBuilder.layout(controller.request(row))
            controller.storeLayout(layout)
            heights[row.id] = layout.height
        }
        controller.setHeights(heights)
        let first = try #require(controller.firstTextPosition)
        let last = try #require(controller.lastTextPosition)

        // Normal drag selection across many rows stays ragged-right.
        controller.setSelection(TranscriptSelection(anchor: first, focus: last))
        let dragRects = controller.taggedSelectionRects(from: first, to: last, columnX: 16, scrollX: { _ in 0 })
        #expect(dragRects.first?.isStart == true)
        #expect(dragRects.last?.isEnd == true)
        #expect(dragRects.count >= 80)
        #expect(dragRects.contains { $0.rect.width < 300 })

        // Select All always highlights full column width in 1-3 seamless strips.
        controller.setSelection(nil)
        controller.selectAll()
        let allRects = controller.taggedSelectionRects(from: first, to: last, columnX: 16, scrollX: { _ in 0 })
        #expect(allRects.first?.isStart == true)
        #expect(allRects.last?.isEnd == true)
        #expect(allRects.count <= 3)
        #expect(allRects.allSatisfy { $0.rect.minX == 16 && $0.rect.width == 320 })

        // O(log n) offset(from:to:) matches exact sum of row lengths + newlines.
        let expectedLen = controller.text(from: first, to: last).utf16.count
        #expect(controller.offset(from: first, to: last) == expectedLen)
        #expect(controller.offset(from: last, to: first) == -expectedLen)
    }

    /// Select All with an active selection inside a message selects all rows of
    /// that message (user or assistant) instead of the entire transcript.
    @Test func selectAllScopesToCurrentMessageWhenSelectionIsActive() throws {
        let controller = TranscriptController(configuration: .testing)
        controller.columnWidth = 320
        let rows = [
            TranscriptRow(
                id: "u1", kind: .userMessage([.paragraph([MarkdownInline(text: "User question")])]),
                messageID: "msg-user", role: .user),
            TranscriptRow(
                id: "a1", kind: .markdownBlock(.paragraph([MarkdownInline(text: "Agent part one")]), .single),
                messageID: "msg-agent", role: .assistant),
            TranscriptRow(
                id: "a2", kind: .markdownBlock(.code(language: "swift", code: "let x = 1"), .single),
                messageID: "msg-agent", role: .assistant),
            TranscriptRow(
                id: "u2", kind: .userMessage([.paragraph([MarkdownInline(text: "Follow up")])]),
                messageID: "msg-user-2", role: .user),
        ]
        controller.setRows(rows)
        controller.setSelection(
            TranscriptSelection(
                anchor: TextPosition(rowID: "a1", offset: 0),
                focus: TextPosition(rowID: "a1", offset: 5)))
        controller.selectAll()
        #expect(controller.selectedText() == "Agent part one\nlet x = 1")
    }
}
