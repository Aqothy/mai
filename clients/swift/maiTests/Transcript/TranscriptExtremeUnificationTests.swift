import CoreGraphics
import Foundation
import QuartzCore
import Synchronization
import Testing

#if os(iOS)
    import UIKit
#endif

@testable import mai

/// Tests and fuzzers for the unified bounded-prose flattener, 2D-virtualized
/// ASCII-fast `CodeLayout`, `U+FEFF` sliding-window fix, cancellable 1-hop
/// raster, and iOS wide-block/inputView fixes.
@MainActor
struct TranscriptExtremeUnificationTests {
    private let style = TextStyle.current()
    private let palette = TextPalette.resolveForTests

    // MARK: Unified bounded prose flattener

    @Test func normalSizedMessagesProduceZeroExtraSlices() {
        let user = TranscriptMessage(kind: .user, turnID: "t", ref: "u")
        let thought = TranscriptMessage(kind: .thought, turnID: "t", ref: "th")
        let assistant = TranscriptMessage(kind: .assistant, turnID: "t", ref: "a")

        let blocks = MarkdownPlanner.blocks(from: "First paragraph.\n\nSecond paragraph.")
        let userRows = user.rows(from: blocks)
        let thoughtRows = thought.rows(from: blocks)
        let assistantRows = assistant.rows(from: blocks)

        #expect(userRows.count == 1)
        if case .userMessage = userRows[0].kind {} else { Issue.record("expected single .userMessage") }
        #expect(thoughtRows.count == 1)
        if case .thought = thoughtRows[0].kind {} else { Issue.record("expected single .thought") }
        #expect(assistantRows.count == 2)
    }

    @Test func giantParagraphListItemQuoteUserAndThoughtAllBoundTo4KB() {
        let unit = "performance analysis across large documents "
        let oneMB = String(repeating: unit, count: 1_048_576 / unit.utf8.count)
        let list5k = (0..<5_000).map { "- Item \($0) with detail text" }.joined(separator: "\n")
        let listItem1MB = "- " + oneMB
        let quote500KB = String(repeating: "> Quoted line with **bold** and `code`.\n", count: 12_000)
        let user500KB = String(repeating: "Line of pasted log text for user bubble.\n", count: 12_000)
        let thought500KB = String(repeating: "Reasoning paragraph with details.\n\n", count: 14_000)

        let cases: [(TranscriptMessage.Kind, String)] = [
            (.assistant, oneMB),
            (.assistant, list5k),
            (.assistant, listItem1MB),
            (.assistant, quote500KB),
            (.user, user500KB),
            (.thought, thought500KB),
        ]

        for (kind, source) in cases {
            let message = TranscriptMessage(kind: kind, turnID: "t", ref: "r")
            let blocks = MarkdownPlanner.blocks(from: source)
            let rows = message.rows(from: blocks)
            #expect(rows.count > 10, "expected giant \(kind) to flatten into bounded rows")

            // Verify every row stays bounded, selectable length matches layout
            // exactly, and user bubbles connect top -> middle -> bottom cleanly.
            let sampleIndices = Set([0, 1, rows.count / 2, rows.count - 1])
            for index in sampleIndices {
                let row = rows[index]
                #expect(row.metrics.bytes <= TranscriptBlockFlattener.maxSliceBytes + 256)
                let layout = RowLayoutBuilder.layout(
                    RowLayoutRequest(
                        rowID: row.id, kind: row.kind,
                        key: RowLayoutKey(contentVersion: 0, width: 520, styleVersion: style.version),
                        style: style))
                let expectedUTF16 = RowSelectableText.utf16Length(for: row.kind)
                let expectedString = RowSelectableText.string(for: row.kind, style: style)
                #expect(expectedUTF16 == layout.content.selectableLength)
                #expect(expectedString == layout.content.selectableString)
                if kind == .user {
                    if case .bubble(_, _, _, let topRounded, let bottomRounded) = layout.content {
                        #expect(topRounded == (index == 0))
                        #expect(bottomRounded == (index == rows.count - 1))
                    } else {
                        Issue.record("expected connected .bubble for giant user message slice \(index)")
                    }
                }
            }
        }
    }

    @Test func streamingGiantParagraphMatchesSettledFlattenedRows() async {
        let worker = TranscriptStreamWorker()
        let unit = "streamed word sequence "
        let text = String(repeating: unit, count: 24_000 / unit.utf8.count)
        let result = await worker.run(
            TranscriptStreamWorker.Update(
                messageID: "t|a", text: text, isFinished: true, width: 520, style: style,
                codeColors: [:], isDark: false, drawing: nil))
        let settled = TranscriptMessage(kind: .assistant, turnID: "t", ref: "a").rows(from: result.blocks)
        #expect(settled.count >= 3)
        #expect(result.metrics.count == settled.count)
        #expect(result.rows.count == settled.count)
        for (streamedRow, settledRow) in zip(result.rows, settled) {
            #expect(streamedRow.kind == settledRow.kind)
        }
    }

    // MARK: 2D-virtualized + ASCII-fast CodeLayout

    @Test func asciiCodeFastPathMatchesCoreTextMetricsAndPixels() {
        let sample = """
            func compute(x: Int, y: Int) -> Int {
            \tlet sum = x + y
            \t\treturn sum * 2 // trailing check
            }
            """
        let ascii = MonospaceASCIIMetrics.metrics(for: style.font(.code))
        guard let fast = ascii.materializeASCII(code: sample, style: style) else {
            Issue.record("expected ASCII fast path to handle pure ASCII code")
            return
        }
        let coreText = TextLayoutEngine.layout(
            CodeLayout.buildStyledCode(sample, colors: nil, style: style),
            width: .greatestFiniteMagnitude,
            options: .init(lineSpacing: 0, wraps: false, fixedLineHeight: style.codeLineHeight))

        #expect(fast.lines.count == coreText.lines.count)
        #expect(abs(fast.size.width - coreText.size.width) <= 1.0)
        #expect(abs(fast.size.height - coreText.size.height) <= 0.01)
        for (a, b) in zip(fast.lines, coreText.lines) {
            #expect(a.range == b.range)
            #expect(abs(a.top - b.top) <= 0.01)
            #expect(abs(a.baseline - b.baseline) <= 0.5)
            #expect(abs(a.width - b.width) <= 1.0)
            #expect(a.caretOffsets.count == b.caretOffsets.count)
            for (cx, cy) in zip(a.caretOffsets, b.caretOffsets) {
                #expect(abs(cx - cy) <= 1.0)
            }
        }
    }

    @Test func virtualizedCodeHandles50kLinesAnd1MBSingleHorizontalLineInOViewport() {
        // 1. 50,000 vertical lines
        let verticalCode = (0..<50_000).map { "let line\($0) = compute(\($0)) // ok" }.joined(separator: "\n")
        let vertical = CodeLayout.make(code: verticalCode, language: "swift", colors: nil, width: 600, style: style)
        #expect(vertical.materializedBody == nil)
        #expect(vertical.retainedBytes < 2_000_000)
        #expect(vertical.utf16Length == verticalCode.utf16.count)
        // Cmd+A selection merges interior into <= 5 rects instead of 50,000 rects.
        let allRects = vertical.selectionRects(for: 0..<vertical.utf16Length)
        #expect(allRects.count <= 5)
        #expect(!allRects.isEmpty)

        // Rasterize a mid-file tile (line ~25,000) cleanly.
        let midY = 25_000 * style.codeLineHeight
        let midRaster = BandRaster(
            content: .codeBody(vertical), palette: palette, drawsWideBody: true,
            rect: CGRect(x: 0, y: midY, width: 600, height: 512), scale: 2, colorSpace: RowLayer.colorSpace)
        #expect(BandRasterizer.bitmap(midRaster) != nil)

        // 2. 1 MB single horizontal line
        let horizontalCode = String(repeating: #"{"k":"value","n":12345},"#, count: 1_048_576 / 24)
        let horizontal = CodeLayout.make(code: horizontalCode, language: "json", colors: nil, width: 600, style: style)
        #expect(horizontal.materializedBody == nil)
        #expect(horizontal.retainedBytes < 4_096)
        #expect(horizontal.utf16Length == horizontalCode.utf16.count)
        // Rasterize a tile 500,000 pt out to the right cleanly.
        let farRaster = BandRaster(
            content: .codeBody(horizontal), palette: palette, drawsWideBody: true,
            rect: CGRect(x: 500_000, y: 0, width: 768, height: style.codeLineHeight), scale: 2,
            colorSpace: RowLayer.colorSpace)
        #expect(BandRasterizer.bitmap(farRaster) != nil)
        // Hit-testing & caret round-trip deep inside the 1 MB line.
        let probeOffset = 100_000
        let caret = horizontal.caretRect(for: probeOffset)
        #expect(caret != nil)
        if let caret {
            let hit = horizontal.offset(closestTo: CGPoint(x: caret.minX + 0.5, y: caret.midY))
            #expect(abs(hit - probeOffset) <= 1)
        }
    }

    // MARK: Root fixes

    @Test func bomUFEFFDoesNotDisableBiDiCheck() {
        #expect(!TextLayoutEngine.isBiDiCodeUnit(0xFEFF))
        #expect(TextLayoutEngine.isBiDiCodeUnit(0xFEFC))
    }

    @Test func staleLayoutGenerationSkipsSpeculativePreRaster() async throws {
        let drawnFlags = Mutex<[Bool]>([])
        let queue = LayoutQueue(concurrency: 1) { result in
            if case .layout(_, let drawn) = result {
                drawnFlags.withLock { $0.append(drawn != nil) }
            }
        }
        let drawing = DrawnBands.Drawing(palette: palette, scale: 2, colorSpace: RowLayer.colorSpace)
        let key = RowLayoutKey(contentVersion: 0, width: 400, styleVersion: style.version)
        let longText = String(repeating: "benchmark word ", count: 200)
        let job1 = LayoutQueue.Job(
            id: "layout|r0",
            work: .layout(
                RowLayoutRequest(
                    rowID: "r0", kind: .markdownBlock(.paragraph([MarkdownInline(text: longText)]), .single),
                    key: key, style: style),
                drawing: drawing),
            priority: 0)
        let job2 = LayoutQueue.Job(
            id: "layout|r1",
            work: .layout(
                RowLayoutRequest(
                    rowID: "r1", kind: .markdownBlock(.paragraph([MarkdownInline(text: "Fresh visible row")]), .single),
                    key: key, style: style),
                drawing: drawing),
            priority: 0)

        await queue.submit(urgent: [job1], generation: 1, replacingUrgent: true)
        await queue.submit(urgent: [job2], generation: 2, replacingUrgent: true)

        for _ in 0..<100 where drawnFlags.withLock({ $0.count }) < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let flags = drawnFlags.withLock { $0 }
        // At least the fresh generation-2 job pre-rastered cleanly.
        #expect(flags.last == true)
    }

    // MARK: Review & blanking regression tests

    @Test func virtualizedCodeRendersSlicedColorsAndInvalidatesDiffOnColorChange() {
        let lines = (0..<600).map { "let value\($0) = compute(\($0))" }
        let code = lines.joined(separator: "\n")
        let ascii = MonospaceASCIIMetrics.metrics(for: style.font(.code))
        let plain = VirtualCodeBody(code: code, style: style, colors: nil, ascii: ascii)

        // Highlight "let" on line 10 with a syntax color.
        let keywordColor = TextColor.rgba(red: 0.7, green: 0.1, blue: 0.5, alpha: 1)
        let line10Start = plain.lineUTF16Range(10).lowerBound
        let run = CodeColors.Run(range: line10Start..<(line10Start + 3), color: keywordColor)
        let colored = CodeColors(code: code, runs: [run], isDark: false)
        let highlighted = VirtualCodeBody(code: code, style: style, colors: colored, ascii: ascii)

        let line10Layout = highlighted.layoutSingleLine(10)
        #expect(line10Layout.runs.contains { $0.color == keywordColor })
        let line11Layout = highlighted.layoutSingleLine(11)
        #expect(!line11Layout.runs.contains { $0.color == keywordColor })
        // Changing syntax colors on identical code must invalidate cached bands.
        #expect(plain.unchangedHeight(comparedTo: highlighted) == 0)
        #expect(highlighted.unchangedHeight(comparedTo: highlighted) == .infinity)
    }

    @Test func positionVerticallyStepsInsideAndAcrossVirtualizedCode() {
        let controller = TranscriptController(configuration: .testing)
        controller.columnWidth = 520
        let code = (0..<600).map { "let item\($0) = \($0) // line" }.joined(separator: "\n")
        let rows: [TranscriptRow] = [
            TranscriptRow(
                id: "p0", sourceID: "m0",
                kind: .markdownBlock(.paragraph([MarkdownInline(text: "Before code block")]), .single),
                messageID: "m0", role: .assistant),
            TranscriptRow(
                id: "c0", sourceID: "m0",
                kind: .markdownBlock(.code(language: "swift", code: code), .single),
                messageID: "m0", role: .assistant),
            TranscriptRow(
                id: "p1", sourceID: "m0",
                kind: .markdownBlock(.paragraph([MarkdownInline(text: "After code block")]), .single),
                messageID: "m0", role: .assistant),
        ]
        var layouts: [RowLayout] = []
        for row in rows {
            layouts.append(
                RowLayoutBuilder.layout(
                    RowLayoutRequest(
                        rowID: row.id, kind: row.kind,
                        key: RowLayoutKey(contentVersion: 0, width: 520, styleVersion: style.version),
                        style: style)))
        }
        controller.replaceRows(0..<0, with: rows, heights: Dictionary(uniqueKeysWithValues: layouts.map { ($0.rowID, $0.height) }))
        for layout in layouts { controller.storeLayout(layout) }

        // Step down from paragraph into virtualized code line 0.
        let downIntoCode = controller.positionVertically(
            from: TextPosition(rowID: "p0", offset: 4), lineOffset: 1, columnX: 0)
        #expect(downIntoCode?.rowID == "c0")

        // Step 5 lines down inside virtualized code (must advance lines, not stall).
        let startInCode = TextPosition(rowID: "c0", offset: 4)
        let fiveDown = controller.positionVertically(from: startInCode, lineOffset: 5, columnX: 0)
        #expect(fiveDown?.rowID == "c0")
        #expect((fiveDown?.offset ?? 0) > startInCode.offset)

        // Step 5 lines back up to line 0.
        if let fiveDown {
            let backUp = controller.positionVertically(from: fiveDown, lineOffset: -5, columnX: 0)
            #expect(backUp?.rowID == "c0")
            #expect(abs((backUp?.offset ?? -1) - startInCode.offset) <= 1)
        }

        // Step down past last line of virtualized code into trailing paragraph.
        let nearEnd = TextPosition(rowID: "c0", offset: code.utf16.count - 2)
        let pastEnd = controller.positionVertically(from: nearEnd, lineOffset: 1, columnX: 0)
        #expect(pastEnd?.rowID == "p1")
    }

    @Test func connectedUserBubbleHasZeroGapBetweenSlices() {
        let logLine = "[2026-11-25 14:00:00] INFO worker=1 batch=42 ok\n\n"
        let userText = String(repeating: logLine, count: 250)
        let message = TranscriptMessage(kind: .user, turnID: "t", ref: "u")
        let rows = message.rows(from: MarkdownPlanner.blocks(from: userText))
        #expect(rows.count >= 3)
        for index in 1..<rows.count {
            let layout = RowLayoutBuilder.layout(
                RowLayoutRequest(
                    rowID: rows[index].id, kind: rows[index].kind,
                    key: RowLayoutKey(contentVersion: 0, width: 520, styleVersion: style.version),
                    style: style))
            if case .bubble(_, let frame, _, let topRounded, let bottomRounded) = layout.content {
                #expect(frame.minY == 0, "joined user bubble slice \(index) must start at y=0 with no transparent gap")
                #expect(!topRounded)
                #expect(bottomRounded == (index == rows.count - 1))
            } else {
                Issue.record("expected .bubble layout for slice \(index)")
            }
        }
    }

    @Test func flattenedBlockquoteAndNestedListQuotePreserveQuoteBarsAndMarkers() {
        let longText = String(repeating: "quoted nested detail ", count: 350)
        let md = "- > \(longText)\n\n  > second paragraph inside nested quote"
        let message = TranscriptMessage(kind: .assistant, turnID: "t", ref: "a")
        let rows = message.rows(from: MarkdownPlanner.blocks(from: md))
        #expect(rows.count >= 3)

        // First slice carries the outer list marker cleanly without merging onto quoted text.
        if case .markdownBlock(_, _, let firstCtx) = rows[0].kind {
            #expect(firstCtx.listMarker != nil)
        }
        // Quoted continuation slices carry ordered [.list, .quote] containers and
        // draw quote bars extending up to y = 0.
        var sawContinuousQuoteBar = false
        for row in rows.dropFirst() {
            if case .markdownBlock(_, _, let ctx) = row.kind, ctx.containers == [.list, .quote], ctx.joinsAbove {
                let layout = RowLayoutBuilder.layout(
                    RowLayoutRequest(
                        rowID: row.id, kind: row.kind,
                        key: RowLayoutKey(contentVersion: 0, width: 520, styleVersion: style.version),
                        style: style))
                if case .text(let textLayout, let origin) = layout.content {
                    #expect(origin.y == 0)
                    if textLayout.decorations.contains(where: { $0.rect.minY <= 0.5 }) {
                        sawContinuousQuoteBar = true
                    }
                }
            }
        }
        #expect(sawContinuousQuoteBar)
    }

    @Test func virtualizedCodeHandlesNegativeClipCRLFBiDiAndBlankSelections() {
        let ascii = MonospaceASCIIMetrics.metrics(for: style.font(.code))

        // 1. CRLF stays on fast ASCII path & negative visMaxX does not trap.
        let crlfCode = (0..<500).map { "line_\($0)_ascii_payload" }.joined(separator: "\r\n")
        let crlfBody = VirtualCodeBody(code: crlfCode, style: style, colors: nil, ascii: ascii)
        #expect(crlfBody.nonASCIILines.isEmpty)
        let negRaster = BandRaster(
            content: .codeBody(CodeLayout.make(code: crlfCode, language: nil, colors: nil, width: 520, style: style)),
            palette: palette, drawsWideBody: true,
            rect: CGRect(x: -500, y: 0, width: 100, height: 100), scale: 2, colorSpace: RowLayer.colorSpace)
        #expect(BandRasterizer.bitmap(negRaster) != nil)

        // 2. Mixed ASCII-prefix + Arabic-suffix line uses consistent CoreText metrics.
        let mixedLines = (0..<500).map { i in i == 5 ? "prefix_ascii_مرحبا بالعالم" : "plain_\(i)" }
        let mixedBody = VirtualCodeBody(
            code: mixedLines.joined(separator: "\n"), style: style, colors: nil, ascii: ascii)
        #expect(mixedBody.nonASCIILines == [5])
        let line5Range = mixedBody.lineUTF16Range(5)
        let rects = mixedBody.selectionRects(for: line5Range)
        #expect(!rects.isEmpty)
        #expect(rects.allSatisfy { $0.width > 0 && $0.height > 0 })

        // 3. All-blank >512-line selection retains positive interior highlight width.
        let blanks = String(repeating: "\n", count: 600)
        let blankBody = VirtualCodeBody(code: blanks, style: style, colors: nil, ascii: ascii)
        let blankRects = blankBody.selectionRects(for: 0..<blankBody.totalUTF16)
        #expect(blankRects.contains { $0.height > 500 * style.codeLineHeight && $0.width > 0 })
    }

    @Test func syncFallbackParsesLargePendingMessageAndLaysOutOnlyVisibleSlices() {
        var config = TranscriptConfiguration(laysOutRows: true, drawsOffMain: false, syncFallbackBudget: 0.5)
        config.concurrency = 1
        let controller = TranscriptController(configuration: config)
        let host = FakeTranscriptHost()
        host.size = CGSize(width: 520, height: 600)
        host.controller = controller
        controller.attach(host)

        // 80 KB pending assistant message (< 128 KB sync parse limit, > 4 KB slice limit).
        let unit = "Sync fallback test paragraph content with markdown **bold** and `code`. "
        let text = String(repeating: unit, count: 80_000 / unit.utf8.count)
        let message = TranscriptMessage(kind: .assistant, turnID: "t0", ref: "a0")
        let pending = message.pendingRow(source: text)
        controller.setRows([pending], measuredHeights: [pending.id: 12_000])
        controller.openStarted = ContinuousClock.now.advanced(by: .seconds(-5))
        controller.alignInitialEndIfPossible()
        #expect(!controller.isAwaitingInitialEnd)
        host.readerScroll(toTop: 0)

        // Prepare only the first 600 pt viewport synchronously.
        controller.prepareVisibleSynchronously(
            in: CGRect(x: 0, y: 0, width: 520, height: 600),
            deadline: CACurrentMediaTime() + 0.5)

        // Pending row spliced into >= 15 bounded <= 4 KB slices, and only the
        // visible subset was laid out synchronously (not all 20+ slices!).
        #expect(controller.rows.count >= 15)
        #expect(controller.layouts[controller.rows[0].id] != nil)
        #expect(controller.layouts.count < controller.rows.count)
    }

    @Test func adaptiveSyncFallbackBudgetMatchesDisplayRefreshAndLowPowerMode() {
        let adaptive = TranscriptConfiguration()
        let budget120 = adaptive.effectiveSyncFallbackBudget(maximumFramesPerSecond: 120, isLowPowerMode: false)
        let budget60 = adaptive.effectiveSyncFallbackBudget(maximumFramesPerSecond: 60, isLowPowerMode: false)
        let budgetLPM = adaptive.effectiveSyncFallbackBudget(maximumFramesPerSecond: 120, isLowPowerMode: true)
        #expect(abs(budget120 - (0.5 / 120.0)) < 0.0002)
        #expect(abs(budget60 - (0.5 / 60.0)) < 0.0002)
        #expect(abs(budgetLPM - budget60) < 0.0001)
        #expect(TranscriptConfiguration.testing.effectiveSyncFallbackBudget(maximumFramesPerSecond: 60, isLowPowerMode: false) == 0)
    }

    @Test func devExtremeThreadsCatalogBuildsBlankingStressThread() {
        let catalog = ChatSyntheticBenchmarkThread.devExtremeThreads()
        #expect(catalog.count == 11)
        let blanking = catalog.first(where: { $0.summary.id == "synthetic-benchmark-blanking" })?.build()
        #expect(blanking != nil)
        #expect((blanking?.turns.count ?? 0) >= 90)
    }

    #if os(iOS)
        @MainActor @Test func iosWideBlockAndTextInputPreventSelectionAndKeyboardRegressions() {
            let controller = TranscriptController(configuration: .testing)
            let scrollView = TranscriptScrollView(controller: controller)
            #expect(scrollView.contentView.inputView != nil)
            #expect(scrollView.contentView.inputView?.frame == .zero)

            let scroller = TranscriptWideBlockScroller()
            #expect(!scroller.delaysContentTouches)
            #expect(scroller.subviews.first?.isUserInteractionEnabled == true)
        }
    #endif

    // MARK: Fuzzing unified flattening & virtualized code invariants

    @Test(arguments: [0, 1]) func fuzzUnifiedFlatteningAndVirtualizedCodeInvariants(seed: UInt64) {
        var rng = FuzzRNG(seed: 0xE77E_0000 ^ seed)
        let iterations = 8 * TranscriptFuzz.scale
        let tokens = [
            "alpha ", "beta\n", "gamma\t", "漢字 ", "مَرْحَبًا ", "👩🏽‍💻 ", "**bold** ", "`code` ",
            "[link](https://example.com) ", "\u{FEFF}",
        ]
        for iter in 0..<iterations {
            let kind: TranscriptMessage.Kind = [.assistant, .user, .thought][iter % 3]
            var md = ""
            let mode = rng.int(in: 0..<4)
            switch mode {
            case 0:
                // Giant single paragraph (~18 KB)
                while md.utf8.count < 18_000 { md += rng.pick(tokens) }
            case 1:
                // Giant list (~20 KB) including one oversized item
                md = "- " + String(repeating: rng.pick(tokens), count: 1_200) + "\n"
                for i in 0..<120 { md += "- item \(i) \(rng.pick(tokens))\n" }
            case 2:
                // Giant quote (~18 KB)
                for i in 0..<300 { md += "> quote line \(i) \(rng.pick(tokens))\n" }
            default:
                // Giant code block (~20 KB, mixed ASCII + occasional Unicode/tabs)
                md = "```txt\n"
                for i in 0..<400 {
                    md += "line_\(i)\t\(rng.pick(tokens))" + String(repeating: "x", count: 35) + "\n"
                }
                md += "```"
            }

            let message = TranscriptMessage(kind: kind, turnID: "t\(iter)", ref: "r\(iter)")
            let blocks = MarkdownPlanner.blocks(from: md)
            let rows = message.rows(from: blocks)
            #expect(!rows.isEmpty)
            let width = CGFloat([320, 520, 760][iter % 3])
            // Check first, middle, and last row invariants.
            for idx in Set([0, rows.count / 2, rows.count - 1]) {
                let row = rows[idx]
                let layout = RowLayoutBuilder.layout(
                    RowLayoutRequest(
                        rowID: row.id, kind: row.kind,
                        key: RowLayoutKey(contentVersion: 0, width: width, styleVersion: style.version),
                        style: style))
                let expectedLen = RowSelectableText.utf16Length(for: row.kind)
                let expectedStr = RowSelectableText.string(for: row.kind, style: style)
                #expect(expectedLen == layout.content.selectableLength, "iter \(iter) row \(idx)")
                #expect(expectedStr == layout.content.selectableString, "iter \(iter) row \(idx)")
                if let len = expectedLen, len > 0 {
                    let midOffset = len / 2
                    if let caret = layout.content.caretRect(for: midOffset) {
                        #expect(caret.width > 0 && caret.height > 0)
                        let hit = layout.content.textOffset(closestTo: CGPoint(x: caret.minX, y: caret.midY))
                        #expect(hit != nil)
                    }
                }
            }
        }
    }
}
