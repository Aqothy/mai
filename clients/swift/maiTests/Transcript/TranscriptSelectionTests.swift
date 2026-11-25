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
                id: "user|t|u", sourceID: "t|u", kind: .userMessage(source: "Hello there"), messageID: "t|u",
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
        #expect(abs(rects[0].minX - first.caretOffsets[6]) < 0.01)
        #expect(abs(rects[1].maxX - second.caretOffsets[2]) < 0.01)
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
}
