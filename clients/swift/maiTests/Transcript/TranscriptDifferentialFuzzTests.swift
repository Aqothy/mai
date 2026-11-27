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
            let maxStep =
                if document.utf8.count < 2_000 {
                    rng.pick([3, 16, 40])
                } else {
                    max(16, document.utf8.count / rng.int(in: 8..<20))
                }
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
            let oldBounds = before.paintedBounds(drawsWideBody: drawsWideBody, rowWidth: width.0, rowHeight: height.0)
            let newBounds = after.paintedBounds(drawsWideBody: drawsWideBody, rowWidth: width.1, rowHeight: height.1)
            let oldFrames = Set(RowLayer.bandFrames(in: oldBounds).map { "\($0)" })
            // A stale band sits immediately above where the change starts.
            let kept = RowLayer.bandFrames(in: newBounds)
                .filter { $0.maxY <= unchanged && oldFrames.contains("\($0)") }
            guard let maxY = kept.map(\.maxY).max() else { return }
            for frame in kept where frame.maxY == maxY {
                let keptPixels = TranscriptFuzz.pixels(before, rect: frame, drawsWideBody: drawsWideBody, palette: palette)
                let fresh = TranscriptFuzz.pixels(after, rect: frame, drawsWideBody: drawsWideBody, palette: palette)
                let matches = keptPixels == fresh
                #expect(matches, "\(context): kept band \(frame) is stale (unchanged \(unchanged))")
            }
        }
        let oldWide = old.content.wideBody
        let newWide = new.content.wideBody
        // A row switching between drawing its body and handing it to a
        // scroller redraws every band (`RowLayer.show`'s `sameRow`).
        if (oldWide == nil) == (newWide == nil) {
            check(
                old.content, new.content,
                height: (old.height, new.height),
                width: (old.key.width, new.key.width), drawsWideBody: newWide == nil)
        }
        if let oldWide, let newWide {
            check(
                oldWide.content, newWide.content, height: (oldWide.frame.height, newWide.frame.height),
                width: (oldWide.contentWidth, newWide.contentWidth), drawsWideBody: true)
        }
    }

    /// `PreparedText` breaks, measures, and carets realistic multi-script,
    /// multi-style text identically to Core Text (`CTTypesetterSuggestLineBreak`
    /// + drawn `CTLine`), and `resized(toWidth:)` equals a fresh layout from
    /// scratch (`REDESIGN.md §7 R1–R2`).
    @Test(arguments: 0..<2)
    func preparedTextMatchesCoreTextExactly(seed: Int) async {
        let style = await TextStyle.current()
        var rng = FuzzRNG(seed: Self.slidingWindowSeed &+ UInt64(seed))
        for iteration in 0..<(4 * TranscriptFuzz.scale) {
            let testCase = realisticCase(&rng, style: style)
            checkPreparedMatchesCoreText(testCase, style: style, context: "seed \(seed) iteration \(iteration)")
        }
    }

    /// Kitchen-sink adversarial and Unicode edge characters (C0/C1 controls,
    /// lone CR, BiDi isolates/overrides, noncharacters, PUA, tag emoji,
    /// Mongolian, Tibetan, Indic/SEA conjuncts, tabs, ZWSP/WJ/SHY): verifies
    /// contiguous coverage, cluster-aligned carets matching drawn `CTLine`,
    /// bounded widths, and bit-exact `resized(toWidth:)` equivalence.
    @Test(arguments: 0..<2)
    func preparedTextAndResizeHoldForEveryKindOfCharacter(seed: Int) async {
        let style = await TextStyle.current()
        var rng = FuzzRNG(seed: Self.slidingWindowSeed &+ 0x100 &+ UInt64(seed))
        let tokens = TranscriptFuzz.adversarialTokens + TranscriptFuzz.unicodeEdgeTokens
        for iteration in 0..<(4 * TranscriptFuzz.scale) {
            let testCase = slidingWindowCase(&rng, style: style, tokens: tokens)
            checkAdversarialInvariants(testCase, style: style, context: "seed \(seed) iteration \(iteration)")
        }
    }

    @Test(arguments: zip([2, 3], [260, 247]))
    func preparedTextRegressions(seed: Int, iteration: Int) async {
        let style = await TextStyle.current()
        var rng = FuzzRNG(seed: Self.slidingWindowSeed &+ UInt64(seed))
        for _ in 0..<iteration { _ = slidingWindowCase(&rng, style: style) }
        checkAdversarialInvariants(
            slidingWindowCase(&rng, style: style), style: style, context: "seed \(seed) iteration \(iteration)")
    }

    private static let slidingWindowSeed: UInt64 = 0x51_1D00

    private static let realisticTokens: [String] = [
        "word", "transcript", "performance", "a", "the", " ", "  ", ".", ",", ";", ":", "()", "[]", "{}", "\"quoted\"",
        "-", "—", "café", "naïve", "résumé", "漢字", "日本語", "かな", "。", "한글", "Привет", "Ελληνικά",
        "👍", "👍🏼", "👩🏽‍💻", "👩‍👩‍👧‍👦", "🏴‍☠️", "✌️", "مرحبا", "بالعالم", "שלום", "ไทย", "अपार्टमेंट",
        "https://example.com/a/very/long/path?query=value", "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
        "1,234.56", "$100", "fi", "ffl", "AVATAR", "Toyota",
    ]

    private func realisticCase(_ rng: inout FuzzRNG, style: TextStyle) -> (text: StyledText, width: CGFloat) {
        var text = TranscriptFuzz.adversarialText(
            &rng, utf16Length: rng.int(in: 2_000..<6_000), newlines: rng.chance(40), tokens: Self.realisticTokens)
        while text.utf16.count > 8_000 { text.removeLast() }
        var inlines: [MarkdownInline] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            let take = min(rest.count, rng.int(in: 40..<400))
            let piece = rest.prefix(take)
            rest = rest.dropFirst(take)
            let inlineStyle: MarkdownInline.Style = rng.pick([[], [], [], .strong, .emphasis, .code])
            inlines.append(MarkdownInline(text: String(piece), style: inlineStyle))
        }
        let width = CGFloat(rng.pick([120, 237, 333, 600, 728]))
        return (AttributedTextBuilder.build([.paragraph(inlines)], style: style), width)
    }

    /// Random text past 4 KB in styled runs (fonts change inside lines, as in
    /// real replies), and a width.
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

    private func checkPreparedMatchesCoreText(
        _ testCase: (text: StyledText, width: CGFloat), style: TextStyle, context: String
    ) {
        let options = TextLayoutEngine.Options(lineSpacing: style.lineSpacing, quoteBarWidth: style.quoteBarWidth)
        let layout = TextLayoutEngine.layout(testCase.text, width: testCase.width, options: options)
        let diff =
            Self.differenceFromOneTypesetter(layout, testCase.text, width: testCase.width, lineSpacing: style.lineSpacing)
            ?? TranscriptFuzz.caretInsideCluster(layout)
        #expect(diff == nil, "\(context) width \(testCase.width): \(diff ?? "")")
        let altWidth: CGFloat = testCase.width > 300 ? 220 : 540
        let resized = layout.resized(toWidth: altWidth)
        let fresh = TextLayoutEngine.layout(testCase.text, width: altWidth, options: options)
        let resizeDiff = TranscriptFuzz.difference(resized, fresh)
        #expect(resizeDiff == nil, "\(context) resize \(testCase.width) -> \(altWidth): \(resizeDiff ?? "")")
    }

    private func checkAdversarialInvariants(
        _ testCase: (text: StyledText, width: CGFloat), style: TextStyle, context: String
    ) {
        let options = TextLayoutEngine.Options(lineSpacing: style.lineSpacing, quoteBarWidth: style.quoteBarWidth)
        let layout = TextLayoutEngine.layout(testCase.text, width: testCase.width, options: options)
        let total = testCase.text.length
        #expect(!layout.lines.isEmpty, "\(context): empty lines")
        #expect(layout.lines.first?.range.lowerBound == 0, "\(context): first line start")
        #expect(layout.lines.last?.range.upperBound == total, "\(context): last line end")
        for i in 1..<layout.lines.count {
            #expect(layout.lines[i - 1].range.upperBound == layout.lines[i].range.lowerBound, "\(context): gap at line \(i)")
            #expect(layout.lines[i].top >= layout.lines[i - 1].bottom, "\(context): overlap at line \(i)")
        }
        let clusterDiff = TranscriptFuzz.caretInsideCluster(layout)
        #expect(clusterDiff == nil, "\(context): \(clusterDiff ?? "")")
        let altWidth: CGFloat = testCase.width > 300 ? 180 : 500
        let resized = layout.resized(toWidth: altWidth)
        let fresh = TextLayoutEngine.layout(testCase.text, width: altWidth, options: options)
        let resizeDiff = TranscriptFuzz.difference(resized, fresh)
        #expect(resizeDiff == nil, "\(context) resize \(testCase.width) -> \(altWidth): \(resizeDiff ?? "")")
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
            let tailStart = after.lines.count - alone.lines.count
            for (index, expected) in alone.lines.enumerated() {
                let expectedCarets = alone.caretOffsets(forLineAt: index)
                for (context, layout, actualIdx) in [
                    ("before", before, index), ("after", after, tailStart + index),
                ] {
                    let actual = layout.lines[actualIdx]
                    let offset = actual.range.lowerBound - expected.range.lowerBound
                    let actualCarets = layout.caretOffsets(forLineAt: actualIdx)
                    let same =
                        actual.range.count == expected.range.count
                        && abs(actual.width - expected.width) < 0.5
                        && actualCarets.count == expectedCarets.count
                        && zip(actualCarets, expectedCarets).allSatisfy { abs($0 - $1) < 0.5 }
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

    /// Verifies that `PreparedText` breaks lines like `CTTypesetterSuggestLineBreak`
    /// and that every line's fitted width, height, and on-demand carets match
    /// the standalone `CTLine` that `TextRenderer` draws on screen.
    static func differenceFromOneTypesetter(
        _ layout: TextLayout, _ styled: StyledText, width: CGFloat, lineSpacing: CGFloat
    ) -> String? {
        let ns = styled.text as NSString
        let attributed = StyledText.attributedSlice(of: ns, range: 0..<ns.length, runs: styled.runs)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var start = 0
        var index = 0
        while start < ns.length {
            let indent = start == 0 ? styled.paragraphs.first?.firstLineIndent ?? 0 : styled.paragraphs.first?.headIndent ?? 0
            let count = max(1, min(CTTypesetterSuggestLineBreak(typesetter, start, Double(max(1, width - indent))), ns.length - start))
            guard index < layout.lines.count else { return "missing line \(index)" }
            let line = layout.lines[index]
            guard line.range == start..<(start + count) else { return "line \(index) range \(line.range) vs \(start..<(start + count))" }
            let tsLine = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            var tsAscent: CGFloat = 0
            var tsDescent: CGFloat = 0
            var tsLeading: CGFloat = 0
            let tsWidth = max(
                0,
                CGFloat(CTLineGetTypographicBounds(tsLine, &tsAscent, &tsDescent, &tsLeading))
                    - CGFloat(CTLineGetTrailingWhitespaceWidth(tsLine)))
            let tsHeight = ceil(tsAscent + tsDescent + tsLeading)
            let baseDir: CTWritingDirection? =
                if layout.prepared.paragraphs.indices.contains(line.paragraphIndex),
                    layout.prepared.paragraphs[line.paragraphIndex].hasBiDiUnits
                {
                    line.bidiIsRTL ? .rightToLeft : .leftToRight
                } else {
                    nil
                }
            let lineAttr = StyledText.attributedSlice(
                of: ns, range: line.range, runs: styled.runs, baseWritingDirection: baseDir)
            let ctLine = CTLineCreateWithAttributedString(lineAttr)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let lineWidth = max(0, CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)) - CGFloat(CTLineGetTrailingWhitespaceWidth(ctLine)))
            let expectedHeight = ceil(ascent + descent + leading)
            guard abs(line.width - lineWidth) < 1.5 || abs(line.width - tsWidth) < 1.5 else {
                return "line \(index) width \(line.width) vs \(lineWidth) (ts \(tsWidth))"
            }
            // On iOS, `CTLineGetTypographicBounds` can synthesize non-additive
            // extra line height when `.AppleColorEmojiUI` shares a line with a
            // non-UI fallback font (e.g. `CourierNewPSMT`), even though every
            // individual `CTRun` on the line has smaller typographic bounds.
            var runAscent: CGFloat = 0
            var runDescent: CGFloat = 0
            var runLeading: CGFloat = 0
            for run in (CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? []) {
                var ra: CGFloat = 0
                var rd: CGFloat = 0
                var rl: CGFloat = 0
                _ = CTRunGetTypographicBounds(run, CFRange(), &ra, &rd, &rl)
                runAscent = max(runAscent, ra)
                runDescent = max(runDescent, rd)
                runLeading = max(runLeading, rl)
            }
            let runHeight = ceil(runAscent + runDescent + runLeading)
            guard
                abs(line.height - expectedHeight) <= 0.5 || abs(line.height - tsHeight) <= 0.5
                    || (runHeight > 0 && abs(line.height - runHeight) <= 0.5)
            else {
                return "line \(index) height \(line.height) vs \(expectedHeight) (ts \(tsHeight), runs \(runHeight))"
            }
            let isRTL = TextLayoutEngine.paragraphIsRTL(ns, startingAt: styled.paragraphs.first?.start ?? 0)
            let lineX = TextLayoutEngine.lineOriginX(indent: indent, lineWidth: line.width, availableWidth: width, isRTL: isRTL)
            let lineNS = lineAttr.string as NSString
            let carets = TextLayoutEngine.caretOffsets(of: ctLine, range: 0..<line.range.count, string: lineNS, indent: lineX, width: line.width)
            let actualCarets = layout.caretOffsets(forLineAt: index)
            guard actualCarets.count == carets.count,
                zip(actualCarets, carets).allSatisfy({ abs($0 - $1) < 1.5 })
            else {
                let at = carets.indices.first { abs(actualCarets[$0] - carets[$0]) >= 1.5 } ?? 0
                let units = (max(0, start + at - 3)..<min(ns.length, start + at + 3)).map { String(ns.character(at: $0), radix: 16) }
                return "line \(index) \(line.range) caret \(at): \(actualCarets[at]) vs \(carets[at]) near \(units)"
            }
            start += count
            index += 1
        }
        return index == layout.lines.count ? nil : "extra lines"
    }
}
