import CoreGraphics
import Foundation
import Testing

@testable import mai

/// A new width does as little as it can (PLAN 4.2): code keeps its text and
/// colors, and rows whose lines break where they did keep their bitmaps.
@MainActor
struct TranscriptResizeTests {
    private let style = TextStyle.current()

    private func layout(_ kind: TranscriptRowKind, width: CGFloat, previousCode: CodeLayout? = nil) -> RowLayout {
        var request = RowLayoutRequest(
            rowID: "row", kind: kind, key: RowLayoutKey(contentVersion: 0, width: width, styleVersion: style.version),
            style: style)
        request.previousCode = previousCode
        request.codeColors = previousCode?.colors
        return RowLayoutBuilder.layout(request)
    }

    @Test func codeAtANewWidthReusesItsTextAndColorsAndRedrawsNothing() {
        let code = "let x = 1\nprint(x)"
        let kind = TranscriptRowKind.markdownBlock(
            .code(language: "swift", code: code), .init(isFirst: true, isLast: true))
        let colors = CodeColors(
            code: code, runs: [.init(range: 0..<3, color: .rgba(red: 1, green: 0, blue: 0, alpha: 1))], isDark: true)
        let colored = CodeLayout.make(code: code, language: "swift", colors: colors, width: 600, style: style)
        let old = layout(kind, width: 600, previousCode: colored)
        let new = layout(kind, width: 520, previousCode: colored)
        guard case .code(let resized, let frame) = new.content else {
            Issue.record("not code")
            return
        }
        #expect(frame.width == 520)
        #expect(resized.isHighlighted)
        #expect(resized.body.runs.map(\.glyphs) == colored.body.runs.map(\.glyphs))
        #expect(RowContentDiff.unchangedHeight(old.content, new.content) == .infinity)
    }

    @Test func proseWhoseLinesBreakTheSameRedrawsNothing() {
        let kind = TranscriptRowKind.markdownBlock(
            .paragraph([MarkdownInline(text: "Short line.")]), .init(isFirst: true, isLast: true))
        let wide = layout(kind, width: 600)
        let narrower = layout(kind, width: 560)
        #expect(RowContentDiff.unchangedHeight(wide.content, narrower.content) == .infinity)

        let long = TranscriptRowKind.markdownBlock(
            .paragraph([MarkdownInline(text: String(repeating: "words that wrap ", count: 30))]),
            .init(isFirst: true, isLast: true))
        let reflowed = RowContentDiff.unchangedHeight(layout(long, width: 600).content, layout(long, width: 300).content)
        #expect(reflowed < .infinity)
    }

    /// A streamed code block keeps the colors of its last highlight for the
    /// code they were made for, and is not highlighted until the rest is.
    @Test func grownCodeKeepsItsColorsForThePartTheyCover() {
        let old = "let x = 1"
        let colors = CodeColors(
            code: old, runs: [.init(range: 0..<3, color: .rgba(red: 1, green: 0, blue: 0, alpha: 1))], isDark: true)
        let grown = old + "\nprint(x)"
        #expect(colors.apply(to: grown, isDark: true))
        #expect(!colors.apply(to: grown, isDark: false))
        #expect(!colors.apply(to: "var y", isDark: true))
        let layout = CodeLayout.make(code: grown, language: "swift", colors: colors, width: 600, style: style)
        #expect(!layout.isHighlighted)
        #expect(layout.colorsAreDark == true)
        let red = TextColor.rgba(red: 1, green: 0, blue: 0, alpha: 1)
        #expect(layout.body.runs.contains { $0.color == red })
    }
}
