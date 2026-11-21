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
}
