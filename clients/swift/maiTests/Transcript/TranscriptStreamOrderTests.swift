import CoreGraphics
import Foundation
import QuartzCore
import Testing

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
        layer.drawBands(in: layer.bounds, visible: layer.bounds, offMain: true)
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
        #expect(bands.map(\.frame) == RowLayer.bandFrames(height: after.height, width: 400))
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

}
