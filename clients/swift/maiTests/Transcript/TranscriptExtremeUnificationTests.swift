import CoreGraphics
import Foundation
import QuartzCore
import Synchronization
import Testing

#if os(iOS)
    import UIKit
#endif

@testable import mai

/// Tests and fuzzers for the unified one-row-per-block virtual text body
/// (`REDESIGN.md §7 R2`): giant prose, lists, quotes, user messages, thoughts,
/// and code blocks render as one row per block with no slicing seams, whole-
/// block triple-click, exact copy, arithmetic resize, and O(viewport) drawing.
nonisolated struct TranscriptExtremeUnificationTests {
    private func makeStyle() async -> TextStyle { await TextStyle.current() }
    private func makePalette() async -> TextPalette { await TextPalette.resolveForTests }

    @Test func oneRowPerBlockForAllMessageKindsEvenWhenGiant() async {
        let style = await makeStyle()
        let unit = "performance analysis across large documents "
        let oneMB = String(repeating: unit, count: 1_048_576 / unit.utf8.count)
        let list5k = (0..<5_000).map { "- Item \($0) with detail text" }.joined(separator: "\n")
        let listItem1MB = "- " + oneMB
        let quote500KB = String(repeating: "> Quoted line with **bold** and `code`.\n", count: 12_000)
        let user500KB = String(repeating: "Line of pasted log text for user bubble.\n", count: 12_000)
        let thought500KB = String(repeating: "Reasoning paragraph with details.\n\n", count: 14_000)

        let cases: [(TranscriptMessage.Kind, String, Int)] = [
            (.assistant, oneMB, 1),
            (.assistant, list5k, 1),
            (.assistant, listItem1MB, 1),
            (.assistant, quote500KB, 1),
            (.user, user500KB, 1),
            (.thought, thought500KB, 1),
        ]

        for (kind, source, expectedRows) in cases {
            let message = TranscriptMessage(kind: kind, turnID: "t", ref: "r")
            let blocks = MarkdownPlanner.blocks(from: source)
            let rows = message.rows(from: blocks)
            #expect(rows.count == expectedRows, "expected one row per block for \(kind), got \(rows.count)")
            let row = rows[0]
            let layout = RowLayoutBuilder.layout(
                RowLayoutRequest(
                    rowID: row.id, kind: row.kind,
                    key: RowLayoutKey(contentVersion: 0, width: 520, styleVersion: style.version),
                    style: style))
            let expectedUTF16 = RowSelectableText.utf16Length(for: row.kind)
            #expect(expectedUTF16 == layout.content.selectableLength)
            if kind == .user {
                if case .bubble = layout.content {} else {
                    Issue.record("expected single .bubble for giant user message")
                }
            }
            // Resizing re-runs only the arithmetic fit over PreparedText.
            var resizeReq = RowLayoutRequest(
                rowID: row.id, kind: row.kind,
                key: RowLayoutKey(contentVersion: 0, width: 380, styleVersion: style.version),
                style: style)
            resizeReq.previous = (row.kind, layout)
            let resized = RowLayoutBuilder.layout(resizeReq)
            #expect(resized.height >= layout.height)
        }
    }

    @MainActor @Test func tripleClickOnGiantSingleParagraphSelectsWholeBlock() {
        let unit = "lorem ipsum dolor sit amet "
        let giant = String(repeating: unit, count: 64_000 / unit.utf8.count)
        let rows = TranscriptMessage(kind: .assistant, turnID: "t", ref: "a")
            .rows(from: MarkdownPlanner.blocks(from: giant))
        #expect(rows.count == 1)
        let controller = TranscriptController(configuration: .testing)
        controller.setRows(rows)
        let para = controller.paragraphRange(around: TextPosition(rowID: rows[0].id, offset: 12_345))
        let expectedUTF16 = giant.trimmingCharacters(in: .whitespaces).utf16.count
        #expect(para?.anchor == TextPosition(rowID: rows[0].id, offset: 0))
        #expect(para?.focus == TextPosition(rowID: rows[0].id, offset: expectedUTF16))
    }

    @Test func streamingGiantParagraphMatchesSettledOneRowPerBlock() async {
        let style = await makeStyle()
        let worker = TranscriptStreamWorker()
        let unit = "streamed word sequence "
        let text = String(repeating: unit, count: 48_000 / unit.utf8.count)
        let result = await worker.run(
            TranscriptStreamWorker.Update(
                messageID: "t|a", text: text, isFinished: true, width: 520, style: style,
                codeColors: [:], isDark: false, drawing: nil))
        let settled = TranscriptMessage(kind: .assistant, turnID: "t", ref: "a").rows(from: result.blocks)
        #expect(settled.count == 1)
        #expect(result.metrics.count == 1)
        #expect(result.rows.count == 1)
        #expect(result.rows[0].kind == settled[0].kind)
    }

    @Test func unifiedCodeHandles50kLinesAnd1MBSingleHorizontalLineInOViewport() async {
        let style = await makeStyle()
        let palette = await makePalette()
        let verticalCode = (0..<50_000).map { "let line\($0) = compute(\($0)) // ok" }.joined(separator: "\n")
        let vertical = CodeLayout.make(code: verticalCode, language: "swift", colors: nil, width: 600, style: style)
        #expect(vertical.retainedBytes < 8_000_000)
        #expect(vertical.utf16Length == verticalCode.utf16.count)
        let allRects = vertical.selectionRects(for: 0..<vertical.utf16Length)
        #expect(allRects.count <= 5)
        #expect(!allRects.isEmpty)

        let midY = 25_000 * style.codeLineHeight
        let midRaster = BandRaster(
            content: .codeBody(vertical), palette: palette, drawsWideBody: true,
            rect: CGRect(x: 0, y: midY, width: 600, height: 512), scale: 2, colorSpace: RowLayer.colorSpace)
        #expect(BandRasterizer.bitmap(midRaster) != nil)

        let horizontalCode = String(repeating: #"{"k":"value","n":12345},"#, count: 1_048_576 / 24)
        let horizontal = CodeLayout.make(code: horizontalCode, language: "json", colors: nil, width: 600, style: style)
        #expect(horizontal.retainedBytes < 8_192)
        #expect(horizontal.utf16Length == horizontalCode.utf16.count)
        let farRaster = BandRaster(
            content: .codeBody(horizontal), palette: palette, drawsWideBody: true,
            rect: CGRect(x: 500_000, y: 0, width: 768, height: style.codeLineHeight), scale: 2,
            colorSpace: RowLayer.colorSpace)
        #expect(BandRasterizer.bitmap(farRaster) != nil)
        let probeOffset = 100_000
        let caret = horizontal.caretRect(for: probeOffset)
        #expect(caret != nil)
        if let caret {
            let hit = horizontal.offset(closestTo: CGPoint(x: caret.minX + 0.5, y: caret.midY))
            #expect(abs(hit - probeOffset) <= 1)
        }
    }

    @Test func bomUFEFFDoesNotDisableBiDiCheck() {
        #expect(!TextLayoutEngine.isBiDiCodeUnit(0xFEFF))
        #expect(TextLayoutEngine.isBiDiCodeUnit(0xFEFC))
    }

    @Test func codeRendersColorsAndInvalidatesDiffOnColorChange() async {
        let style = await makeStyle()
        let lines = (0..<600).map { "let value\($0) = compute(\($0))" }
        let code = lines.joined(separator: "\n")
        let plain = CodeLayout.make(code: code, language: "swift", colors: nil, width: 600, style: style)

        let keywordColor = TextColor.rgba(red: 0.7, green: 0.1, blue: 0.5, alpha: 1)
        let line10Start = plain.body.lines[10].range.lowerBound
        let run = CodeColors.Run(range: line10Start..<(line10Start + 3), color: keywordColor)
        let colored = CodeColors(code: code, runs: [run], isDark: false)
        let highlighted = CodeLayout.make(code: code, language: "swift", colors: colored, width: 600, style: style)

        #expect(highlighted.body.prepared.runs.contains { $0.style.color == keywordColor })
        #expect(plain.unchangedBodyHeight(comparedTo: highlighted) == 0)
        #expect(highlighted.unchangedBodyHeight(comparedTo: highlighted) == .infinity)
    }

    @MainActor @Test func positionVerticallyStepsInsideAndAcrossCode() {
        let style = TextStyle.current()
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
        controller.replaceRows(
            0..<0, with: rows, heights: Dictionary(uniqueKeysWithValues: layouts.map { ($0.rowID, $0.height) }))
        for layout in layouts { controller.storeLayout(layout) }

        let downIntoCode = controller.positionVertically(
            from: TextPosition(rowID: "p0", offset: 4), lineOffset: 1, columnX: 0)
        #expect(downIntoCode?.rowID == "c0")

        let startInCode = TextPosition(rowID: "c0", offset: 4)
        let fiveDown = controller.positionVertically(from: startInCode, lineOffset: 5, columnX: 0)
        #expect(fiveDown?.rowID == "c0")
        #expect((fiveDown?.offset ?? 0) > startInCode.offset)

        if let fiveDown {
            let backUp = controller.positionVertically(from: fiveDown, lineOffset: -5, columnX: 0)
            #expect(backUp?.rowID == "c0")
            #expect(abs((backUp?.offset ?? -1) - startInCode.offset) <= 1)
        }

        let nearEnd = TextPosition(rowID: "c0", offset: code.utf16.count - 2)
        let pastEnd = controller.positionVertically(from: nearEnd, lineOffset: 1, columnX: 0)
        #expect(pastEnd?.rowID == "p1")
    }

    @Test func codeHandlesNegativeClipCRLFBiDiAndBlankSelections() async {
        let style = await makeStyle()
        let palette = await makePalette()

        let crlfCode = (0..<500).map { "line_\($0)_ascii_payload" }.joined(separator: "\r\n")
        let crlfBlock = CodeLayout.make(code: crlfCode, language: nil, colors: nil, width: 520, style: style)
        #expect(crlfBlock.body.lines.allSatisfy { $0.fastASCIIByteRange != nil })
        let negRaster = BandRaster(
            content: .codeBody(crlfBlock),
            palette: palette, drawsWideBody: true,
            rect: CGRect(x: -500, y: 0, width: 100, height: 100), scale: 2, colorSpace: RowLayer.colorSpace)
        #expect(BandRasterizer.bitmap(negRaster) != nil)

        let mixedLines = (0..<500).map { i in i == 5 ? "prefix_ascii_مرحبا بالعالم" : "plain_\(i)" }
        let mixedBlock = CodeLayout.make(
            code: mixedLines.joined(separator: "\n"), language: nil, colors: nil, width: 520, style: style)
        #expect(mixedBlock.body.lines[5].fastASCIIByteRange == nil)
        let line5Range = mixedBlock.body.lines[5].range
        let rects = mixedBlock.selectionRects(for: line5Range)
        #expect(!rects.isEmpty)
        #expect(rects.allSatisfy { $0.width > 0 && $0.height > 0 })

        let blanks = String(repeating: "\n", count: 600)
        let blankBlock = CodeLayout.make(code: blanks, language: nil, colors: nil, width: 520, style: style)
        let blankRects = blankBlock.selectionRects(for: 0..<blankBlock.utf16Length)
        #expect(blankRects.contains { $0.height > 500 * style.codeLineHeight && $0.width > 0 })
    }

    @MainActor @Test func devExtremeThreadsCatalogBuildsBlankingStressThread() {
        let catalog = ChatSyntheticBenchmarkThread.devExtremeThreads()
        #expect(catalog.count == 12)
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
            #expect(scrollView.wideBlockPan != nil)

            let scroller = TranscriptWideBlockScroller()
            #expect(!scroller.isUserInteractionEnabled)
            #expect(scroller.subviews.first?.isUserInteractionEnabled == false)
        }
    #endif

    @Test(arguments: [0, 1]) func fuzzUnifiedVirtualTextInvariants(seed: UInt64) async {
        let style = await makeStyle()
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
                while md.utf8.count < 24_000 { md += rng.pick(tokens) }
            case 1:
                md = "- " + String(repeating: rng.pick(tokens), count: 2_600) + "\n"
                for i in 0..<120 { md += "- item \(i) \(rng.pick(tokens))\n" }
            case 2:
                for i in 0..<400 { md += "> quote line \(i) \(rng.pick(tokens))\n" }
            default:
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
