import CoreGraphics
import Foundation
import Testing

@testable import mai

/// PLAN 5: one selection across prose, code, tables and messages, in text
/// positions, copied as plain text (code verbatim, tables tab-separated),
/// with the Comment target rules of Q4.
@MainActor
struct TranscriptSelectionTests {
    private let style = TextStyle.current()

    private let table = MarkdownTable(
        alignments: [.leading, .leading],
        header: [[MarkdownInline(text: "Name")], [MarkdownInline(text: "Value")]],
        rows: [[[MarkdownInline(text: "a")], [MarkdownInline(text: "1")]]])

    private func blocks() -> [MarkdownBlock] {
        [
            .paragraph([MarkdownInline(text: "First paragraph.")]),
            .code(language: "swift", code: "let x = 1\nprint(x)"),
            .table(table),
        ]
    }

    /// A user message, then an assistant message of three blocks.
    private func rows() -> [TranscriptRow] {
        var rows = [
            TranscriptRow(
                id: "user|t|u", sourceID: "t|u",
                kind: .userMessage([.paragraph([MarkdownInline(text: "Hello there")])]), messageID: "t|u",
                role: .user)
        ]
        let blocks = blocks()
        for index in blocks.indices {
            rows.append(
                TranscriptRow(
                    id: "t|a#\(index)", sourceID: "t|a", kind: .markdownBlock(blocks[index], .of(index, in: blocks)),
                    messageID: "t|a", role: .assistant))
        }
        rows.append(TranscriptRow(id: "actions|t", kind: .turnActions(turnID: "t", hasReply: false)))
        return rows
    }

    private func make() -> TranscriptController {
        let controller = TranscriptController(configuration: .testing)
        let rows = rows()
        controller.setRows(rows, measuredHeights: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, 40) }))
        return controller
    }

    @Test func aSelectionAcrossBlocksCopiesCodeVerbatimAndTablesTabSeparated() {
        let controller = make()
        controller.setSelection(
            TranscriptSelection(
                anchor: TextPosition(rowID: "t|a#0", offset: 6), focus: TextPosition(rowID: "t|a#2", offset: 10)))
        #expect(controller.selectedText() == "paragraph.\nlet x = 1\nprint(x)\nName\tValue")
        #expect(controller.selectedRange(inRowAt: 1) == 6..<16)
        #expect(controller.selectedRange(inRowAt: 2) == 0..<18)
        #expect(controller.selectedRange(inRowAt: 3) == 0..<10)
        #expect(controller.selectedRange(inRowAt: 4) == nil)
    }

    @Test func aBackwardSelectionReadsTheSame() {
        let controller = make()
        controller.setSelection(
            TranscriptSelection(
                anchor: TextPosition(rowID: "t|a#2", offset: 10), focus: TextPosition(rowID: "t|a#0", offset: 6)))
        #expect(controller.selectedText() == "paragraph.\nlet x = 1\nprint(x)\nName\tValue")
    }

    @Test func selectAllSpansEverySelectableRowAndSkipsChrome() {
        let controller = make()
        controller.selectAll()
        #expect(controller.selectedText().hasPrefix("Hello there\nFirst paragraph."))
        #expect(controller.selectedText().hasSuffix("Name\tValue\na\t1"))
    }

    @Test func commentTargetsOneMessageOrNoneAcrossMessages() {
        let controller = make()
        controller.setSelection(
            TranscriptSelection(
                anchor: TextPosition(rowID: "t|a#0", offset: 0), focus: TextPosition(rowID: "t|a#1", offset: 3)))
        #expect(controller.selectionCommentTarget().messageID == "t|a")
        #expect(controller.selectionCommentTarget().role == "assistant")

        controller.setSelection(
            TranscriptSelection(
                anchor: TextPosition(rowID: "user|t|u", offset: 0), focus: TextPosition(rowID: "t|a#0", offset: 3)))
        #expect(controller.selectionCommentTarget().messageID == nil)
        #expect(controller.selectionCommentTarget().role == nil)
    }

    @Test func wordsAndParagraphsSelectWithinARow() {
        let controller = make()
        let word = controller.wordRange(around: TextPosition(rowID: "t|a#0", offset: 8))
        #expect(word?.anchor.offset == 6)
        #expect(word?.focus.offset == 15)
        let line = controller.paragraphRange(around: TextPosition(rowID: "t|a#1", offset: 2))
        #expect(line?.anchor.offset == 0)
        #expect(line?.focus.offset == 9)
    }

    /// A double-click never selects part of a grapheme cluster, as a browser
    /// snaps word boundaries to clusters: the system's word tokenizer cuts
    /// `n` from its combining marks next to kana (the selection fuzzer at
    /// scale 50 found it: seed 0, iteration 10).
    @Test func aWordRangeNeverCutsAGraphemeCluster() {
        let controller = TranscriptController(configuration: .testing)
        let text = ".✌︎かな()n\u{0308}\u{0308}a🇦🇧🇨fi\u{00AD}.✌︎ 👍ສະ"
        let row = TranscriptRow(id: "p", kind: .markdownBlock(.paragraph([MarkdownInline(text: text)]), .single))
        controller.setRows([row], measuredHeights: ["p": 40])
        let ns = text as NSString
        for offset in 0..<ns.length where ns.rangeOfComposedCharacterSequence(at: offset).location == offset {
            guard let word = controller.wordRange(around: TextPosition(rowID: "p", offset: offset)) else { continue }
            for edge in [word.anchor.offset, word.focus.offset] where edge < ns.length {
                #expect(
                    ns.rangeOfComposedCharacterSequence(at: edge).location == edge,
                    "word around \(offset) is \(word.anchor.offset)..<\(word.focus.offset): \(edge) cuts a cluster")
            }
        }
    }

    /// Word and character ranges never cross a line terminator onto the line
    /// before (bare combining mark starting a line), and clicking past a line
    /// ending in a Unicode line separator stays before that break.
    @Test func lineTerminatorsEndClustersAndClampLineEndClicks() {
        let controller = TranscriptController(configuration: .testing)
        for sample in ["abc\n\u{0301}def", "abc\u{2028}\u{0301}def"] {
            let row = TranscriptRow(id: "p", kind: .markdownBlock(.paragraph([MarkdownInline(text: sample)]), .single))
            controller.setRows([row], measuredHeights: ["p": 60])
            let atMark = TextPosition(rowID: "p", offset: 4)
            let charRange = controller.characterRange(around: atMark)
            #expect(charRange?.anchor.offset == 4 && charRange?.focus.offset == 5, "\(sample): char \(String(describing: charRange))")
            let wordRange = controller.wordRange(around: atMark)
            #expect((wordRange?.anchor.offset ?? 0) >= 4, "\(sample): word \(String(describing: wordRange)) crossed break")
        }
        let laid = RowLayoutBuilder.prose([.paragraph([MarkdownInline(text: "abc\u{2028}def")])], width: 400, style: style)
        #expect(laid.lines.count == 2)
        #expect(laid.lines[0].endsWithNewline)
        #expect(laid.offset(closestTo: CGPoint(x: 390, y: laid.lines[0].top + 1)) == 3)
    }

    /// Rows far from the viewport have no layout: their text, built from
    /// their content, must match what their layout would select.
    @Test func textWithoutALayoutMatchesTheLayoutsText() {
        for row in rows() where row.kind.isSelectable {
            let layout = RowLayoutBuilder.layout(
                RowLayoutRequest(
                    rowID: row.id, kind: row.kind,
                    key: RowLayoutKey(contentVersion: 0, width: 500, styleVersion: style.version), style: style))
            #expect(RowSelectableText.string(for: row.kind, style: style) == layout.content.selectableString)
            #expect(layout.content.selectableString.utf16.count == layout.content.selectableLength)
        }
    }

    @Test func pointsMapToOffsetsAndBackToRects() {
        let text = RowLayoutBuilder.prose(
            [.paragraph([MarkdownInline(text: "Alpha beta")]), .paragraph([MarkdownInline(text: "Gamma")])],
            width: 400, style: style)
        let first = text.lines[0]
        let second = text.lines[1]
        #expect(first.endsWithNewline)
        // Past the end of a line ending in a newline: before the newline.
        #expect(text.offset(closestTo: CGPoint(x: 390, y: first.top + 1)) == 10)
        #expect(text.offset(closestTo: CGPoint(x: -5, y: second.top + 1)) == 11)
        #expect(text.offset(closestTo: CGPoint(x: 0, y: -20)) == 0)
        #expect(text.offset(closestTo: CGPoint(x: 0, y: text.size.height + 20)) == text.length)
        let rects = text.selectionRects(for: 6..<13)
        #expect(rects.count == 2)
        #expect(abs(rects[0].minX - text.caretOffsets(forLineAt: 0)[6]) < 0.01)
        #expect(abs(rects[1].maxX - text.caretOffsets(forLineAt: 1)[2]) < 0.01)
    }

    @Test func tableCellsHitTestWithinTheirBoxes() {
        let layout = RowLayoutBuilder.layout(
            RowLayoutRequest(
                rowID: "table", kind: .markdownBlock(.table(table), .init(isFirst: true, isLast: true)),
                key: RowLayoutKey(contentVersion: 0, width: 500, styleVersion: style.version), style: style))
        guard case .table(let tableLayout, let frame) = layout.content else {
            Issue.record("not a table")
            return
        }
        let cell = tableLayout.cells[3]  // the "1" cell
        let point = CGPoint(
            x: frame.minX + cell.box.midX, y: frame.minY + tableLayout.toolbarHeight + cell.box.midY)
        let offset = layout.content.textOffset(closestTo: point)
        // "Name\tValue\na\t" is 13 characters; the cell's text starts there.
        #expect(offset == 13 || offset == 14)
    }

    /// When a selection's start or end row has scrolled off-screen (no cached
    /// layout), `taggedSelectionRects` must not attach `isStart` or `isEnd`
    /// handles to mid-selection visible rows.
    @Test func offscreenSelectionEndpointsNeverTagMiddleRowsAsHandles() {
        let controller = make()
        controller.columnWidth = 500
        // Lay out only the middle row `t|a#0` (index 1); leave start `user|t|u`
        // (index 0) and end `t|a#1` (index 2) without layouts (off-screen).
        let middle = controller.rows[1]
        controller.storeLayout(RowLayoutBuilder.layout(controller.request(middle)))
        let tagged = controller.taggedSelectionRects(
            from: TextPosition(rowID: "user|t|u", offset: 0),
            to: TextPosition(rowID: "t|a#1", offset: 5),
            columnX: 0, scrollX: { _ in 0 })
        #expect(!tagged.isEmpty)
        #expect(tagged.allSatisfy { !$0.isStart && !$0.isEnd })

        // Lay out start row too: now only the first rect has `isStart`.
        controller.storeLayout(RowLayoutBuilder.layout(controller.request(controller.rows[0])))
        let withStart = controller.taggedSelectionRects(
            from: TextPosition(rowID: "user|t|u", offset: 0),
            to: TextPosition(rowID: "t|a#1", offset: 5),
            columnX: 0, scrollX: { _ in 0 })
        #expect(withStart.first?.isStart == true)
        #expect(withStart.dropFirst().allSatisfy { !$0.isStart })
        #expect(withStart.allSatisfy { !$0.isEnd })
    }

    /// `position(from:offset:)` never lands inside an Apple composed character
    /// sequence (surrogate pair or combining mark), `positionVertically` moves
    /// by visual lines, and `tokenBoundaryRange` clamps to row / table-cell bounds.
    @Test func positionSnapsClustersMovesVerticallyAndClampsTokenBounds() throws {
        let controller = TranscriptController(configuration: .testing)
        controller.columnWidth = 400
        let rows = [
            TranscriptRow(
                id: "r0", sourceID: "m",
                kind: .markdownBlock(.paragraph([MarkdownInline(text: "👍n\u{0308}a\nSecond line")]), .single)),
            TranscriptRow(
                id: "r1", sourceID: "m",
                kind: .markdownBlock(.table(table), .single)),
        ]
        controller.setRows(rows, measuredHeights: ["r0": 60, "r1": 100])
        for row in controller.rows {
            controller.storeLayout(RowLayoutBuilder.layout(controller.request(row)))
        }
        // Step +1 from 0 across 2-unit emoji "👍" snaps forward to offset 2.
        let afterEmoji = try #require(controller.position(from: TextPosition(rowID: "r0", offset: 0), offset: 1))
        #expect(afterEmoji == TextPosition(rowID: "r0", offset: 2))
        // Step -1 from 2 back across "👍" snaps backward to offset 0.
        let backEmoji = try #require(controller.position(from: afterEmoji, offset: -1))
        #expect(backEmoji == TextPosition(rowID: "r0", offset: 0))
        // Step +1 from 2 across "n\u{0308}" snaps forward to offset 4 ('a').
        let afterCombined = try #require(controller.position(from: afterEmoji, offset: 1))
        #expect(afterCombined == TextPosition(rowID: "r0", offset: 4))

        // Vertical line movement from line 0 -> line 1 -> line 2 without stalling
        // at line starts (`line[0].upperBound == line[1].lowerBound`).
        let rows3 = [
            TranscriptRow(
                id: "m3", sourceID: "m",
                kind: .markdownBlock(.paragraph([MarkdownInline(text: "First\nSecond\nThird")]), .single))
        ]
        controller.setRows(rows3, measuredHeights: ["m3": 90])
        controller.storeLayout(RowLayoutBuilder.layout(controller.request(controller.rows[0])))
        let line1Start = try #require(
            controller.positionVertically(from: TextPosition(rowID: "m3", offset: 0), lineOffset: 1, columnX: 0))
        #expect(line1Start == TextPosition(rowID: "m3", offset: 6))
        let line2Start = try #require(
            controller.positionVertically(from: line1Start, lineOffset: 1, columnX: 0))
        #expect(line2Start == TextPosition(rowID: "m3", offset: 13))
        let backToLine0 = try #require(
            controller.positionVertically(from: line1Start, lineOffset: -1, columnX: 0))
        #expect(backToLine0 == TextPosition(rowID: "m3", offset: 0))

        // Strict hit test rejects empty space far to the right of a short line.
        #expect(controller.strictTextPosition(atDocumentPoint: CGPoint(x: 350, y: 10), columnX: 0) == nil)

        // Table cell token boundary clamps strictly to cell 0 ("Name", 0..<4).
        controller.setRows(rows, measuredHeights: ["r0": 60, "r1": 100])
        for row in controller.rows {
            controller.storeLayout(RowLayoutBuilder.layout(controller.request(row)))
        }
        let cellBounds = try #require(controller.tokenBoundaryRange(for: TextPosition(rowID: "r1", offset: 2)))
        #expect(cellBounds == 0..<4)
    }
}
