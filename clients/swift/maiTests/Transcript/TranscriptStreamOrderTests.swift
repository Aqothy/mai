import CoreGraphics
import Foundation
import QuartzCore
import Testing

@testable import mai

/// A streamed message's text lands in the order it was written (PLAN 6.6):
/// a band takes any bitmap newer than the one it shows, and its fades start
/// with the bitmap that has their text.
@MainActor
struct TranscriptStreamOrderTests {
    @Test func aBandTakesAnyBitmapNewerThanItShowsButNotOlder() {
        let band = RowBandLayer()
        band.invalidate()
        let first = band.generation
        band.invalidate()
        band.invalidate()
        let current = band.generation
        // Outdated but newer than nothing: shows, so a band a stream changes
        // every frame still moves.
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

    @Test func fadesStartWithTheBitmapThatHasTheirText() {
        let band = RowBandLayer()
        band.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        band.invalidate()
        let first = band.generation
        band.fadeIn([CGRect(x: 0, y: 0, width: 10, height: 10)])
        band.invalidate()
        band.fadeIn([CGRect(x: 0, y: 20, width: 10, height: 10)])
        band.show(nil, generation: first)
        #expect(band.mask?.sublayers?.count == 2, "the solid plus the first generation's one piece")
        band.show(nil, generation: band.generation)
        #expect(band.mask?.sublayers?.count == 3)
    }
}
