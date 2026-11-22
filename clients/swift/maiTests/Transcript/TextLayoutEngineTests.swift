import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import mai

/// One layout serves measuring, drawing, hit testing and selection (PLAN 3.1
/// rule 8): lines break at the width, paragraphs keep the chat's spacing and
/// indents, carets and decorations line up with the glyphs.
@MainActor
struct TextLayoutEngineTests {
    private let style = TextStyle.current()

    private func layout(_ blocks: [MarkdownBlock], width: CGFloat) -> TextLayout {
        RowLayoutBuilder.prose(blocks, width: width, style: style)
    }

    @Test func linesBreakWithinTheWidthAndCoverTheText() {
        let words = Array(repeating: "transcript", count: 60).joined(separator: " ")
        let text = layout([.paragraph([MarkdownInline(text: words)])], width: 300)
        #expect(text.lines.count > 3)
        #expect(text.lines.allSatisfy { $0.x + $0.width <= 300.5 })
        #expect(text.lines.first?.range.lowerBound == 0)
        #expect(text.lines.last?.range.upperBound == words.utf16.count)
        for (above, below) in zip(text.lines, text.lines.dropFirst()) {
            #expect(above.range.upperBound == below.range.lowerBound)
            #expect(below.top >= above.bottom)
        }
        #expect(text.size.height == ceil(text.lines.last?.bottom ?? 0))
    }

    @Test func blocksAreSeparatedByTheBlockSpacing() {
        let one = layout([.paragraph([MarkdownInline(text: "One")])], width: 400)
        let two = layout(
            [.paragraph([MarkdownInline(text: "One")]), .paragraph([MarkdownInline(text: "Two")])], width: 400)
        let lineHeight = one.lines[0].height
        #expect(two.lines.count == 2)
        #expect(two.lines[1].top == lineHeight + style.lineSpacing + style.blockSpacing)
    }

    @Test func listItemsHangTheirTextAfterTheMarker() {
        let item = Array(repeating: "wrapping", count: 30).joined(separator: " ")
        let list = layout(
            [.list(MarkdownList(startIndex: nil, items: [[.paragraph([MarkdownInline(text: item)])]]))], width: 300)
        #expect(list.lines.count > 1)
        #expect(list.lines[0].x == 0)
        #expect(list.lines.dropFirst().allSatisfy { $0.x == style.listIndent })
        #expect(list.string.hasPrefix("•  "))
    }

    @Test func caretsRunLeftToRightAcrossEachLine() {
        let text = layout([.paragraph([MarkdownInline(text: "Carets café 👩🏽‍💻 end")])], width: 1_000)
        let line = text.lines[0]
        #expect(line.caretOffsets.count == line.range.count + 1)
        #expect(zip(line.caretOffsets, line.caretOffsets.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(abs((line.caretOffsets.last ?? 0) - (line.x + line.width)) < 1)
    }

    /// Carets from glyph positions match Core Text's at every character
    /// boundary, and stay at a cluster's start inside it.
    @Test(arguments: [
        "Plain ASCII text, with punctuation; and (brackets) 123.",
        "café naïve résumé and cafe\u{301} decomposed",
        "Emoji 👩🏽‍💻 🎉 and flags 🇨🇦 in a line",
        "漢字かな交じり文 with Latin",
        "office fifty flow affix ffl",
        "func consume(ctx context.Context) -> Int { 42 }",
    ])
    func glyphCaretsMatchCoreText(text: String) {
        for font in [style.font(.body).font, style.font(.code).font] {
            let attributed = NSAttributedString(
                string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let line = CTLineCreateWithAttributedString(attributed)
            let range = 0..<attributed.length
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let glyphs = TextLayoutEngine.caretOffsets(
                of: line, range: range, string: attributed.string as NSString, indent: 4, width: width)
            let system = TextLayoutEngine.enumeratedCaretOffsets(of: line, range: range, indent: 4, width: width)
            #expect(glyphs.count == system.count)
            #expect(zip(glyphs, glyphs.dropFirst()).allSatisfy { $0 <= $1 })
            var boundary = 0
            for character in text {
                #expect(abs(glyphs[boundary] - system[boundary]) < 0.5, "\(text) at \(boundary)")
                let next = boundary + character.utf16.count
                for inside in (boundary + 1)..<max(boundary + 1, next) {
                    #expect(glyphs[inside] == glyphs[boundary], "inside a cluster of \(text) at \(inside)")
                }
                boundary = next
            }
            #expect(abs(glyphs[boundary] - system[boundary]) < 0.5)
        }
    }

    @Test func inlineCodeLinksAndStrikethroughGetDecorations() {
        let text = layout(
            [
                .paragraph([
                    MarkdownInline(text: "Run "), MarkdownInline(text: "make", style: .code),
                    MarkdownInline(text: " or "),
                    MarkdownInline(text: "read", link: URL(string: "https://example.com")),
                    MarkdownInline(text: " not", style: .strikethrough),
                ])
            ], width: 1_000)
        let kinds = text.decorations.map(\.kind)
        #expect(kinds.contains(.inlineCodeBackground))
        #expect(kinds.contains(.underline))
        #expect(kinds.contains(.strikethrough))
        #expect(text.links.first == URL(string: "https://example.com"))
        #expect(text.runs.contains { $0.linkIndex == 0 })
    }

    @Test func codeKeepsLinesUnwrappedWithAnAnalyticHeight() {
        let code = "let a = 1\n" + String(repeating: "x", count: 400) + "\nend"
        let block = CodeLayout.make(code: code, language: "swift", colors: nil, width: 300, style: style)
        #expect(block.body.lines.count == 3)
        #expect(block.isWiderThanBlock)
        #expect(block.size.height == ceil(style.codeHeaderHeight + 3 * style.codeLineHeight + style.codeBottomInset))
        #expect(CodeLayout.displayName("py") == "Python")
    }

    @Test func tablesSizeColumnsWithinTheirLimits() {
        let table = MarkdownTable(
            alignments: [.leading, .trailing],
            header: [[MarkdownInline(text: "Name")], [MarkdownInline(text: "Value")]],
            rows: [[[MarkdownInline(text: "a")], [MarkdownInline(text: "1")]]])
        let layout = TableLayout.make(table, width: 760, style: style)
        #expect(layout.cells.count == 4)
        #expect(layout.dividers.count == 1)
        #expect(layout.gridSize.width >= 2 * style.tableMinimumColumnWidth + style.tableColumnSpacing)
        #expect(TableLayout.tabSeparatedText(table) == "Name\tValue\na\t1")
    }

    /// A CRLF code block is as tall as its lines: "\r\n" is one Character,
    /// so counting Characters saw one line and clipped the rest.
    @Test func crlfCodeHasOneLinePerLine() {
        let crlf = CodeLayout.make(code: "a\r\nb\r\nc", language: nil, colors: nil, width: 400, style: style)
        let lf = CodeLayout.make(code: "a\nb\nc", language: nil, colors: nil, width: 400, style: style)
        #expect(crlf.size.height == lf.size.height)
    }

    /// A list's bullet follows how deep in lists it is: two quotes indent as
    /// much as a list, and used to make a top-level list's bullet `◦`.
    @Test func aListInQuotesStartsAtTheFirstBullet() {
        let list = MarkdownBlock.list(MarkdownList(startIndex: nil, items: [[.paragraph([MarkdownInline(text: "a")])]]))
        let text = AttributedTextBuilder.build([.quote([.quote([list])])], style: style)
        #expect(text.string.string.hasPrefix("•"))
    }

    /// An item that starts with code or a nested list still shows its marker.
    @Test func aListItemStartingWithABlockKeepsItsMarker() {
        let code = AttributedTextBuilder.build(
            [.list(MarkdownList(startIndex: nil, items: [[.code(language: nil, code: "make")]]))], style: style)
        #expect(code.string.string.hasPrefix("•"))
        #expect(code.string.string.hasSuffix("make"))
        let numbered = AttributedTextBuilder.build(
            [.list(MarkdownList(startIndex: 3, items: [[.code(language: nil, code: "make")]]))], style: style)
        #expect(numbered.string.string.hasPrefix("3."))
    }

    /// The newline ending a paragraph is in that paragraph's font: in the
    /// body font, the last line of code in a quote was taller than the rest.
    @Test func aParagraphBreakDoesNotRaiseTheLineItEnds() {
        let layout = layout(
            [.quote([.code(language: nil, code: "a\nb"), .paragraph([MarkdownInline(text: "x")])])], width: 500)
        #expect(layout.lines.count == 3)
        #expect(layout.lines[0].height == layout.lines[1].height)
    }

    /// A table's last column's cells end at the grid: their boxes (hit
    /// testing, selection) reached half a column spacing past it.
    @Test func theLastColumnsBoxesEndAtTheGrid() {
        for columns in 1...3 {
            let cell = [MarkdownInline(text: "x")]
            let table = MarkdownTable(
                alignments: Array(repeating: .leading, count: columns), header: Array(repeating: cell, count: columns),
                rows: [Array(repeating: cell, count: columns)])
            let layout = TableLayout.make(table, width: 400, style: style)
            let last = layout.cells.filter { $0.column == columns - 1 }
            #expect(last.allSatisfy { abs($0.box.maxX - layout.gridSize.width) < 1 }, "\(columns) columns")
        }
    }

    /// Core Text reorders a Devanagari vowel sign before its consonant, so
    /// glyph order is not text order there: those lines take Core Text's
    /// carets, and a trailing edge never lands inside an emoji's pair.
    @Test func reorderedAndRightToLeftLinesTakeCoreTextsCarets() {
        for text in ["हिन्दी किताब", "שלום 👋 עולם"] {
            let attributed = NSAttributedString(
                string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): style.font(.body).font])
            let line = CTLineCreateWithAttributedString(attributed)
            let range = 0..<attributed.length
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let string = attributed.string as NSString
            let carets = TextLayoutEngine.caretOffsets(of: line, range: range, string: string, indent: 0, width: width)
            #expect(
                carets == TextLayoutEngine.enumeratedCaretOffsets(
                    of: line, range: range, string: string, indent: 0, width: width))
            let emoji = string.range(of: "👋")
            if emoji.location != NSNotFound { #expect(carets[emoji.location + 1] == carets[emoji.location]) }
        }
    }

    /// Incremental streaming layouts for prose, code and tables match one-shot
    /// layout bit-for-bit.
    @Test func incrementalLayoutsMatchFullLayout() {
        // 1. Prose paragraph growth.
        let words = ["stream", "layout", "**bold**", "`code`", "café", "👩🏽‍💻", "text", "frame"]
        let part1 = (0..<80).map { words[$0 % words.count] }.joined(separator: " ")
        let part2 = part1 + " " + (0..<40).map { words[$0 % words.count] }.joined(separator: " ")
        let block1 = MarkdownPlanner.blocks(from: part1)[0]
        let block2 = MarkdownPlanner.blocks(from: part2)[0]
        let kind1 = TranscriptRowKind.markdownBlock(block1, .init(isFirst: true, isLast: true))
        let kind2 = TranscriptRowKind.markdownBlock(block2, .init(isFirst: true, isLast: true))
        let key = RowLayoutKey(contentVersion: 0, width: 420, styleVersion: style.version)
        let first = RowLayoutBuilder.layout(RowLayoutRequest(rowID: "p", kind: kind1, key: key, style: style))
        var incReq = RowLayoutRequest(rowID: "p", kind: kind2, key: key, style: style)
        incReq.previous = (kind1, first)
        let incremental = RowLayoutBuilder.layout(incReq)
        let full = RowLayoutBuilder.layout(RowLayoutRequest(rowID: "p", kind: kind2, key: key, style: style))
        #expect(incremental.height == full.height)
        if case .text(let a, _) = incremental.content, case .text(let b, _) = full.content {
            #expect(a.size == b.size)
            #expect(a.lines.count == b.lines.count)
            #expect(RowContentDiff.unchangedHeight(a, b) == .infinity)
        } else {
            Issue.record("expected text layouts")
        }

        // 2. Code fence growth (including CRLF).
        let code1 = "line 0\r\nline 1\r\nline 2\r\nline 3\r\nline 4"
        let code2 = code1 + "\r\nline 5\r\nline 6"
        let c1 = CodeLayout.make(code: code1, language: "go", colors: nil, width: 400, style: style)
        let c2Inc = CodeLayout.make(code: code2, language: "go", colors: nil, width: 400, style: style, previous: c1)
        let c2Full = CodeLayout.make(code: code2, language: "go", colors: nil, width: 400, style: style)
        #expect(c2Inc.size == c2Full.size)
        #expect(c2Inc.body.lines.count == 7)
        #expect(RowContentDiff.unchangedHeight(c2Inc.body, c2Full.body) == .infinity)

        // 3. Table growth.
        let t1 = MarkdownTable(
            alignments: [.leading, .trailing],
            header: [[MarkdownInline(text: "A")], [MarkdownInline(text: "B")]],
            rows: (0..<10).map { [[MarkdownInline(text: "row\($0)")], [MarkdownInline(text: "\($0)")]] })
        let t2 = MarkdownTable(
            alignments: t1.alignments, header: t1.header,
            rows: t1.rows + [[[MarkdownInline(text: "row10")], [MarkdownInline(text: "10")]]])
        let tl1 = TableLayout.make(t1, width: 500, style: style)
        let tl2Inc = TableLayout.make(t2, width: 500, style: style, previous: tl1)
        let tl2Full = TableLayout.make(t2, width: 500, style: style)
        #expect(tl2Inc.size == tl2Full.size)
        #expect(RowContentDiff.unchangedHeight(.tableBody(tl2Inc), .tableBody(tl2Full)) == .infinity)
    }
}
