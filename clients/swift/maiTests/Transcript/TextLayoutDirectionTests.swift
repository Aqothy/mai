import CoreGraphics
import Foundation
import Testing

@testable import mai

/// UAX #9 base direction (`dir="auto"`) in layout: decided once per
/// paragraph, and only where a paragraph aligns to the available width.
nonisolated struct TextLayoutDirectionTests {
    /// The base direction is the paragraph's, so `Builder` decides it once per
    /// paragraph. A long line with no strong character (digits, punctuation,
    /// emoji) scans to its end to find none: once is O(length), per wrapped
    /// line it was O(lines x length) (128 KB of digits: 4.0 s vs 0.10 s).
    @Test(.serialized) func aNeutralParagraphLaysOutAsFastAsALetterParagraph() async {
        let style = await TextStyle.current()
        let options = TextLayoutEngine.Options(lineSpacing: style.lineSpacing, quoteBarWidth: style.quoteBarWidth)
        func best(_ unit: String) -> Duration {
            let text = String(repeating: unit, count: 128 * 1_024 / unit.utf16.count)
            let styled = AttributedTextBuilder.build([.paragraph([MarkdownInline(text: text)])], style: style)
            var fastest = Duration.seconds(1_000)
            for _ in 0..<2 {
                let start = ContinuousClock.now
                _ = TextLayoutEngine.layout(styled, width: 600, options: options)
                fastest = min(fastest, ContinuousClock.now - start)
            }
            return fastest
        }
        let letters = best("abcd ")
        let digits = best("1234 ")
        #expect(digits < letters * 3, "128 KB digits \(digits) vs letters \(letters)")
    }

    /// Table cells are measured at the maximum column width to find their
    /// natural width; right-aligning an RTL cell to that width would make
    /// every Hebrew or Arabic column the maximum width.
    @Test func aShortRightToLeftCellKeepsItsColumnAsNarrowAsLeftToRightText() async {
        let style = await TextStyle.current()
        func table(_ cell: String) -> TableLayout {
            TableLayout.make(
                MarkdownTable(
                    alignments: [.leading], header: [[MarkdownInline(text: "Name")]],
                    rows: [[[MarkdownInline(text: cell)]]]),
                width: 700, style: style)
        }
        let ltr = table("abcd")
        let rtl = table("שלום")
        #expect(rtl.gridSize.width == ltr.gridSize.width, "rtl \(rtl.gridSize.width) vs ltr \(ltr.gridSize.width)")
        #expect(rtl.gridSize.width < style.tableMaximumColumnWidth)
    }

    /// RTL lines in quotes or lists right-align inside `[indent, availableWidth]`
    /// so full wrapped lines never draw over left-side quote bars or markers.
    @Test func rtlIndentedLinesStayPastQuoteAndListIndent() async {
        #expect(TextLayoutEngine.lineOriginX(indent: 20, lineWidth: 380, availableWidth: 400, isRTL: true) == 20)
        #expect(TextLayoutEngine.lineOriginX(indent: 20, lineWidth: 100, availableWidth: 400, isRTL: true) == 300)
        let style = await TextStyle.current()
        let quoted = AttributedTextBuilder.build(
            [.quote([.paragraph([MarkdownInline(text: String(repeating: "مرحبا بالعالم ", count: 20))])])],
            style: style)
        let layout = TextLayoutEngine.layout(
            quoted, width: 320,
            options: .init(lineSpacing: style.lineSpacing, quoteBarWidth: style.quoteBarWidth))
        #expect(layout.lines.count >= 2)
        for line in layout.lines {
            #expect(line.x >= style.quoteIndent - 0.5)
        }
    }

    /// BiDi selection rects track cumulative run x (not glyph 0's GPOS offset
    /// on a trailing combining mark), keep the newline tail, and `link(at:)`
    /// uses per-run visual bounds on complex BiDi lines.
    @Test func bidiSelectionRectsNewlineTailAndLinkHitTestingAreExact() async throws {
        let style = await TextStyle.current()
        let options = TextLayoutEngine.Options(lineSpacing: style.lineSpacing, quoteBarWidth: style.quoteBarWidth)

        // Trailing combining mark in RTL run must not shift the selection rect right into " def".
        let combined = AttributedTextBuilder.build([.paragraph([MarkdownInline(text: "abc شً def\nnext")])], style: style)
        let combinedLayout = TextLayoutEngine.layout(combined, width: 400, options: options)
        let line0 = try #require(combinedLayout.lines.first)
        #expect(line0.hasComplexBiDi)
        let rtlRect = try #require(combinedLayout.selectionRects(for: 4..<6).first)
        let ltrAfterRect = try #require(combinedLayout.selectionRects(for: 6..<10).first)
        #expect(rtlRect.maxX <= ltrAfterRect.minX + 0.5)

        // Selecting across a BiDi line's newline preserves the newline indicator width.
        let withoutNewline = combinedLayout.selectionRects(for: 0..<10).map(\.maxX).max() ?? 0
        let withNewline = combinedLayout.selectionRects(for: 0..<11).map(\.maxX).max() ?? 0
        #expect(withNewline > withoutNewline + 1)

        // Arabic link before LTR text must be clickable over the Arabic run, not zero-width.
        let url = try #require(URL(string: "https://example.com/rtl"))
        let linkStyled = AttributedTextBuilder.build(
            [.paragraph([MarkdownInline(text: "مرحبا", link: url), MarkdownInline(text: " world")])],
            style: style)
        let linkLayout = TextLayoutEngine.layout(linkStyled, width: 400, options: options)
        let linkLine = try #require(linkLayout.lines.first)
        #expect(linkLine.hasComplexBiDi)
        let midY = (linkLine.top + linkLine.bottom) / 2
        let arabicRect = try #require(linkLayout.selectionRects(for: 0..<5).first)
        let worldRect = try #require(linkLayout.selectionRects(for: 6..<11).first)
        #expect(linkLayout.link(at: CGPoint(x: arabicRect.midX, y: midY)) == url)
        #expect(linkLayout.link(at: CGPoint(x: worldRect.midX, y: midY)) == nil)
    }
}
