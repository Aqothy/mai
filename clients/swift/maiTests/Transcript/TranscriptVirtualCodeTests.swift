import CoreGraphics
import Foundation
import Testing

@testable import mai

/// `VirtualCodeBody`, the body of every code block over 16 KB or with a line
/// over 4 KB: exact widths, and main-thread queries that stay cheap.
@MainActor
struct TranscriptVirtualCodeTests {
    private let style = TextStyle.current()

    private func exactBody(_ code: String) -> TextLayout {
        TextLayoutEngine.layout(
            CodeLayout.buildStyledCode(code, colors: nil, style: style), width: .greatestFiniteMagnitude,
            options: .init(lineSpacing: 0, wraps: false, fixedLineHeight: style.codeLineHeight))
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    /// The block's width is its widest line's, laid out: it sets the
    /// horizontal scroll extent and the painted bands. Box drawing, arrows,
    /// quotes and dashes are 1 column in SF Mono and emoji over 2, so a width
    /// estimated from UTF-8 lengths shows a scrollbar a block doesn't need or
    /// cuts a line off.
    @Test(arguments: [
        String(repeating: "─", count: 60),
        String(repeating: "→ ", count: 40),
        String(repeating: "“quoted” — ", count: 10),
        String(repeating: "😀", count: 120),
    ])
    func virtualizedCodeIsAsWideAsItsWidestLine(widest: String) {
        let filler = (0..<1_200).map { "let v\($0) = \($0)" }.joined(separator: "\n")
        let code = widest + "\n" + filler
        let block = CodeLayout.make(code: code, language: nil, colors: nil, width: 600, style: style)
        #expect(block.materializedBody == nil, "expected the virtualized body (\(code.utf8.count) bytes)")
        let exact = exactBody(code).size.width
        #expect(
            abs(block.bodySize.width - exact) <= 1,
            "virtualized width \(block.bodySize.width) pt, laid out \(exact) pt")
        let exactIsWider = ceil(exact + 2 * style.codeHorizontalInset) > block.size.width + 0.5
        #expect(block.isWiderThanBlock == exactIsWider, "scrollbar shown: \(block.isWiderThanBlock), needed: \(exactIsWider)")
    }

    /// `RowLayer.show` diffs every streamed frame on the main thread; for a
    /// virtualized body that is `VirtualCodeBody.unchangedHeight`, which must
    /// not walk every byte (`stream-25k-line-row-show-main`, Profile: 0.02 ms;
    /// a per-line byte walk took 3.4 ms).
    @Test func diffingAStreamedVirtualizedCodeBlockIsNotProportionalToItsBytes() {
        let lines = (0..<25_000).map { "let value\($0) = compute(\($0)) // ok" }
        let before = CodeLayout.make(
            code: lines[..<24_950].joined(separator: "\n"), language: "swift", colors: nil, width: 728, style: style)
        let after = CodeLayout.make(
            code: lines.joined(separator: "\n"), language: "swift", colors: nil, width: 728, style: style,
            previous: before)
        #expect(before.materializedBody == nil && after.materializedBody == nil)
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

    /// A long non-ASCII line is laid out with Core Text once and kept, so a
    /// drag's hit tests and selection rects on the main thread don't lay the
    /// whole line out again (~20 ms per megabyte, Profile).
    @Test func hitTestingALongNonASCIILineDoesNotLayItOutAgain() {
        let line = String(repeating: #"{"k":"valué","n":12345},"#, count: 40_000)
        let block = CodeLayout.make(code: line, language: "json", colors: nil, width: 600, style: style)
        #expect(block.materializedBody == nil)
        #expect(block.hasLargeNonASCIILine)
        // Warm-up: a cache filled on first use would pass the rest.
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

    /// Past the 128 KB measuring budget the block counts the next line's
    /// upper bound (one column per UTF-8 byte), never less than a line it
    /// skipped: a CJK line narrower in bytes but wider on screen than 1,000
    /// box-drawing lines still fits.
    @Test func aBlockPastItsMeasuringBudgetNeverClipsAWiderLine() {
        let box = String(repeating: "─", count: 100)
        let cjk = String(repeating: "漢", count: 70)
        let code = (Array(repeating: box, count: 1_000) + [cjk]).joined(separator: "\n")
        let block = CodeLayout.make(code: code, language: nil, colors: nil, width: 600, style: style)
        #expect(block.materializedBody == nil)
        let widest = max(exactBody(box).size.width, exactBody(cjk).size.width)
        #expect(block.bodySize.width + 1 >= widest, "body \(block.bodySize.width) pt, widest line \(widest) pt")
    }

    @Test func virtualizedCodeMeasuresExactNonASCIIWidthAndCachesHitTests() {
        let ascii = MonospaceASCIIMetrics.metrics(for: style.font(.code))
        let lineOpts = TextLayoutEngine.Options(lineSpacing: 0, wraps: false, fixedLineHeight: style.codeLineHeight)

        let boxLine = String(repeating: "─", count: 60)
        let boxCode = boxLine + "\n" + String(repeating: "a\n", count: 9_000)
        let boxVirtual = VirtualCodeBody(code: boxCode, style: style, colors: nil, ascii: ascii)
        let boxCT = TextLayoutEngine.layout(
            CodeLayout.buildStyledCode(boxLine, colors: nil, style: style),
            width: .greatestFiniteMagnitude, options: lineOpts)
        #expect(abs(boxVirtual.size.width - ceil(boxCT.size.width)) <= 1)

        let emojiLine = String(repeating: "🚀", count: 120)
        let emojiCode = emojiLine + "\n" + String(repeating: "a\n", count: 9_000)
        let emojiVirtual = VirtualCodeBody(code: emojiCode, style: style, colors: nil, ascii: ascii)
        let emojiCT = TextLayoutEngine.layout(
            CodeLayout.buildStyledCode(emojiLine, colors: nil, style: style),
            width: .greatestFiniteMagnitude, options: lineOpts)
        #expect(abs(emojiVirtual.size.width - ceil(emojiCT.size.width)) <= 1)

        // Streaming unchangedHeight via memcmp must agree on tail appends and mid-file edits.
        let baseLines = (0..<1_000).map { "line_\($0) = value" }.joined(separator: "\n")
        let appended = baseLines + "\nline_1000 = value"
        let bodyA = VirtualCodeBody(code: baseLines, style: style, colors: nil, ascii: ascii)
        let bodyB = VirtualCodeBody(code: appended, style: style, colors: nil, ascii: ascii)
        #expect(bodyA.unchangedHeight(comparedTo: bodyA) == .infinity)
        #expect(bodyA.unchangedHeight(comparedTo: bodyB) == CGFloat(999) * style.codeLineHeight)

        let edited = baseLines.replacing("line_500 = value", with: "line_500 = CHANGED")
        let bodyC = VirtualCodeBody(code: edited, style: style, colors: nil, ascii: ascii)
        #expect(bodyA.unchangedHeight(comparedTo: bodyC) == CGFloat(500) * style.codeLineHeight)
    }
}
