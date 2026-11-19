import CoreGraphics
import Foundation
import QuartzCore
import Testing

@testable import mai

/// A streamed message's text lands in the order it was written (PLAN 6.5):
/// a band takes any bitmap newer than the one it shows.
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

}
