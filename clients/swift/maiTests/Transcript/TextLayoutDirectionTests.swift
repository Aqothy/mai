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
    @Test func aNeutralParagraphLaysOutAsFastAsALetterParagraph() async {
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
}
