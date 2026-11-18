import CoreGraphics
import Foundation

/// A message streaming into the transcript: where its text comes from and
/// what the stream worker last made of it.
@MainActor
struct TranscriptStream {
    /// The store's live text for the message, which grows without
    /// publishing a change (only the first chunk does).
    var text: ThreadStreamingText?
    /// The message's text from the last structural update, for a message the
    /// store keeps no live text for.
    var entryText: String
    var blocks: [MarkdownBlock] = []
    /// The UTF-8 length the rows show.
    var shownLength = 0
    /// The UTF-8 length released to the rows so far (PLAN 6.2).
    var releasedLength = 0
    var isInFlight = false
    /// The turn ended: the next update is the final parse.
    var isFinishing = false

    var currentText: String {
        let live = text?.text ?? ""
        return live.utf8.count >= entryText.utf8.count ? live : entryText
    }

    /// The least a frame releases, so a trickle of text still moves.
    static let minimumPerFrame = 3

    /// The part of `text` to show this frame (PLAN 6.2): bursts arrive
    /// paced, the backlog released over about 12 frames (100 ms at 120 Hz),
    /// ending at the end of a word. Everything at once when the turn ended or
    /// motion is reduced.
    mutating func release(_ text: String, reducesMotion: Bool) -> Substring {
        let utf8 = text.utf8
        let total = utf8.count
        guard !reducesMotion, !isFinishing, total > releasedLength else {
            releasedLength = total
            return text[...]
        }
        let step = max(Self.minimumPerFrame, (total - releasedLength) / 12)
        var end = utf8.index(utf8.startIndex, offsetBy: min(total, releasedLength + step))
        // On to the end of the word in progress, a few bytes at most.
        var scanned = 0
        while end < utf8.endIndex, scanned < 24, utf8[end] != 0x20, utf8[end] != 0x0A {
            utf8.formIndex(after: &end)
            scanned += 1
        }
        // Whole characters only.
        while end < utf8.endIndex, end.samePosition(in: text) == nil { utf8.formIndex(after: &end) }
        releasedLength = utf8.distance(from: utf8.startIndex, to: end)
        return text[..<end]
    }
}
