import Foundation
import Testing

@testable import mai

/// PLAN 6.2: a burst of streamed text is released over about 12 frames,
/// ending on word ends and whole characters; everything at once when the turn
/// ended or motion is reduced.
@MainActor
struct TranscriptStreamPacingTests {
    private let text = Array(repeating: "naïve café 👩🏽‍💻 words flow", count: 40).joined(separator: " ")

    @Test func aBurstCatchesUpInAboutTwelveFramesOnWordEnds() {
        var stream = TranscriptStream(text: nil, entryText: text)
        var frames = 0
        var shown = ""
        while stream.releasedLength < text.utf8.count {
            let released = stream.release(text, reducesMotion: false)
            #expect(released.count >= shown.count)
            #expect(text.hasPrefix(released))
            let end = released.endIndex
            // Words here are shorter than the 24 bytes a release may extend.
            #expect(end == text.endIndex || text[end] == " ")
            shown = String(released)
            frames += 1
            #expect(frames < 100)
        }
        #expect(shown == text)
        #expect(frames > 12 && frames < 60)
    }

    @Test func reducedMotionAndAFinishedTurnShowEverything() {
        var stream = TranscriptStream(text: nil, entryText: text)
        #expect(String(stream.release(text, reducesMotion: true)) == text)

        var finishing = TranscriptStream(text: nil, entryText: text)
        finishing.isFinishing = true
        #expect(String(finishing.release(text, reducesMotion: false)) == text)
    }

    @Test func aTrickleStillMoves() {
        var stream = TranscriptStream(text: nil, entryText: "ab")
        let released = stream.release("ab", reducesMotion: false)
        #expect(released == "ab")
    }
}
