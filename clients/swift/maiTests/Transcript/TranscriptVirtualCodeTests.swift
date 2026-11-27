import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import mai

/// Unified `CodeLayout` (backed by `PreparedText` + `FontWidthTable` with
/// wrapping off and 4-column tab stops): exact widths for every script (no
/// 128 KB measuring budget), O(log lines) `memcmp` streaming diffs, and cached
/// per-line hit testing.
@MainActor
struct TranscriptVirtualCodeTests {
    private let style = TextStyle.current()

    private func exactBodyWidth(_ code: String) -> CGFloat {
        let attr = StyledText.attributedSlice(
            of: code as NSString,
            range: 0..<code.utf16.count,
            runs: [
                StyledRun(
                    range: 0..<code.utf16.count, font: style.font(.code), style: TextRunStyle(),
                    tabInterval: style.codeTabInterval)
            ])
        var maxW: CGFloat = 0
        for lineStr in code.components(separatedBy: "\n") {
            let lineAttr = StyledText.attributedSlice(
                of: lineStr as NSString,
                range: 0..<lineStr.utf16.count,
                runs: [
                    StyledRun(
                        range: 0..<lineStr.utf16.count, font: style.font(.code), style: TextRunStyle(),
                        tabInterval: style.codeTabInterval)
                ])
            let ct = CTLineCreateWithAttributedString(lineAttr)
            let w = CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(ct))
            maxW = max(maxW, w)
        }
        _ = attr
        return ceil(maxW)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    @Test(arguments: [
        String(repeating: "─", count: 60),
        String(repeating: "→ ", count: 40),
        String(repeating: "“quoted” — ", count: 10),
        String(repeating: "😀", count: 120),
    ])
    func codeIsAsWideAsItsWidestLine(widest: String) {
        let filler = (0..<1_200).map { "let v\($0) = \($0)" }.joined(separator: "\n")
        let code = widest + "\n" + filler
        let block = CodeLayout.make(code: code, language: nil, colors: nil, width: 600, style: style)
        let exact = exactBodyWidth(code)
        #expect(
            abs(block.bodySize.width - exact) <= 1,
            "code width \(block.bodySize.width) pt, Core Text \(exact) pt")
        let exactIsWider = ceil(exact + 2 * style.codeHorizontalInset) > block.size.width + 0.5
        #expect(block.isWiderThanBlock == exactIsWider, "scrollbar shown: \(block.isWiderThanBlock), needed: \(exactIsWider)")
    }

    @Test func diffingAStreamedCodeBlockIsNotProportionalToItsBytes() {
        let lines = (0..<25_000).map { "let value\($0) = compute(\($0)) // ok" }
        let before = CodeLayout.make(
            code: lines[..<24_950].joined(separator: "\n"), language: "swift", colors: nil, width: 728, style: style)
        let after = CodeLayout.make(
            code: lines.joined(separator: "\n"), language: "swift", colors: nil, width: 728, style: style,
            previous: before)
        let old = RowContentLayout.code(before, frame: CGRect(origin: .zero, size: before.size))
        let new = RowContentLayout.code(after, frame: CGRect(origin: .zero, size: after.size))
        var times: [Double] = []
        var unchanged: CGFloat = 0
        for _ in 0..<5 {
            let start = ContinuousClock.now
            unchanged = RowContentDiff.unchangedHeight(old, new)
            times.append(Self.milliseconds(start.duration(to: .now)))
        }
        let median = times.sorted()[2]
        #expect(unchanged > 0)
        #expect(median < 2, "diffing two streamed 25,000-line code layouts took \(median) ms on the main thread")
    }

    @Test func hitTestingALongNonASCIILineDoesNotLayItOutAgain() {
        let line = String(repeating: #"{"k":"valué","n":12345},"#, count: 40_000)
        let block = CodeLayout.make(code: line, language: "json", colors: nil, width: 600, style: style)
        _ = block.offset(closestTo: CGPoint(x: 50_000, y: 5))
        var times: [Double] = []
        for step in 0..<3 {
            let start = ContinuousClock.now
            _ = block.offset(closestTo: CGPoint(x: 50_000 + CGFloat(step) * 8, y: 5))
            _ = block.selectionRects(for: 6_000..<(6_400 + step))
            times.append(Self.milliseconds(start.duration(to: .now)))
        }
        let median = times.sorted()[1]
        #expect(median < 2, "one drag step (hit test + selection rects) took \(median) ms on a 1 MB line")
    }

    /// With `FontWidthTable`, every line's width is measured exactly with no
    /// 128 KB budget: a CJK line after 1,000 box-drawing lines never clips.
    @Test func aBlockWithManyNonASCIILinesMeasuresExactWidth() {
        let box = String(repeating: "─", count: 100)
        let cjk = String(repeating: "漢", count: 70)
        let code = (Array(repeating: box, count: 1_000) + [cjk]).joined(separator: "\n")
        let block = CodeLayout.make(code: code, language: nil, colors: nil, width: 600, style: style)
        let widest = max(exactBodyWidth(box), exactBodyWidth(cjk))
        #expect(abs(block.bodySize.width - widest) <= 1, "body \(block.bodySize.width) pt, widest line \(widest) pt")
    }

    @Test func unifiedCodeMeasuresExactNonASCIIWidthAndDiffsAccurately() {
        let boxLine = String(repeating: "─", count: 60)
        let boxCode = boxLine + "\n" + String(repeating: "a\n", count: 9_000)
        let boxBlock = CodeLayout.make(code: boxCode, language: nil, colors: nil, width: 600, style: style)
        #expect(abs(boxBlock.bodySize.width - exactBodyWidth(boxLine)) <= 1)

        let emojiLine = String(repeating: "🚀", count: 120)
        let emojiCode = emojiLine + "\n" + String(repeating: "a\n", count: 9_000)
        let emojiBlock = CodeLayout.make(code: emojiCode, language: nil, colors: nil, width: 600, style: style)
        #expect(abs(emojiBlock.bodySize.width - exactBodyWidth(emojiLine)) <= 1)

        let baseLines = (0..<1_000).map { "line_\($0) = value" }.joined(separator: "\n")
        let appended = baseLines + "\nline_1000 = value"
        let blockA = CodeLayout.make(code: baseLines, language: nil, colors: nil, width: 600, style: style)
        let blockB = CodeLayout.make(code: appended, language: nil, colors: nil, width: 600, style: style)
        #expect(blockA.unchangedBodyHeight(comparedTo: blockA) == .infinity)
        #expect(blockA.unchangedBodyHeight(comparedTo: blockB) == CGFloat(999) * style.codeLineHeight)

        let edited = baseLines.replacing("line_500 = value", with: "line_500 = CHANGED")
        let blockC = CodeLayout.make(code: edited, language: nil, colors: nil, width: 600, style: style)
        #expect(blockA.unchangedBodyHeight(comparedTo: blockC) == CGFloat(500) * style.codeLineHeight)
    }
}
