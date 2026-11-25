import CoreGraphics
import CoreText
import Foundation
import IOSurface
import QuartzCore
import Testing

@testable import mai

/// Deterministic extreme-input stress tests and fuzzers for the native
/// transcript engine, covering large/pathological inputs, CoreText /
/// Unicode / grapheme / BiDi / Zalgo edge cases, and layout / geometry
/// invariants.
@MainActor
struct TranscriptExtremeAndFuzzTests {
    private let style = TextStyle.current()

    /// Reference single-typesetter layout (no sliding window) for differential
    /// verification on medium strings above `slidingWindowThreshold`.
    private func unslicedReferenceLayout(_ styled: StyledText, width: CGFloat) -> (
        lineRanges: [Range<Int>], lineWidths: [CGFloat], totalHeight: CGFloat
    ) {
        let length = styled.length
        let typesetter = CTTypesetterCreateWithAttributedString(styled.string)
        var start = 0
        var ranges: [Range<Int>] = []
        var widths: [CGFloat] = []
        var y: CGFloat = 0
        while start < length {
            let count = max(
                1, min(CTTypesetterSuggestLineBreak(typesetter, start, Double(max(1, width))), length - start))
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let typographic = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let lineWidth = max(0, typographic - CGFloat(CTLineGetTrailingWhitespaceWidth(line)))
            if !ranges.isEmpty { y += style.lineSpacing }
            y += ceil(ascent + descent + leading)
            ranges.append(start..<(start + count))
            widths.append(lineWidth)
            start += count
        }
        return (ranges, widths, ceil(y))
    }

    // MARK: 1. Sliding-Window CTTypesetter (Parity, Extreme Length, Boundary Fuzzing, BiDi, Zalgo)

    @Test func giantSingleParagraphStaysLinearWithSpacesAndZeroSpaces() {
        // 256 KB prose without newlines (used to take ~3,000 ms with O(N^2) ICU).
        let word = "performance "
        let spaced = String(repeating: word, count: 256 * 1024 / word.utf8.count)
        let spacedStart = ContinuousClock.now
        let spacedLayout = RowLayoutBuilder.prose(
            [.paragraph([MarkdownInline(text: spaced)])], width: 728, style: style)
        let spacedElapsed = spacedStart.duration(to: .now)
        #expect(spacedLayout.lines.count > 1_000)
        #expect(spacedLayout.lines.first?.range.lowerBound == 0)
        #expect(spacedLayout.lines.last?.range.upperBound == spaced.utf16.count)
        #expect(spacedElapsed < .seconds(2), "256 KB spaced paragraph took \(spacedElapsed)")
        verifyTextLayoutInvariants(spacedLayout, maxWidth: 728)

        // 256 KB zero-space minified JSON / base64 token.
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
        let unspaced = String(repeating: token, count: 256 * 1024 / token.utf8.count)
        let unspacedStart = ContinuousClock.now
        let unspacedLayout = RowLayoutBuilder.prose(
            [.paragraph([MarkdownInline(text: unspaced)])], width: 728, style: style)
        let unspacedElapsed = unspacedStart.duration(to: .now)
        #expect(unspacedLayout.lines.count > 1_000)
        #expect(unspacedLayout.lines.last?.range.upperBound == unspaced.utf16.count)
        #expect(unspacedElapsed < .seconds(2), "256 KB zero-space paragraph took \(unspacedElapsed)")
        verifyTextLayoutInvariants(unspacedLayout, maxWidth: 728)
    }

    @Test func slidingWindowMatchesUnslicedCoreTextExactlyOnLtrProseAndStyledRuns() {
        let baseWords = [
            "Sliding", "window", "typesetter", "café", "👩🏽‍💻", "漢字", "alpha-beta",
            "https://example.com/path", "12345", "end.",
        ]
        var inlines: [MarkdownInline] = []
        var totalUTF16 = 0
        var i = 0
        while totalUTF16 < 10_000 {
            let text = baseWords[i % baseWords.count] + " "
            let inlineStyle: MarkdownInline.Style =
                switch i % 5 {
                case 1: .strong
                case 2: .emphasis
                case 3: .code
                default: []
                }
            inlines.append(MarkdownInline(text: text, style: inlineStyle))
            totalUTF16 += text.utf16.count
            i += 1
        }
        let styled = AttributedTextBuilder.build([.paragraph(inlines)], style: style)
        #expect(styled.length > TextLayoutEngine.slidingWindowThreshold)

        for width in [CGFloat(220), 420, 728] {
            let actual = TextLayoutEngine.layout(
                styled, width: width, options: .init(lineSpacing: style.lineSpacing, quoteBarWidth: style.quoteBarWidth))
            let reference = unslicedReferenceLayout(styled, width: width)
            #expect(actual.lines.count == reference.lineRanges.count, "width \(width)")
            #expect(actual.lines.map(\.range) == reference.lineRanges, "line ranges width \(width)")
            #expect(actual.size.height == reference.totalHeight, "height width \(width)")
            verifyTextLayoutInvariants(actual, maxWidth: width)
        }
    }

    @Test func slidingWindowBoundaryFuzzerPreservesAllUnicodeAndCaretInvariants() {
        var rng = FuzzRNG(seed: 0xDEAD_BEEF_CAFE_0001)
        let widths: [CGFloat] = [120, 280, 480, 728]

        for iteration in 0..<24 {
            // Deliberately build strings of 5,000..9,000 UTF-16 units so multiple
            // 2 KB window boundaries land inside random Unicode clusters.
            let targetLength = rng.int(in: 5_000..<9_000)
            var parts: [String] = []
            var utf16Count = 0
            while utf16Count < targetLength {
                let token = TranscriptFuzz.adversarialTokens[rng.int(in: 0..<TranscriptFuzz.adversarialTokens.count)]
                parts.append(token)
                utf16Count += token.utf16.count
            }
            let text = parts.joined()
            let width = widths[iteration % widths.count]
            let layout = RowLayoutBuilder.prose([.paragraph([MarkdownInline(text: text)])], width: width, style: style)
            verifyTextLayoutInvariants(layout, maxWidth: width, allowWideAtomicCluster: true)

            // Verify no line break splits a UTF-16 surrogate pair.
            let ns = text as NSString
            for line in layout.lines where line.range.upperBound < ns.length {
                let lastUnit = ns.character(at: line.range.upperBound - 1)
                let nextUnit = ns.character(at: line.range.upperBound)
                let splitSurrogate = (0xD800...0xDBFF).contains(lastUnit) && (0xDC00...0xDFFF).contains(nextUnit)
                #expect(!splitSurrogate, "iteration \(iteration) split surrogate pair at \(line.range.upperBound)")
            }
        }
    }

    @Test func biDiArabicAndZalgoStressRemainValidAndBounded() {
        // Mixed Arabic RTL + Eastern Arabic numerals + Latin exceeding slidingWindowThreshold.
        let arabicChunk = "مرحبا بالعالم ٢٥ Hello world שלום 👋 עולם أبا "
        let longBiDi = String(repeating: arabicChunk, count: 160)
        #expect(longBiDi.utf16.count > TextLayoutEngine.slidingWindowThreshold)
        let biDiLayout = RowLayoutBuilder.prose(
            [.paragraph([MarkdownInline(text: longBiDi)])], width: 420, style: style)
        #expect(biDiLayout.hasComplexBiDi)
        #expect(biDiLayout.lines.first?.range.lowerBound == 0)
        #expect(biDiLayout.lines.last?.range.upperBound == longBiDi.utf16.count)
        verifyTextLayoutInvariants(biDiLayout, maxWidth: 420, checkMonotonicCarets: false)

        // Pathological Zalgo combining-mark chain (Ghostty DoS vector).
        let zalgo = "prefix " + "a" + String(repeating: "\u{0301}", count: 500) + " suffix"
        let zalgoLayout = RowLayoutBuilder.prose(
            [.paragraph([MarkdownInline(text: zalgo)])], width: 320, style: style)
        #expect(!zalgoLayout.lines.isEmpty)
        #expect(zalgoLayout.size.height.isFinite && zalgoLayout.size.height > 0)
        verifyTextLayoutInvariants(zalgoLayout, maxWidth: 320, allowWideAtomicCluster: true)
    }

    // MARK: 2. Horizontal + Vertical 2D Tiling & Wide Blocks

    @Test func giantSingleCodeLineTilesHorizontallyWithinSurfaceMemoryCap() {
        // 100 KB single minified JSON line inside a code block.
        let unit = #"{"id":12345,"name":"transcript-engine","ok":true},"#
        let longLine = "[" + String(repeating: unit, count: 100_000 / unit.utf8.count) + "]"
        let key = RowLayoutKey(contentVersion: 0, width: 700, styleVersion: style.version)
        let layout = RowLayoutBuilder.layout(
            RowLayoutRequest(
                rowID: "wide-code",
                kind: .markdownBlock(.code(language: "json", code: longLine), .single),
                key: key, style: style))
        guard let wide = layout.content.wideBody else {
            Issue.record("expected wideBody for 100 KB single code line")
            return
        }
        #expect(wide.contentWidth > 100_000)

        let palette = TextPalette.resolveForTests
        let rowLayer = RowLayer()
        rowLayer.frame = CGRect(x: 0, y: 0, width: wide.contentWidth, height: wide.frame.height)
        rowLayer.show(
            rowID: "wide-code",
            layout: RowLayout(rowID: "wide-code", key: key, height: wide.frame.height, content: wide.content),
            palette: palette, drawsWideBody: true, scale: 2)

        // Draw only a viewport window at x = 50,000 (simulating scrolled-right wide code).
        let drawRect = CGRect(x: 50_000, y: 0, width: 1_400, height: wide.frame.height)
        rowLayer.drawBands(in: drawRect, visible: drawRect, offMain: false)
        let mountedBands = rowLayer.sublayers?.compactMap { $0 as? RowBandLayer } ?? []
        #expect((2...4).contains(mountedBands.count))
        for band in mountedBands {
            #expect(band.frame.width <= RowLayer.bandWidth)
            #expect(band.frame.height <= RowLayer.bandHeight)
            guard let surface = band.contents as? IOSurface else {
                Issue.record("expected non-nil IOSurface for wide tile \(band.frame)")
                continue
            }
            #expect(surface.width <= 16_384 && surface.height <= 16_384)
            #expect(surface.allocationSize <= 16 * 1024 * 1024, "tile surface \(surface.allocationSize) B exceeded 16 MB")
        }

        // Scrolling far away releases old tiles cleanly.
        let farRect = CGRect(x: 0, y: 0, width: 768, height: wide.frame.height)
        rowLayer.releaseBands(outside: farRect)
        let afterRelease = rowLayer.sublayers?.compactMap { $0 as? RowBandLayer } ?? []
        #expect(afterRelease.isEmpty)

        // Streaming DrawnBands pre-draw must also stay bounded to leftmost 2 columns.
        let streamed = DrawnBands.draw(
            layout, after: nil, palette: palette, scale: 2, colorSpace: RowLayer.colorSpace)
        #expect(!streamed.wideBands.isEmpty)
        #expect(streamed.wideBands.count <= 2)
        for item in streamed.wideBands {
            #expect(item.frame.width <= RowLayer.bandWidth)
            #expect(item.bitmap != nil)
            if let surface = item.bitmap?.surface {
                #expect(surface.allocationSize <= 16 * 1024 * 1024)
            }
        }
    }

    @Test func horizontalGlyphCullingMatchesFullRenderBitForBit() throws {
        let code = (0..<200).map { "token_\($0)_value" }.joined(separator: " ")
        let codeLayout = CodeLayout.make(code: code, language: "swift", colors: nil, width: 400, style: style)
        let palette = TextPalette.resolveForTests
        let tile = CGRect(x: 768, y: 0, width: 768, height: min(512, codeLayout.body.size.height + 16))

        func render(clipped: Bool) -> [UInt8] {
            let w = Int(ceil(tile.width))
            let h = Int(ceil(tile.height))
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            let space = RowLayer.colorSpace
            let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            pixels.withUnsafeMutableBytes { buf in
                guard let ctx = CGContext(
                    data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: space, bitmapInfo: info)
                else { return }
                ctx.translateBy(x: 0, y: CGFloat(h))
                ctx.scaleBy(x: 1, y: -1)
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                ctx.translateBy(x: -tile.minX, y: -tile.minY)
                let drawClip = clipped
                    ? tile
                    : CGRect(x: 0, y: tile.minY, width: codeLayout.contentWidth + 100, height: tile.height)
                TextRenderer.draw(codeLayout.body, at: CGPoint(x: codeLayout.bodyOrigin.x, y: 0), clip: drawClip, palette: palette, in: ctx)
            }
            return pixels
        }

        let culled = render(clipped: true)
        let full = render(clipped: false)
        #expect(culled == full)
        #expect(culled.contains { $0 != 0 })
    }

    @Test func giantTablesTileWithinMemoryLimits() {
        // 500 rows x 10 cols (tall) and 5 rows x 100 cols (wide).
        let tallHeader = (0..<10).map { [MarkdownInline(text: "Col \($0)")] }
        let tallRows = (0..<500).map { r in (0..<10).map { c in [MarkdownInline(text: "r\(r)c\(c)")] } }
        let tallTable = MarkdownTable(
            alignments: Array(repeating: .leading, count: 10), header: tallHeader, rows: tallRows)
        let tallLayout = TableLayout.make(tallTable, width: 700, style: style)
        #expect(tallLayout.cells.count == 5_010)
        #expect(tallLayout.gridSize.height > 10_000)

        let wideHeader = (0..<100).map { [MarkdownInline(text: "Header\($0)")] }
        let wideRows = (0..<5).map { r in (0..<100).map { c in [MarkdownInline(text: "cell-\(r)-\(c)")] } }
        let wideTable = MarkdownTable(
            alignments: Array(repeating: .leading, count: 100), header: wideHeader, rows: wideRows)
        let wideLayout = TableLayout.make(wideTable, width: 700, style: style)
        #expect(wideLayout.isWiderThanBlock)
        #expect(wideLayout.gridSize.width > 10_000)

        let palette = TextPalette.resolveForTests
        let tile = CGRect(x: 3_072, y: 0, width: RowLayer.bandWidth, height: min(RowLayer.bandHeight, wideLayout.gridSize.height))
        let bitmap = BandRasterizer.bitmap(
            BandRaster(
                content: .tableBody(wideLayout), palette: palette, drawsWideBody: true, rect: tile, scale: 2,
                colorSpace: RowLayer.colorSpace))
        #expect(bitmap != nil)
        if let surface = bitmap?.surface {
            #expect(surface.allocationSize <= 16 * 1024 * 1024)
        }
    }

    // MARK: 3. Bounded Row Chunking, Memory-Budget Eviction & Non-Blocking Accessibility

    @Test func tall20000LineCodeBlockChunksSeamlesslyAndEvictsByByteBudget() {
        let code = (0..<20_000).map { "let line\($0) = \($0) * 2" }.joined(separator: "\n")
        let rows = TranscriptRowChunker.assistantRows(
            messageID: "t1|a1", turnID: "t1", blocks: [.code(language: "swift", code: code)])
        #expect(rows.count == 100)
        #expect(rows.allSatisfy { $0.sourceID == "t1|a1" && $0.messageID == "t1|a1" })

        let controller = TranscriptController(configuration: .testing)
        controller.setRows(rows)
        #expect(controller.fullCodeText(startingAtRowID: rows[0].id) == code)

        // Selection across all chunks reproduces the exact 20,000-line source.
        controller.selectAll()
        #expect(controller.selectedText() == code)

        // First chunk has header + Copy accessory; middle/last have no header.
        let key = RowLayoutKey(contentVersion: 0, width: 600, styleVersion: style.version)
        let firstLayout = RowLayoutBuilder.layout(RowLayoutRequest(rowID: rows[0].id, kind: rows[0].kind, key: key, style: style))
        let midLayout = RowLayoutBuilder.layout(RowLayoutRequest(rowID: rows[1].id, kind: rows[1].kind, key: key, style: style))
        #expect(firstLayout.content.codeLayout?.headerHeight ?? 0 > 0)
        #expect(firstLayout.content.accessories(forRowID: rows[0].id).map(\.action) == [.copyChunkedCode(rowID: rows[0].id)])
        #expect(midLayout.content.codeLayout?.headerHeight == 0)
        #expect(midLayout.content.accessories(forRowID: rows[1].id).isEmpty)

        // Memory-budget eviction: 30 chunks of 200 wide lines hold ~30 MB of
        // layout (> 12 MB) in fewer rows than the 64-row cap; the off-window
        // ones go.
        let wide = (0..<6_000).map { "let line\($0) = " + String(repeating: "x", count: 150) }.joined(separator: "\n")
        let wideRows = TranscriptRowChunker.assistantRows(
            messageID: "t1|a2", turnID: "t1", blocks: [.code(language: "swift", code: wide)])
        controller.setRows(wideRows)
        for row in wideRows.prefix(30) {
            controller.storeLayout(
                RowLayoutBuilder.layout(RowLayoutRequest(rowID: row.id, kind: row.kind, key: key, style: style)))
        }
        #expect(controller.layouts.count == 30)
        #expect(controller.cachedLayoutBytes > 12 << 20)
        controller.dropLayouts(outside: 0...1_000)
        #expect(controller.layouts.count < 30)
        #expect(controller.cachedLayoutBytes == controller.layouts.values.reduce(0) { $0 + $1.content.retainedBytes })
    }

    @Test func giant500KBUserMessageChunksAndPreservesExactTextAndFastAccessibility() {
        // 1. Newline-separated 500 KB log.
        let logLine = "[2026-11-23 22:00:00] INFO worker=3 processed batch_id=987654321 duration_ms=12\n"
        let bigLog = String(repeating: logLine, count: 500_000 / logLine.utf8.count)
        let logRows = TranscriptRowChunker.userRows(messageID: "t1|u1", turnID: "t1", source: bigLog)
        #expect(logRows.count > 20)
        #expect(logRows.allSatisfy { $0.sourceID == "t1|u1" })

        // Split, it copies as it would whole: Markdown rendered either way.
        let controller = TranscriptController(configuration: .testing)
        controller.setRows(logRows)
        controller.selectAll()
        #expect(controller.selectedText() == RowSelectableText.string(for: .userMessage(source: bigLog), style: style))

        // Accessibility query must not parse Markdown synchronously on MainActor.
        let a11yStart = ContinuousClock.now
        let accessible = controller.accessibleRows(minY: 0, maxY: 800, columnX: 0)
        let a11yElapsed = a11yStart.duration(to: .now)
        #expect(!accessible.isEmpty)
        #expect(accessible[0].text.hasPrefix("You: "))
        if accessible.count > 1 {
            #expect(!accessible[1].text.hasPrefix("You: "))
        }
        #expect(a11yElapsed < .milliseconds(50), "a11y query took \(a11yElapsed)")

        // 2. Zero-newline 500 KB minified JSON pasted by user.
        let jsonUnit = #"{"key":"value","nested":[1,2,3],"emoji":"👩🏽‍💻"},"#
        let bigJSON = String(repeating: jsonUnit, count: 500_000 / jsonUnit.utf8.count)
        let jsonRows = TranscriptRowChunker.userRows(messageID: "t2|u1", turnID: "t2", source: bigJSON)
        #expect(jsonRows.count > 20)
        let controller2 = TranscriptController(configuration: .testing)
        controller2.setRows(jsonRows)
        controller2.selectAll()
        #expect(controller2.selectedText() == RowSelectableText.string(for: .userMessage(source: bigJSON), style: style))
    }

    @Test func giantParagraphChunksWithoutSplittingEmojiOrInjectingNewlines() {
        let unit = "The quick 👩🏽‍💻 brown fox jumps over café lazy dog. "
        let text = String(repeating: unit, count: 2_500)  // ~140 KB
        let rows = TranscriptRowChunker.assistantRows(
            messageID: "m1", turnID: "t1", blocks: [.paragraph([MarkdownInline(text: text)])])
        #expect(rows.count > 5)

        let controller = TranscriptController(configuration: .testing)
        controller.setRows(rows)
        controller.selectAll()
        #expect(controller.selectedText() == text)

        // Verify UIKit UITextInput position/offset math matches selectedText UTF-16 count.
        if let first = controller.firstTextPosition, let last = controller.lastTextPosition {
            #expect(controller.offset(from: first, to: last) == text.utf16.count)
            #expect(controller.position(from: first, offset: text.utf16.count) == last)
        }
    }

    // MARK: 4. Parse-Only Split for 2,000-Block Messages

    @Test func messageWith2000BlocksParsesWithoutEagerlyLayingOutOffscreenBlocks() async throws {
        let source = (0..<2_000).map { "Paragraph number \($0) with enough words to measure." }.joined(separator: "\n\n")
        let controller = TranscriptController(configuration: .launch)
        let host = FakeTranscriptHost()
        host.size = CGSize(width: 600, height: 400)
        host.controller = controller
        controller.attach(host)
        // Push out the 1 s readiness fallback so parallel Debug test CPU load
        // never reveals before the viewport's async layouts land.
        controller.openStarted = ContinuousClock.now.advanced(by: .seconds(60))

        let pending = TranscriptRow(
            id: "big#pending", sourceID: "big", kind: .pendingMessage(source: source),
            messageID: "big", role: .assistant, turnID: "t1")
        controller.setRows([pending])

        for _ in 0..<250 where controller.isAwaitingInitialEnd {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!controller.isAwaitingInitialEnd)
        #expect(controller.rows.count == 2_000)
        // Must have laid out ONLY the viewport + prefetch window, nowhere near all 2,000 blocks.
        #expect(controller.layouts.count < 200)
        #expect(!controller.layouts.isEmpty)
    }

    // MARK: 5. 5 MB Multi-Turn Chat + 200 Live Tool Updates

    @Test func fiveMBChatWith200LiveToolUpdatesStaysFastAndLazyCopiesReply() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let summary = ThreadFixtures.summary(
            id: "big-thread", title: "5 MB Chat", cwd: "/tmp", agent: ("a", "A"), status: .running,
            createdAt: base, updatedAt: base)
        let payload = String(repeating: "Detailed analysis of the subsystem state and logs.\n", count: 2_500)  // ~125 KB
        var turns: [TurnView] = []
        for t in 0..<40 {
            let turnID = "turn-\(t)"
            turns.append(
                ThreadFixtures.turn(
                    id: turnID, participant: summary.participants[0].id, state: .completed,
                    startedAt: base.addingTimeInterval(Double(t) * 60),
                    settledAt: base.addingTimeInterval(Double(t) * 60 + 10),
                    entries: [
                        ThreadFixtures.entry(ref: "u", kind: .userMessage, text: "Prompt \(t)"),
                        ThreadFixtures.entry(ref: "a", kind: .assistantMessage, text: payload + "turn-\(t)"),
                    ]))
        }
        let liveTurn = ThreadFixtures.turn(
            id: "turn-live", participant: summary.participants[0].id, state: .running,
            startedAt: base.addingTimeInterval(3_000), settledAt: nil,
            entries: [ThreadFixtures.entry(ref: "u", kind: .userMessage, text: "Run checks")])
        turns.append(liveTurn)

        var detail = ThreadFixtures.detail(summary: summary, turns: turns)
        let store = ThreadStore(previewThreads: [summary], selectedThread: detail)
        let controller = TranscriptController(configuration: .testing)
        let host = FakeTranscriptHost()
        host.size = CGSize(width: 600, height: 400)
        host.controller = controller
        controller.attach(host)
        controller.start(store: store, threadID: detail.id)

        // Lazy reply copy returns exact Markdown for finished turn 0.
        #expect(controller.replyMarkdown(forTurnID: "turn-0") == payload + "turn-0")

        // Simulate 200 live tool events on turn-live through incremental turn updates.
        let start = ContinuousClock.now
        for step in 0..<200 {
            let event = ThreadEvent(
                delivery: nil,
                entry: ThreadFixtures.entry(ref: "tool-\(step)", kind: .toolCall, title: "Read file \(step)"),
                kind: MaidThreadEventKind.entry.rawValue,
                participant: nil, plan: nil, request: nil, resolved: nil,
                seq: detail.seq + 1, summary: nil, text: nil, thread: detail.id,
                turn: liveTurn)
            _ = detail.apply(event)
            let tailIndex = detail.turns.count - 1
            controller.turns[tailIndex] = TranscriptTurn(detail.turns[tailIndex])
            controller.turnRevisions = detail.turnRevisions
            controller.rebuildRows(fromTurnIndex: tailIndex)
        }
        let elapsed = start.duration(to: .now)
        #expect(elapsed < .milliseconds(400), "200 live tool updates on 5 MB chat took \(elapsed)")
    }

    // MARK: 6. LegendList-Style Geometry & ReadingPlace Invariant Fuzzer

    @Test func geometryAndReadingPlaceInvariantFuzzer() {
        var rng = FuzzRNG(seed: 0x1E6E_D115_7000_0001)
        var geometry = TranscriptGeometry()
        var modelIDs: [String] = []
        var modelSources: [String] = []
        var modelHeights: [CGFloat] = []
        var nextID = 0

        func makeID() -> String {
            nextID += 1
            return "r\(nextID)"
        }

        // Seed 60 rows.
        for i in 0..<60 {
            let id = makeID()
            modelIDs.append(id)
            modelSources.append("src-\(i / 3)")
            modelHeights.append(CGFloat(rng.int(in: 12..<240)))
        }
        geometry.replace(ids: modelIDs, sources: modelSources) { modelHeights[$0] }

        for step in 0..<400 {
            let op = rng.int(in: 0..<3)
            if op == 0, !modelIDs.isEmpty {
                // Random height updates.
                var updates: [String: CGFloat] = [:]
                for _ in 0..<rng.int(in: 1..<6) {
                    let idx = rng.int(in: 0..<modelIDs.count)
                    let h = CGFloat(rng.int(in: 1..<500))
                    modelHeights[idx] = h
                    updates[modelIDs[idx]] = h
                }
                let anchorTop = CGFloat(rng.int(in: 0..<max(1, Int(geometry.totalHeight))))
                let place = geometry.readingPlace(atViewportTop: anchorTop, includeFallbacks: false)
                geometry.setHeights(updates)
                if let place, let resolved = geometry.offset(for: place),
                    let anchorIdx = geometry.index(for: place.anchorID)
                {
                    let expected = geometry.offset(at: anchorIdx) + min(place.offsetIntoRow, geometry.height(at: anchorIdx))
                    #expect(resolved == expected, "step \(step) height anchor drift")
                }
            } else {
                // Random range replacement (insert, grow, shrink, delete).
                let start = modelIDs.isEmpty ? 0 : rng.int(in: 0..<(modelIDs.count + 1))
                let maxRemove = min(6, modelIDs.count - start)
                let removeCount = maxRemove > 0 ? rng.int(in: 0..<(maxRemove + 1)) : 0
                let addCount = rng.int(in: 0..<6)
                let range = start..<(start + removeCount)
                let source = "src-\(rng.int(in: 0..<30))"
                let newIDs = (0..<addCount).map { _ in makeID() }
                let newSources = Array(repeating: source, count: addCount)
                let newHeights = (0..<addCount).map { _ in CGFloat(rng.int(in: 1..<400)) }

                let anchorTop = geometry.totalHeight > 0 ? CGFloat(rng.int(in: 0..<Int(geometry.totalHeight))) : 0
                let fastPlace = geometry.readingPlace(atViewportTop: anchorTop, replacingRange: range)
                let fullPlace = geometry.readingPlace(atViewportTop: anchorTop, includeFallbacks: true)

                modelIDs.replaceSubrange(range, with: newIDs)
                modelSources.replaceSubrange(range, with: newSources)
                modelHeights.replaceSubrange(range, with: newHeights)
                geometry.replaceRows(range, ids: newIDs, sources: newSources, heights: newHeights)

                // Fast zero-COW ReadingPlace must agree 100% with full fallback ReadingPlace!
                #expect(
                    fastPlace.flatMap(geometry.offset(for:)) == fullPlace.flatMap(geometry.offset(for:)),
                    "step \(step) fast vs full ReadingPlace mismatch")
            }

            // Full structural invariant oracle after every single mutation.
            verifyGeometryInvariants(geometry, ids: modelIDs, heights: modelHeights, step: step)
        }
    }

    // MARK: Structural Invariant Oracles

    private func verifyTextLayoutInvariants(
        _ layout: TextLayout, maxWidth: CGFloat, checkMonotonicCarets: Bool = true,
        allowWideAtomicCluster: Bool = false
    ) {
        let totalUTF16 = layout.string.utf16.count
        guard totalUTF16 > 0 else {
            #expect(layout.lines.isEmpty)
            return
        }
        #expect(!layout.lines.isEmpty)
        #expect(layout.lines.first?.range.lowerBound == 0)
        #expect(layout.lines.last?.range.upperBound == totalUTF16)
        #expect(layout.size.width.isFinite && layout.size.height.isFinite)
        #expect(layout.size.height == ceil(layout.lines.last?.bottom ?? 0))

        for index in layout.lines.indices {
            let line = layout.lines[index]
            #expect(!line.range.isEmpty)
            #expect(line.top.isFinite && line.height.isFinite && line.height > 0)
            #expect(line.caretOffsets.count == line.range.count + 1)
            if !allowWideAtomicCluster {
                #expect(line.x + line.width <= maxWidth + 2, "line \(index) overflowed width \(maxWidth)")
            }
            if index > 0 {
                let prev = layout.lines[index - 1]
                #expect(prev.range.upperBound == line.range.lowerBound)
                #expect(line.top >= prev.bottom)
            }
            if checkMonotonicCarets && !layout.hasComplexBiDi {
                for c in 1..<line.caretOffsets.count {
                    #expect(line.caretOffsets[c] >= line.caretOffsets[c - 1] - 0.01)
                }
            } else {
                #expect(line.caretOffsets.allSatisfy { $0.isFinite })
            }
        }
        // Spot-check hit-test and selection rects stay in bounds and finite.
        for probe in [0, totalUTF16 / 2, max(0, totalUTF16 - 1)] {
            let lineIdx = layout.lines.firstIndex { $0.range.contains(probe) } ?? 0
            let line = layout.lines[lineIdx]
            let caretX = line.caretOffsets[min(probe - line.range.lowerBound, line.caretOffsets.count - 1)]
            let hit = layout.offset(closestTo: CGPoint(x: caretX, y: line.top + line.height / 2))
            #expect(hit >= 0 && hit <= totalUTF16)
        }
        let rects = layout.selectionRects(for: 0..<min(totalUTF16, 128))
        #expect(rects.allSatisfy { $0.minX.isFinite && $0.minY.isFinite && $0.width >= 0 && $0.height >= 0 })
    }

    private func verifyGeometryInvariants(
        _ geometry: TranscriptGeometry, ids: [String], heights: [CGFloat], step: Int
    ) {
        #expect(geometry.count == ids.count, "step \(step) count")
        var running: CGFloat = 0
        for i in 0..<ids.count {
            #expect(geometry.offset(at: i) == running, "step \(step) offset[\(i)]")
            #expect(geometry.height(at: i) == heights[i], "step \(step) height[\(i)]")
            #expect(geometry.index(for: ids[i]) == i, "step \(step) index[\(ids[i])]")
            #expect(geometry.index(at: running) == i, "step \(step) index(at: \(running))")
            if heights[i] > 1 {
                #expect(geometry.index(at: running + heights[i] - 0.5) == i, "step \(step) end-of-row lookup")
            }
            running += heights[i]
        }
        #expect(geometry.totalHeight == running, "step \(step) totalHeight")
    }

    // MARK: Adversarial Review Regression Tests

    @Test func unchunkedUserMessageSelectableTextMatchesLaidOutText() {
        let source = "Check **bold**, *italic*, `code`, and [link](https://example.com)."
        let kind = TranscriptRowKind.userMessage(source: source, position: .single)
        let key = RowLayoutKey(contentVersion: 0, width: 728, styleVersion: style.version)
        let laidOut = RowLayoutBuilder.layout(RowLayoutRequest(rowID: "u", kind: kind, key: key, style: style))
        let fallback = RowSelectableText.string(for: kind, style: style)
        #expect(fallback == laidOut.content.selectableString)
        #expect(fallback == "Check bold, italic, code, and link.")
    }

    @Test func splitUserMessageKeepsItsTrailingNewline() {
        for count in [200, 400] {
            let source = String(repeating: "x\n", count: count)
            let rows = TranscriptRowChunker.userRows(messageID: "m-\(count)", turnID: "t", source: source)
            #expect(rows.count == (count > 200 ? 2 : 1))
            var joined = ""
            for (index, row) in rows.enumerated() {
                if index > 0 { joined.append(row.separatorBefore) }
                if case .userMessage(let text, _) = row.kind { joined.append(text) }
            }
            #expect(joined == source)
        }
    }

    @Test func replaceRowsReestimatesHeightWhenRowKindChangesAndStreamingMatchesBuilder() {
        let bigCode = (0..<1_000).map { "line \($0)" }.joined(separator: "\n")
        let block = MarkdownBlock.code(language: "txt", code: bigCode)

        // Streaming builder must emit unchunked rows matching applyStreamRows.
        let streamingBuilder = TranscriptBuilder(
            blocks: { _, _ in [block] }, isStreaming: { $0 == "t|m" }, expandedTurnIDs: [], workingPhrase: "Working")
        let turn = TranscriptTurn(
            ThreadFixtures.turn(
                id: "t", participant: "a", state: .running, startedAt: Date(), settledAt: nil,
                entries: [ThreadFixtures.entry(ref: "m", kind: .assistantMessage, text: "```txt\n\(bigCode)\n```")]))
        let streamingRows = streamingBuilder.rows(for: [turn])
        let assistantStreamingRows = streamingRows.filter { $0.sourceID == "t|m" }
        #expect(assistantStreamingRows.count == 1)

        // Finishing replaces unchunked m#0 (huge measured height) with chunked rows;
        // chunk 0 must not inherit the old 1,000-line height when its kind changed.
        let controller = TranscriptController(configuration: .testing)
        controller.columnWidth = 728
        let initialRow = TranscriptRow(
            id: "t|m#0", sourceID: "t|m", kind: .markdownBlock(block, .single),
            messageID: "t|m", role: .assistant, turnID: "t")
        controller.setRows([initialRow], measuredHeights: ["t|m#0": 18_000])
        #expect(controller.geometry.height(at: 0) == 18_000)

        let chunked = TranscriptRowChunker.assistantRows(messageID: "t|m", turnID: "t", blocks: [block])
        #expect(chunked.count == 5)
        controller.replaceRows(0..<1, with: chunked, heights: [:])
        #expect(controller.geometry.height(at: 0) < 5_000)
    }

    @Test func parsedMessageEvictionRetainsMessagesVisibleViaLaterBlock() {
        let controller = TranscriptController(configuration: .testing)
        let host = FakeTranscriptHost()
        host.size = CGSize(width: 800, height: 600)
        host.controller = controller
        controller.attach(host)

        // Build 18 parsed messages (~1 MB each = 18 MB > 16 MB cap).
        let bigBlock = MarkdownBlock.paragraph([MarkdownInline(text: "hello", style: [])])
        let megabyte = String(repeating: "a", count: 1_048_576)
        var rows: [TranscriptRow] = []
        var heights: [String: CGFloat] = [:]
        for i in 0..<18 {
            let id = "t|m\(i)"
            let blockCount = (i == 0) ? 3 : 2
            for b in 0..<blockCount {
                let rowID = "\(id)#\(b)"
                rows.append(
                    TranscriptRow(
                        id: rowID, sourceID: id, kind: .markdownBlock(bigBlock, .single),
                        messageID: id, role: .assistant, turnID: "t"))
                // m0#0 sits at y = 0..100 (well above keptWindow 3900...6900),
                // m0#1 bridges 100..5100, and m0#2 sits squarely in the viewport (5100..5200).
                heights[rowID] = (i == 0 && b == 1) ? 5_000 : 100
            }
        }
        controller.setRows(rows, measuredHeights: heights)
        // Reveal initial end, then scroll so m0#2 is visible while m0#0 is 3,800 pt above keptWindow.
        controller.alignInitialEndIfPossible()
        host.readerScroll(toTop: 5_100)

        for i in 0..<18 {
            controller.cacheParsedMessage(id: "t|m\(i)", source: megabyte, blocks: [bigBlock])
        }
        #expect(controller.parsedMessages["t|m0"] != nil)
    }

    @Test func slidingWindowExpandsWhenSingleLineExceedsWindowSize() {
        let text = "a" + String(repeating: " ", count: 5_000) + "b"
        let styled = AttributedTextBuilder.plain(text, role: .body, color: .primary, style: style)
        let layout = TextLayoutEngine.layout(
            styled, width: 728, options: .init(lineSpacing: style.lineSpacing))

        // Reference unsliced CoreText line count & break offsets.
        let typesetter = CTTypesetterCreateWithAttributedString(styled.string)
        let total = styled.string.length
        var refRanges: [Range<Int>] = []
        var offset = 0
        while offset < total {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, offset, 728))
            refRanges.append(offset..<(offset + count))
            offset += count
        }
        #expect(layout.lines.map(\.range) == refRanges)
        #expect(layout.lines.count == 2)
        #expect(layout.lines[1].caretOffsets.first == 0)
    }

    @Test func drawnBandsRedrawsShrunkWideTile() {
        let wideLine = String(repeating: "W", count: 160)
        let narrowerLine = String(repeating: "W", count: 130)
        let key1 = RowLayoutKey(contentVersion: 1, width: 728, styleVersion: style.version)
        let key2 = RowLayoutKey(contentVersion: 2, width: 728, styleVersion: style.version)
        let l1 = RowLayoutBuilder.layout(
            RowLayoutRequest(rowID: "c", kind: .markdownBlock(.code(language: nil, code: wideLine), .single), key: key1, style: style))
        let l2 = RowLayoutBuilder.layout(
            RowLayoutRequest(rowID: "c", kind: .markdownBlock(.code(language: nil, code: narrowerLine), .single), key: key2, style: style))
        guard let b1 = l1.content.wideBody, let b2 = l2.content.wideBody else {
            Issue.record("Expected wide bodies")
            return
        }
        #expect(b1.contentWidth > RowLayer.bandWidth)
        #expect(b2.contentWidth > RowLayer.bandWidth)
        #expect(b2.contentWidth < b1.contentWidth)
        let palette = TextPalette.resolveForTests
        let drawn = DrawnBands.draw(l2, after: l1, palette: palette, scale: 2, colorSpace: RowLayer.colorSpace)
        let shrunkCol1Frame = CGRect(
            x: RowLayer.bandWidth, y: 0, width: b2.contentWidth - RowLayer.bandWidth, height: b2.frame.height)
        #expect(drawn.wideBands.contains { $0.frame == shrunkCol1Frame })
    }
}
