import CoreGraphics
import CoreText
import Foundation
import QuartzCore
import Testing

#if os(macOS)
    import AppKit
#endif

@testable import mai

/// Bitmaps land in order: a band takes any bitmap newer than the one it
/// shows, and a streamed block shows its new text in the same placement as
/// its new size (PLAN 6.5).
@MainActor
struct TranscriptStreamOrderTests {
    private let style = TextStyle.current()

    /// A streamed block's layout at its `version`th update.
    private func paragraph(_ text: String, version: Int) -> RowLayout {
        let kind = TranscriptRowKind.markdownBlock(
            .paragraph([MarkdownInline(text: text)]), .init(isFirst: true, isLast: true))
        return RowLayoutBuilder.layout(
            RowLayoutRequest(
                rowID: "row", kind: kind,
                key: RowLayoutKey(contentVersion: version, width: 400, styleVersion: style.version), style: style))
    }

    private func mounted(_ layout: RowLayout, palette: TextPalette) -> RowLayer {
        let layer = RowLayer()
        layer.frame = CGRect(x: 0, y: 0, width: layout.key.width, height: layout.height)
        layer.show(rowID: "row", layout: layout, palette: palette, drawsWideBody: true, scale: 2)
        layer.drawBands(in: layer.bounds, visible: layer.bounds, offMain: false)
        return layer
    }

    @Test func aStreamedBlockShowsItsNewTextWithItsNewSize() {
        let palette = TextPalette.resolveForTests
        let before = paragraph("The first words", version: 0)
        let after = paragraph(String(repeating: "the first words and many more after them ", count: 8), version: 1)
        let layer = mounted(before, palette: palette)
        let drawn = DrawnBands.draw(
            after, after: before, palette: palette, scale: 2, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        #expect(!drawn.bands.isEmpty)
        layer.frame.size.height = after.height
        layer.show(rowID: "row", layout: after, palette: palette, drawsWideBody: true, scale: 2, drawn: drawn)
        let bands = layer.sublayers?.compactMap { $0 as? RowBandLayer } ?? []
        #expect(!bands.isEmpty)
        #expect(bands.allSatisfy { $0.isCurrent && $0.contents != nil })
        let expectedBounds = after.content.paintedBounds(drawsWideBody: true, rowWidth: 400, rowHeight: after.height)
        #expect(bands.map(\.frame) == RowLayer.bandFrames(in: expectedBounds))
    }

    @Test func bandsDrawnWithAnotherPaletteAreNotShown() {
        let before = paragraph("The first words", version: 0)
        let after = paragraph("The first words and more", version: 1)
        let layer = mounted(before, palette: TextPalette.resolveForTests)
        let drawn = DrawnBands.draw(
            after, after: before, palette: TextPalette.resolveForTests, scale: 2,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        layer.show(
            rowID: "row", layout: after, palette: TextPalette.resolveForTests, drawsWideBody: true, scale: 2,
            drawn: drawn)
        let bands = layer.sublayers?.compactMap { $0 as? RowBandLayer } ?? []
        #expect(bands.contains { !$0.isCurrent })
    }

    @Test func aBandTakesAnyBitmapNewerThanItShowsButNotOlder() {
        let band = RowBandLayer()
        band.invalidate()
        let first = band.generation
        band.invalidate()
        band.invalidate()
        let current = band.generation
        // Outdated but newer than what it shows: shows, so a band a live
        // resize changes every frame still moves.
        #expect(band.wants(first))
        band.show(nil, generation: first + 1)
        #expect(!band.wants(first))
        #expect(band.wants(current))
        #expect(!band.isCurrent)
    }

    @Test func aReleasedBandTakesNoBitmapMadeBeforeTheRelease() {
        let band = RowBandLayer()
        band.invalidate()
        let before = band.generation
        band.release()
        #expect(!band.wants(before))
        band.invalidate()
        #expect(band.wants(band.generation))
    }

    /// A row that paints nothing (a turn's action buttons) holds no bitmap,
    /// and a code block wider than its row paints only its header: the body
    /// is drawn in the block's own scroller.
    @Test func rowsHoldBitmapsOnlyForWhatTheyPaint() {
        let palette = TextPalette.resolveForTests
        let key = RowLayoutKey(contentVersion: 0, width: 300, styleVersion: style.version)
        let actions = RowLayoutBuilder.layout(
            RowLayoutRequest(rowID: "a", kind: .turnActions(turnID: "t", hasReply: true), key: key, style: style))
        let actionsLayer = mounted(actions, palette: palette)
        let actionBands = actionsLayer.sublayers?.compactMap { $0 as? RowBandLayer } ?? []
        #expect(actionBands.isEmpty)

        let wide = String(repeating: "x", count: 200)
        let code = TranscriptRowKind.markdownBlock(
            .code(language: "go", code: Array(repeating: wide, count: 60).joined(separator: "\n")),
            .init(isFirst: true, isLast: true))
        let codeLayout = RowLayoutBuilder.layout(RowLayoutRequest(rowID: "c", kind: code, key: key, style: style))
        #expect(codeLayout.content.wideBody != nil)
        #expect(codeLayout.height > RowLayer.bandHeight)
        let codeLayer = RowLayer()
        codeLayer.frame = CGRect(x: 0, y: 0, width: 300, height: codeLayout.height)
        codeLayer.show(rowID: "c", layout: codeLayout, palette: palette, drawsWideBody: false, scale: 2)
        codeLayer.drawBands(in: codeLayer.bounds, visible: codeLayer.bounds, offMain: false)
        let codeBands = codeLayer.sublayers?.compactMap { $0 as? RowBandLayer } ?? []
        #expect(codeBands.count == 1)
        #expect(codeBands.allSatisfy { $0.frame.maxY <= RowLayer.bandHeight })
    }

    /// A row draws in its window's color space: moved to a window with
    /// another one, its bands draw again, and bitmaps drawn in another space
    /// are not shown.
    @Test func aRowDrawsInItsWindowsColorSpace() {
        let palette = TextPalette.resolveForTests
        let before = paragraph("Colors", version: 0)
        let layer = mounted(before, palette: palette)
        let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
        layer.show(rowID: "row", layout: before, palette: palette, drawsWideBody: true, scale: 2, colorSpace: displayP3)
        let bands = layer.sublayers?.compactMap { $0 as? RowBandLayer } ?? []
        #expect(!bands.isEmpty)
        #expect(bands.allSatisfy { !$0.isCurrent })

        let after = paragraph("Colors and more", version: 1)
        let drawn = DrawnBands.draw(
            after, after: before, palette: palette, scale: 2, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        layer.show(
            rowID: "row", layout: after, palette: palette, drawsWideBody: true, scale: 2, colorSpace: displayP3,
            drawn: drawn)
        #expect(bands.allSatisfy { $0.contents == nil || !$0.isCurrent })
    }

    #if os(macOS)
        /// Increase Contrast keeps the light or dark appearance but changes
        /// its colors: a mounted row draws again in the new palette.
        @Test func increasedContrastRedrawsAMountedRow() {
            let normal = TextPalette.resolve(for: NSAppearance(named: .aqua)!)
            let contrast = TextPalette.resolve(for: NSAppearance(named: .accessibilityHighContrastAqua)!)
            #expect(normal.isDark == contrast.isDark)
            let layout = paragraph("Contrast", version: 0)
            let layer = mounted(layout, palette: normal)
            layer.show(rowID: "row", layout: layout, palette: contrast, drawsWideBody: true, scale: 2)
            let bands = layer.sublayers?.compactMap { $0 as? RowBandLayer } ?? []
            #expect(!bands.isEmpty)
            #expect(bands.allSatisfy { !$0.isCurrent })
        }
    #endif

    /// A wide streaming code block pre-draws its changed body bands with its
    /// layout, so the body shows its new text with its new size.
    @Test func wideCodePreDrawsItsChangedBodyBands() {
        let palette = TextPalette.resolveForTests
        let longLine = String(repeating: "x", count: 200)
        let kind1 = TranscriptRowKind.markdownBlock(
            .code(language: "go", code: longLine), .init(isFirst: true, isLast: true))
        let kind2 = TranscriptRowKind.markdownBlock(
            .code(language: "go", code: longLine + "\n" + longLine), .init(isFirst: true, isLast: true))
        let key1 = RowLayoutKey(contentVersion: 0, width: 300, styleVersion: style.version)
        let key2 = RowLayoutKey(contentVersion: 1, width: 300, styleVersion: style.version)
        let l1 = RowLayoutBuilder.layout(RowLayoutRequest(rowID: "c", kind: kind1, key: key1, style: style))
        let l2 = RowLayoutBuilder.layout(RowLayoutRequest(rowID: "c", kind: kind2, key: key2, style: style))
        #expect(l2.content.wideBody != nil)
        let drawn = DrawnBands.draw(
            l2, after: l1, palette: palette, scale: 2, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        #expect(!drawn.wideBands.isEmpty)
    }

    /// A text size change while a reply streams lays its blocks out again:
    /// the worker used to keep the rows it had laid out at the old size.
    @Test func aTextSizeChangeMidStreamLaysTheReplyOutAgain() async {
        let worker = TranscriptStreamWorker()
        let bigger = TextStyle(version: style.version + 1) { role in
            CTFontCreateCopyWithAttributes(style.font(role).font, CTFontGetSize(style.font(role).font) + 4, nil, nil)
        }
        func update(_ style: TextStyle) -> TranscriptStreamWorker.Update {
            .init(
                messageID: "m", text: "One\n\nTwo\n\nThr", isFinished: false, width: 400, style: style, codeColors: [:],
                isDark: nil, drawing: nil)
        }
        _ = await worker.run(update(style))
        let result = await worker.run(update(bigger))
        #expect(result.rows.count == 3)
        #expect(result.styleVersion == bigger.version)
    }

    private final class MountRecorder: TranscriptRowMounterDelegate {
        var wideOrigins: [String: CGPoint] = [:]
        var accessoryOrigins: [String: CGPoint] = [:]
        func showWideBlock(
            rowID: String, body: WideBlockBody, key: RowLayoutKey, origin: CGPoint, drawn: CGRect,
            visible: CGRect, streamed: DrawnBands?
        ) { wideOrigins[rowID] = origin }
        func removeWideBlock(rowID: String) { wideOrigins[rowID] = nil }
        func showWideBlockSelection(rowID: String, range: Range<Int>?, color: CGColor) {}
        func showAccessories(rowID: String, accessories: [RowAccessory], origin: CGPoint) {
            accessoryOrigins[rowID] = origin
        }
        func removeAccessories(rowID: String) { accessoryOrigins[rowID] = nil }
    }

    /// A row kept just outside the drawn window moves its wide block's
    /// scroller and its buttons with it when a row above changes height; they
    /// stayed where it was and could show over other rows.
    @Test func aKeptRowsWideBlockAndButtonsFollowIt() {
        var configuration = TranscriptConfiguration(laysOutRows: true)
        configuration.concurrency = 1
        let controller = TranscriptController(configuration: configuration)
        let host = FakeTranscriptHost()
        host.controller = controller
        controller.attach(host)
        let long = String(repeating: "wide ", count: 60)
        controller.setRows(
            [
                TranscriptRow(id: "spacer", kind: .notice(title: "spacer", text: nil)),
                TranscriptRow(
                    id: "m#0", sourceID: "m",
                    kind: .markdownBlock(.code(language: "go", code: long), .init(isFirst: true, isLast: true)),
                    messageID: "m", role: .assistant),
                TranscriptRow(id: "tail", kind: .notice(title: "tail", text: nil)),
            ], measuredHeights: ["spacer": 400, "tail": 3000])
        controller.storeLayout(RowLayoutBuilder.layout(controller.request(controller.rows[0])))
        let code = RowLayoutBuilder.layout(controller.request(controller.rows[1]))
        controller.storeLayout(code)
        controller.setHeights(["spacer": 400, "m#0": code.height, "tail": 3000])
        let mounter = TranscriptRowMounter(container: CALayer())
        let recorder = MountRecorder()
        mounter.delegate = recorder
        let width = controller.columnWidth
        func place(at top: CGFloat) {
            mounter.place(
                controller, visible: CGRect(x: 0, y: top, width: width, height: 400), documentWidth: width,
                palette: TextPalette.resolveForTests, scale: 2, showsContent: true)
        }
        place(at: 0)
        #expect(recorder.wideOrigins["m#0"]?.y == 400)
        place(at: 1050)
        #expect(recorder.wideOrigins["m#0"]?.y == 400)
        controller.setHeights(["spacer": 450])
        mounter.invalidate()
        place(at: 1100)
        #expect(recorder.wideOrigins["m#0"]?.y == 450)
        #expect(recorder.accessoryOrigins["m#0"]?.y == 450)
    }
}
