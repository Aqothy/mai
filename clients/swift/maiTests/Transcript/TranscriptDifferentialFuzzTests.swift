import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import mai

/// Differential fuzzers: every shortcut the engine takes must be
/// indistinguishable from doing the work from scratch. Incremental streaming
/// layout against a one-shot layout of the same block, the sliding
/// typesetter window against one Core Text typesetter, and the bands a row
/// keeps across a streamed update against a fresh raster (Blink's paint
/// under-invalidation checking).
nonisolated struct TranscriptDifferentialFuzzTests {
    /// Streams random replies in random cuts; every block the worker lays
    /// out incrementally equals its layout from nothing, and every band a
    /// mounted row keeps (`RowContentDiff`) draws what a fresh band would.
    @Test(arguments: 0..<3)
    func streamedLayoutsEqualOneShotLayoutsAndKeptBandsStayCurrent(seed: Int) async {
        await checkStreamedLayouts(
            seed: 0x5EED_0000 &+ UInt64(seed), iterations: 2, vocabulary: TranscriptFuzz.words,
            fenceTokens: TranscriptFuzz.adversarialTokens)
    }

    /// The same with every kind of character a model can emit in the prose
    /// and code fences (`unicodeEdgeTokens`).
    @Test(arguments: 0..<2)
    func streamedLayoutsHoldForEveryKindOfCharacter(seed: Int) async {
        await checkStreamedLayouts(
            seed: 0x5EED_1000 &+ UInt64(seed), iterations: 1,
            vocabulary: TranscriptFuzz.words + TranscriptFuzz.unicodeEdgeTokens,
            fenceTokens: TranscriptFuzz.adversarialTokens + TranscriptFuzz.unicodeEdgeTokens)
    }

    private func checkStreamedLayouts(
        seed: UInt64, iterations: Int, vocabulary: [String], fenceTokens: [String]
    ) async {
        let style = await TextStyle.current()
        var rng = FuzzRNG(seed: seed)
        let palette = await TextPalette.resolveForTests
        for _ in 0..<(iterations * TranscriptFuzz.scale) {
            let document = TranscriptFuzz.markdownDocument(
                &rng, blocks: rng.int(in: 1..<8), vocabulary: vocabulary, fenceTokens: fenceTokens)
            let width = CGFloat(rng.int(in: 180..<760))
            let worker = TranscriptStreamWorker()
            var shown: [Int: RowLayout] = [:]
            let maxStep = max(16, document.utf8.count / rng.int(in: 8..<20))
            let cuts = TranscriptFuzz.prefixes(of: document, &rng, maxStep: maxStep)
            for (step, text) in cuts.enumerated() {
                let isFinished = step == cuts.count - 1
                let result = await worker.run(
                    TranscriptStreamWorker.Update(
                        messageID: "m", text: text, isFinished: isFinished, width: width, style: style,
                        codeColors: [:], isDark: true, drawing: nil))
                for row in result.rows {
                    let fresh = RowLayoutBuilder.layout(
                        RowLayoutRequest(rowID: row.layout.rowID, kind: row.kind, key: row.layout.key, style: style))
                    #expect(row.layout.height == fresh.height, "seed \(seed) step \(step) row \(row.index) height")
                    if let diff = TranscriptFuzz.difference(row.layout.content, fresh.content) {
                        Issue.record("seed \(seed) step \(step) row \(row.index) width \(width): \(diff)")
                        return
                    }
                    if let old = shown[row.index] {
                        checkKeptBands(old: old, new: row.layout, palette: palette, context: "seed \(seed) step \(step)")
                    }
                    shown[row.index] = row.layout
                }
            }
        }
    }

    /// Bands a row keeps across `old` -> `new` (as `RowLayer.show` decides)
    /// must draw the same pixels as the new layout.
    private func checkKeptBands(old: RowLayout, new: RowLayout, palette: TextPalette, context: String) {
        func check(
            _ before: RowContentLayout, _ after: RowContentLayout, height: (CGFloat, CGFloat),
            width: (CGFloat, CGFloat), drawsWideBody: Bool
        ) {
            let unchanged = RowContentDiff.unchangedHeight(before, after)
            guard unchanged > 0 else { return }
            let oldFrames = Set(RowLayer.bandFrames(height: height.0, width: width.0).map { "\($0)" })
            // A stale band sits immediately above where the change starts.
            let kept = RowLayer.bandFrames(height: height.1, width: width.1)
                .filter { $0.maxY <= unchanged && oldFrames.contains("\($0)") }
            guard let maxY = kept.map(\.maxY).max() else { return }
            for frame in kept where frame.maxY == maxY {
                let keptPixels = TranscriptFuzz.pixels(before, rect: frame, drawsWideBody: drawsWideBody, palette: palette)
                let fresh = TranscriptFuzz.pixels(after, rect: frame, drawsWideBody: drawsWideBody, palette: palette)
                #expect(keptPixels == fresh, "\(context): kept band \(frame) is stale (unchanged \(unchanged))")
            }
        }
        let oldWide = old.content.wideBody
        let newWide = new.content.wideBody
        // A row switching between drawing its body and handing it to a
        // scroller redraws every band (`RowLayer.show`'s `sameRow`).
        if (oldWide == nil) == (newWide == nil) {
            check(
                old.content, new.content,
                height: (
                    old.content.paintedHeight(drawsWideBody: oldWide == nil, rowHeight: old.height),
                    new.content.paintedHeight(drawsWideBody: newWide == nil, rowHeight: new.height)
                ),
                width: (old.key.width, new.key.width), drawsWideBody: newWide == nil)
        }
        if let oldWide, let newWide {
            check(
                oldWide.content, newWide.content, height: (oldWide.frame.height, newWide.frame.height),
                width: (oldWide.contentWidth, newWide.contentWidth), drawsWideBody: true)
        }
    }

    /// The sliding typesetter window breaks, measures and carets every line
    /// exactly as one typesetter over the whole text does, for random text
    /// whose window boundaries land inside every kind of cluster. Only up to
    /// 10,240 UTF-16 units: past that one typesetter breaks lines by another
    /// algorithm (measured: the same first line breaks at 30 units in every
    /// prefix up to 10,240 and at 8 beyond), which windows never reach.
    ///
    /// Accepted difference (scale 50, seed 1, iteration 282): Core Text
    /// shapes a Bengali run in a fallback font about 3% wider or narrower
    /// depending on the text up to 500 units before it and on the text after
    /// it. A window starts at its cut (one line back beside Thai, Lao,
    /// Khmer or Myanmar letters) and ends 64 units on, so a line holding
    /// such a run can measure and break differently. Neither is wrong: a
    /// browser shapes each run on its own.
    @Test(arguments: 0..<2)
    func slidingWindowMatchesOneTypesetterExactly(seed: Int) async {
        let style = await TextStyle.current()
        var rng = FuzzRNG(seed: Self.slidingWindowSeed &+ UInt64(seed))
        for iteration in 0..<(4 * TranscriptFuzz.scale) {
            checkSlidingWindow(slidingWindowCase(&rng, style: style), style: style, context: "seed \(seed) iteration \(iteration)")
        }
    }

    /// Cases the scale-50 run found: Lao words broken at a window's start,
    /// where a window without the line before it as context began inside a
    /// word (`slide` in `TextLayoutEngine.layoutWindows`).
    /// The same with every kind of character a model can emit mixed in:
    /// mandatory breaks inside hard lines, controls, BiDi controls and
    /// right-to-left runs (whole-line typesetters), and scripts Core Text
    /// shapes by syllable.
    @Test(arguments: 0..<2)
    func slidingWindowMatchesOneTypesetterForEveryKindOfCharacter(seed: Int) async {
        let style = await TextStyle.current()
        var rng = FuzzRNG(seed: Self.slidingWindowSeed &+ 0x100 &+ UInt64(seed))
        let tokens = TranscriptFuzz.adversarialTokens + TranscriptFuzz.unicodeEdgeTokens
        for iteration in 0..<(4 * TranscriptFuzz.scale) {
            checkSlidingWindow(
                slidingWindowCase(&rng, style: style, tokens: tokens), style: style,
                context: "seed \(seed) iteration \(iteration)")
        }
    }

    @Test(arguments: zip([2, 3], [260, 247]))
    func slidingWindowRegressions(seed: Int, iteration: Int) async {
        let style = await TextStyle.current()
        var rng = FuzzRNG(seed: Self.slidingWindowSeed &+ UInt64(seed))
        for _ in 0..<iteration { _ = slidingWindowCase(&rng, style: style) }
        checkSlidingWindow(slidingWindowCase(&rng, style: style), style: style, context: "seed \(seed) iteration \(iteration)")
    }

    private static let slidingWindowSeed: UInt64 = 0x51_1D00

    /// Random text past the sliding threshold in styled runs (fonts change
    /// inside lines, as in real replies), and a width.
    private func slidingWindowCase(
        _ rng: inout FuzzRNG, style: TextStyle, tokens: [String] = TranscriptFuzz.adversarialTokens
    ) -> (text: StyledText, width: CGFloat) {
        var text = TranscriptFuzz.adversarialText(
            &rng, utf16Length: rng.int(in: 4_200..<10_000), newlines: rng.chance(30), tokens: tokens)
        while text.utf16.count > 10_240 { text.removeLast() }
        var inlines: [MarkdownInline] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            let take = min(rest.count, rng.int(in: 1..<400))
            let piece = rest.prefix(take)
            rest = rest.dropFirst(take)
            let inlineStyle: MarkdownInline.Style = rng.pick([[], [], .strong, .emphasis, .code])
            inlines.append(MarkdownInline(text: String(piece), style: inlineStyle))
        }
        let width = CGFloat(rng.pick([60, 120, 333, 728]))
        return (AttributedTextBuilder.build([.paragraph(inlines)], style: style), width)
    }

    private func checkSlidingWindow(_ testCase: (text: StyledText, width: CGFloat), style: TextStyle, context: String) {
        let options = TextLayoutEngine.Options(lineSpacing: style.lineSpacing, quoteBarWidth: style.quoteBarWidth)
        let layout = TextLayoutEngine.layout(testCase.text, width: testCase.width, options: options)
        let diff =
            Self.differenceFromOneTypesetter(layout, testCase.text, width: testCase.width, lineSpacing: style.lineSpacing)
            ?? TranscriptFuzz.caretInsideCluster(layout)
        #expect(diff == nil, "\(context) width \(testCase.width): \(diff ?? "")")
    }

    /// A line lays out identically (breaks, glyphs, positions, carets)
    /// whether it is alone or has tens of kilobytes of text around it: Core
    /// Text drops kerning and ligatures in strings over 10,240 units, which
    /// windows never reach.
    @Test(arguments: [TextStyle.FontRole.body, .code])
    func linesLayOutTheSameHoweverMuchTextSurroundsThem(role: TextStyle.FontRole) async {
        let style = await TextStyle.current()
        var rng = FuzzRNG(seed: 0x5A3E)
        let options = TextLayoutEngine.Options(lineSpacing: 0, wraps: role == .body)
        let filler = String(repeating: "lorem ipsum dolor sit amet\n", count: 12_000 / 27)
        for iteration in 0..<(3 * TranscriptFuzz.scale) {
            // Ends in a newline wherever it sits, so its lines' ranges match.
            let line = "AVATAR Toyota WAVE office affluent Yesterday, VA. ✌️ café — “quotes” fi ffl ✌︎ "
                + TranscriptFuzz.adversarialText(&rng, utf16Length: rng.int(in: 10..<300)) + "\n"
            let alone = TextLayoutEngine.layout(
                AttributedTextBuilder.plain(line, role: role, color: .primary, style: style), width: 640, options: options)
            let before = TextLayoutEngine.layout(
                AttributedTextBuilder.plain(line + filler, role: role, color: .primary, style: style),
                width: 640, options: options)
            let after = TextLayoutEngine.layout(
                AttributedTextBuilder.plain(filler + line, role: role, color: .primary, style: style),
                width: 640, options: options)
            let tail = after.lines.suffix(alone.lines.count)
            for (index, expected) in alone.lines.enumerated() {
                for (context, layout, actual) in [
                    ("before", before, before.lines[index]), ("after", after, tail[tail.startIndex + index]),
                ] {
                    let offset = actual.range.lowerBound - expected.range.lowerBound
                    let same =
                        actual.range.count == expected.range.count && actual.width == expected.width
                        && actual.caretOffsets == expected.caretOffsets
                        && actual.runs.flatMap { layout.runs[$0].glyphs } == expected.runs.flatMap { alone.runs[$0].glyphs }
                        && actual.runs.flatMap { layout.runs[$0].positions.map(\.x) }
                            == expected.runs.flatMap { alone.runs[$0].positions.map(\.x) }
                    #expect(same, "iteration \(iteration) \(role) \(context): line \(index) (offset \(offset)) differs")
                }
            }
        }
    }

    /// No caret stops inside a grapheme cluster, even where Core Text gives a
    /// character inside one a glyph of its own: a VS16 after a fallback font
    /// drew its base (one code line past 10,240 units), Indic spacing marks,
    /// © and ® joined to an emoji by a ZWJ.
    @Test func caretsNeverLandInsideAGraphemeCluster() async {
        let style = await TextStyle.current()
        var rng = FuzzRNG(seed: 0xC1_5751)
        var texts = [
            "का कि की कु क्ष त्र श्र", "রাষ্ট্র্রে অপার্টমেন্ট", "✌︎ and ✌️, ❤︎ and ❤️, e\u{0301} n\u{0308}",
            "a👍\u{200D}©b 👍\u{200D}® ©",
        ]
        for _ in 0..<(2 * TranscriptFuzz.scale) {
            texts.append("✌︎ " + TranscriptFuzz.adversarialText(&rng, utf16Length: 11_000) + " ✌️ ✌︎ ❤️")
        }
        for _ in 0..<(2 * TranscriptFuzz.scale) {
            texts.append(
                TranscriptFuzz.adversarialText(
                    &rng, utf16Length: 11_000, newlines: true,
                    tokens: TranscriptFuzz.adversarialTokens + TranscriptFuzz.unicodeEdgeTokens))
        }
        for (index, text) in texts.enumerated() {
            for role in [TextStyle.FontRole.body, .code] {
                let layout = TextLayoutEngine.layout(
                    AttributedTextBuilder.plain(text, role: role, color: .primary, style: style), width: 500,
                    options: .init(lineSpacing: 0, wraps: role == .body))
                let inside = TranscriptFuzz.caretInsideCluster(layout)
                #expect(inside == nil, "text \(index) \(role): \(inside ?? "")")
            }
        }
    }

    /// Lines from a single typesetter over the whole string, compared with
    /// `layout`'s ranges, widths, carets and glyphs.
    static func differenceFromOneTypesetter(
        _ layout: TextLayout, _ styled: StyledText, width: CGFloat, lineSpacing: CGFloat
    ) -> String? {
        let ns = styled.string.string as NSString
        let typesetter = CTTypesetterCreateWithAttributedString(styled.string)
        var start = 0
        var index = 0
        while start < ns.length {
            let indent = start == 0 ? styled.paragraphs.first?.firstLineIndent ?? 0 : styled.paragraphs.first?.headIndent ?? 0
            let count = max(1, min(CTTypesetterSuggestLineBreak(typesetter, start, Double(max(1, width - indent))), ns.length - start))
            guard index < layout.lines.count else { return "missing line \(index)" }
            let line = layout.lines[index]
            guard line.range == start..<(start + count) else { return "line \(index) range \(line.range) vs \(start..<(start + count))" }
            let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            let lineWidth = max(0, CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(ctLine)))
            guard line.width == lineWidth else { return "line \(index) width \(line.width) vs \(lineWidth)" }
            let carets = TextLayoutEngine.caretOffsets(of: ctLine, range: line.range, string: ns, indent: indent, width: lineWidth)
            guard line.caretOffsets == carets else {
                let at = carets.indices.first { line.caretOffsets[$0] != carets[$0] } ?? 0
                let units = (max(0, start + at - 3)..<min(ns.length, start + at + 3)).map { String(ns.character(at: $0), radix: 16) }
                return "line \(index) \(line.range) caret \(at): \(line.caretOffsets[at]) vs \(carets[at]) near \(units)"
            }
            var glyphs: [CGGlyph] = []
            var xs: [CGFloat] = []
            for run in CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? [] {
                let n = CTRunGetGlyphCount(run)
                var g = [CGGlyph](repeating: 0, count: n)
                var p = [CGPoint](repeating: .zero, count: n)
                CTRunGetGlyphs(run, CFRange(), &g)
                CTRunGetPositions(run, CFRange(), &p)
                glyphs += g
                xs += p.map { indent + $0.x }
            }
            let laid = line.runs.flatMap { layout.runs[$0].glyphs }
            let laidX = line.runs.flatMap { layout.runs[$0].positions.map(\.x) }
            guard laid == glyphs, laidX == xs else { return "line \(index) glyphs" }
            start += count
            index += 1
        }
        return index == layout.lines.count ? nil : "extra lines"
    }
}
