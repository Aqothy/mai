import CoreGraphics
import CoreText
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

    /// Colors are for one text: code that changed (a streamed block that
    /// grew) is plain until highlighted again, never partly colored.
    @Test func colorsApplyOnlyToTheCodeTheyWereMadeFor() {
        let old = "let x = 1"
        let colors = CodeColors(
            code: old, runs: [.init(range: 0..<3, color: .rgba(red: 1, green: 0, blue: 0, alpha: 1))], isDark: true)
        #expect(colors.matches(code: old, isDark: true))
        #expect(!colors.matches(code: old, isDark: false))
        #expect(!colors.matches(code: old + "\nprint(x)", isDark: true))
        let grown = CodeLayout.make(code: old + "\nprint(x)", language: "swift", colors: colors, width: 600, style: style)
        #expect(!grown.isHighlighted)
        #expect(CodeLayout.make(code: old, language: "swift", colors: colors, width: 600, style: style).isHighlighted)
    }

    /// What draws differently is redrawn even when the glyphs do not move:
    /// a rule's line spans the new width, a strikethrough appears, a code
    /// label takes a new text size.
    @Test func decorationsAndLabelsRedrawWhenOnlyTheyChange() {
        let rule = TranscriptRowKind.markdownBlock(.rule(spelling: "---"), .init(isFirst: true, isLast: true))
        #expect(
            RowContentDiff.unchangedHeight(layout(rule, width: 600).content, layout(rule, width: 300).content)
                < .infinity)

        let plain = RowLayoutBuilder.prose([.paragraph([MarkdownInline(text: "abc")])], width: 400, style: style)
        let struck = RowLayoutBuilder.prose(
            [.paragraph([MarkdownInline(text: "abc", style: .strikethrough)])], width: 400, style: style)
        #expect(RowContentDiff.unchangedHeight(plain, struck) < .infinity)

        let bigger = TextStyle(version: style.version + 1) { role in
            CTFontCreateCopyWithAttributes(style.font(role).font, CTFontGetSize(style.font(role).font) + 4, nil, nil)
        }
        let small = CodeLayout.make(code: "let a = 1", language: "swift", colors: nil, width: 400, style: style)
        let large = CodeLayout.make(code: "let a = 1", language: "swift", colors: nil, width: 400, style: bigger)
        let frame = CGRect(x: 0, y: 8, width: 400, height: 0)
        #expect(
            RowContentDiff.unchangedHeight(
                .code(small, frame: frame), .code(large, frame: frame)) < frame.minY + small.headerHeight)
    }
}
