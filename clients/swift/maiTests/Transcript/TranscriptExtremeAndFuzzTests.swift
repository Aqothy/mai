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
nonisolated struct TranscriptExtremeAndFuzzTests {
    // MARK: 1. Sliding-Window CTTypesetter (Extreme Length, BiDi, Zalgo)

    @Test func giantSingleParagraphStaysLinearWithSpacesAndZeroSpaces() async {
        let style = await TextStyle.current()
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

    @Test func biDiArabicAndZalgoStressRemainValidAndBounded() async {
        let style = await TextStyle.current()
        // Mixed Arabic RTL + Eastern Arabic numerals + Latin exceeding 4 KB.
        let arabicChunk = "مرحبا بالعالم ٢٥ Hello world שלום 👋 עולם أبا "
        let longBiDi = String(repeating: arabicChunk, count: 160)
        #expect(longBiDi.utf16.count > 4_096)
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

    @MainActor @Test func giantSingleCodeLineTilesHorizontallyWithinSurfaceMemoryCap() async {
        let style = TextStyle.current()
        // 100 KB single minified JSON line inside a code block.
        let unit = #"{"id":12345,"name":"transcript-engine","ok":true},"#
        let longLine = "[" + String(repeating: unit, count: 100_000 / unit.utf8.count) + "]"
        let key = RowLayoutKey(contentVersion: 0, width: 700, styleVersion: style.version)
        let layout = await Task.detached {
            RowLayoutBuilder.layout(
                RowLayoutRequest(
                    rowID: "wide-code",
                    kind: .markdownBlock(.code(language: "json", code: longLine), .single),
                    key: key, style: style))
        }.value
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

    @Test func horizontalGlyphCullingMatchesFullRenderBitForBit() async throws {
        let style = await TextStyle.current()
        let code = (0..<200).map { "token_\($0)_value" }.joined(separator: " ")
        let codeLayout = CodeLayout.make(code: code, language: "swift", colors: nil, width: 400, style: style)
        let palette = await TextPalette.resolveForTests
        let tile = CGRect(x: 768, y: 0, width: 768, height: min(512, codeLayout.bodySize.height + 16))

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
                codeLayout.drawBody(at: CGPoint(x: codeLayout.bodyOrigin.x, y: 0), clip: drawClip, palette: palette, in: ctx)
            }
            return pixels
        }

        let culled = render(clipped: true)
        let full = render(clipped: false)
        #expect(culled == full)
        #expect(culled.contains { $0 != 0 })
    }

    @Test func giantTablesTileWithinMemoryLimits() async {
        let style = await TextStyle.current()
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

        let palette = await TextPalette.resolveForTests
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

    // MARK: 3. Compact PreparedText Memory Footprint (`REDESIGN.md §4, §8`)

    @MainActor @Test func wideCodeBlocksAndProseStayCompactWithoutEviction() async {
        let style = TextStyle.current()
        let key = RowLayoutKey(contentVersion: 0, width: 600, styleVersion: style.version)
        let controller = TranscriptController(configuration: .testing)

        // 16 × 35 KB wide code blocks stay well under 1 MB total (no glyph copies).
        let chunk = (0..<200).map { "let line\($0) = " + String(repeating: "x", count: 160) }.joined(separator: "\n")
        let wideRows = (0..<16).map { index in
            TranscriptRow(
                id: "t1|a2#\(index)", sourceID: "t1|a2",
                kind: .markdownBlock(.code(language: "swift", code: chunk), .single),
                messageID: "t1|a2", role: .assistant, turnID: "t1")
        }
        controller.setRows(wideRows)
        let codeLayouts = await Task.detached {
            wideRows.map { RowLayoutBuilder.layout(RowLayoutRequest(rowID: $0.id, kind: $0.kind, key: key, style: style)) }
        }.value
        for layout in codeLayouts { controller.storeLayout(layout) }
        #expect(controller.cachedLayoutBytes < 1_024_000)

        // 40 × 12 KB prose rows hold compact segment + line geometry (< 3 MB total,
        // ~7× smaller than the old 12+ MB glyph-copying layout cache).
        let proseController = TranscriptController(configuration: .testing)
        let bigProse = String(repeating: "memory budget check ", count: 600)
        let proseRows = (0..<40).map { index in
            TranscriptRow(
                id: "t1|p#\(index)", sourceID: "t1|p",
                kind: .markdownBlock(.paragraph([MarkdownInline(text: bigProse)]), .single),
                messageID: "t1|p", role: .assistant, turnID: "t1")
        }
        proseController.setRows(proseRows)
        let proseLayouts = await Task.detached {
            proseRows.map { RowLayoutBuilder.layout(RowLayoutRequest(rowID: $0.id, kind: $0.kind, key: key, style: style)) }
        }.value
        for layout in proseLayouts { proseController.storeLayout(layout) }
        #expect(proseController.layouts.count == 40)
        #expect(proseController.cachedLayoutBytes < 4 << 20)
        #expect(proseController.cachedLayoutBytes == proseController.layouts.values.reduce(0) { $0 + $1.content.retainedBytes })
    }

    // MARK: 4. Exact Geometry Backfill for 2,000-Block Messages (`REDESIGN.md §4.6, §7 R3`)

    @MainActor @Test func messageWith2000BlocksParsesAndBackfillsExactGeometry() async throws {
        let source = (0..<2_000).map { "Paragraph number \($0) with enough words to measure." }.joined(separator: "\n\n")
        let controller = TranscriptController(configuration: .launch)
        let host = FakeTranscriptHost()
        host.size = CGSize(width: 600, height: 400)
        host.controller = controller
        controller.attach(host)
        controller.openStarted = ContinuousClock.now.advanced(by: .seconds(60))

        let pending = TranscriptMessage(kind: .assistant, turnID: "t1", ref: "big").pendingRow(source: source)
        controller.setRows([pending])

        for _ in 0..<250 where controller.isAwaitingInitialEnd {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!controller.isAwaitingInitialEnd)
        #expect(controller.rows.count == 2_000)
        // R3 parses and lays out all 2,000 blocks in one hop for exact geometry.
        #expect(controller.layouts.count == 2_000)
    }

    // MARK: 5. 5 MB Multi-Turn Chat + 200 Live Tool Updates

    @MainActor @Test func fiveMBChatWith200LiveToolUpdatesStaysFastAndLazyCopiesReply() {
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
            let carets = layout.caretOffsets(forLineAt: index)
            #expect(!line.range.isEmpty)
            #expect(line.top.isFinite && line.height.isFinite && line.height > 0)
            #expect(carets.count == line.range.count + 1)
            if !allowWideAtomicCluster {
                #expect(line.x + line.width <= maxWidth + 2, "line \(index) overflowed width \(maxWidth)")
            }
            if index > 0 {
                let prev = layout.lines[index - 1]
                #expect(prev.range.upperBound == line.range.lowerBound)
                #expect(line.top >= prev.bottom)
            }
            if checkMonotonicCarets && !layout.hasComplexBiDi {
                for c in 1..<carets.count {
                    #expect(carets[c] >= carets[c - 1] - 0.01)
                }
            } else {
                #expect(carets.allSatisfy { $0.isFinite })
            }
        }
        // Spot-check hit-test and selection rects stay in bounds and finite.
        for probe in [0, totalUTF16 / 2, max(0, totalUTF16 - 1)] {
            let lineIdx = layout.lines.firstIndex { $0.range.contains(probe) } ?? 0
            let line = layout.lines[lineIdx]
            let carets = layout.caretOffsets(forLineAt: lineIdx)
            let caretX = carets[min(probe - line.range.lowerBound, carets.count - 1)]
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

    @Test func unchunkedUserAndThoughtSelectableTextMatchesLaidOutText() async {
        let style = await TextStyle.current()
        let source = "Check **bold**, *italic*, `code`, and [link](https://example.com)."
        let blocks = MarkdownPlanner.blocks(from: source)
        let key = RowLayoutKey(contentVersion: 0, width: 728, styleVersion: style.version)
        for kind in [TranscriptRowKind.userMessage(blocks), TranscriptRowKind.thought(blocks)] {
            let laidOut = RowLayoutBuilder.layout(RowLayoutRequest(rowID: "u", kind: kind, key: key, style: style))
            let fallback = RowSelectableText.string(for: kind, style: style)
            #expect(fallback == laidOut.content.selectableString)
            #expect(fallback == "Check bold, italic, code, and link.")
        }
    }

    @MainActor @Test func replaceRowsReestimatesHeightWhenRowKindChanges() {
        let bigCode = (0..<1_000).map { "line \($0)" }.joined(separator: "\n")
        let block = MarkdownBlock.code(language: "txt", code: bigCode)
        let controller = TranscriptController(configuration: .testing)
        controller.columnWidth = 728
        let initialRow = TranscriptRow(
            id: "t|m#0", sourceID: "t|m", kind: .markdownBlock(block, .single),
            messageID: "t|m", role: .assistant, turnID: "t")
        controller.setRows([initialRow], measuredHeights: ["t|m#0": 18_000])
        #expect(controller.geometry.height(at: 0) == 18_000)

        let shortRow = TranscriptRow(
            id: "t|m#0", sourceID: "t|m",
            kind: .markdownBlock(.paragraph([MarkdownInline(text: "short")]), .single),
            messageID: "t|m", role: .assistant, turnID: "t")
        controller.replaceRows(0..<1, with: [shortRow], heights: [:])
        #expect(controller.geometry.height(at: 0) < 5_000)
    }

    @MainActor @Test func parsedMessageEvictionRetainsMessagesVisibleViaLaterBlock() {
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

    @Test func slidingWindowExpandsWhenSingleLineExceedsWindowSize() async {
        let style = await TextStyle.current()
        let text = "a" + String(repeating: " ", count: 5_000) + "b"
        let styled = AttributedTextBuilder.plain(text, role: .body, color: .primary, style: style)
        let layout = TextLayoutEngine.layout(
            styled, width: 728, options: .init(lineSpacing: style.lineSpacing))

        // Reference unsliced CoreText line count & break offsets.
        let ns = styled.text as NSString
        let typesetter = CTTypesetterCreateWithAttributedString(
            StyledText.attributedSlice(of: ns, range: 0..<ns.length, runs: styled.runs))
        let total = styled.length
        var refRanges: [Range<Int>] = []
        var offset = 0
        while offset < total {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, offset, 728))
            refRanges.append(offset..<(offset + count))
            offset += count
        }
        #expect(layout.lines.map(\.range) == refRanges)
        #expect(layout.lines.count == 2)
        #expect(layout.caretOffsets(forLineAt: 1).first == 0)
    }

    @Test func drawnBandsRedrawsShrunkWideTile() async {
        let style = await TextStyle.current()
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
        let palette = await TextPalette.resolveForTests
        let drawn = DrawnBands.draw(l2, after: l1, palette: palette, scale: 2, colorSpace: RowLayer.colorSpace)
        let shrunkCol1Frame = CGRect(
            x: RowLayer.bandWidth, y: 0, width: b2.contentWidth - RowLayer.bandWidth, height: b2.frame.height)
        #expect(drawn.wideBands.contains { $0.frame == shrunkCol1Frame })
    }
}
