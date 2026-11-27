import CoreGraphics
import Foundation

/// A message streaming into the transcript: where its text comes from and
/// what the stream worker last made of it.
struct TranscriptStream {
    var kind: TranscriptMessage.Kind = .assistant
    /// The store's live text for the message, which grows without
    /// publishing a change (only the first chunk does).
    var text: ThreadStreamingText?
    /// The message's text from the last structural update, for a message the
    /// store keeps no live text for.
    var entryText: String
    var blocks: [MarkdownBlock] = []
    var metrics: [TextMetrics] = []
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
    /// ending at the end of a word. White space goes with the word after it,
    /// so a new line, or a code line's indent, shows with its first word
    /// instead of as an empty line before it; until that word arrives the
    /// release does not move. Everything at once when the turn ended or
    /// motion is reduced.
    mutating func release(_ text: String, reducesMotion: Bool) -> Substring {
        let utf8 = text.utf8
        let total = utf8.count
        guard !reducesMotion, !isFinishing, total > releasedLength else {
            releasedLength = total
            return text[...]
        }
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D }
        let step = max(Self.minimumPerFrame, (total - releasedLength) / 12)
        var end = utf8.index(utf8.startIndex, offsetBy: min(total, releasedLength + step))
        // Past white space, then on to the end of the word in progress, a few
        // bytes at most.
        while end < utf8.endIndex, isSpace(utf8[end]) { utf8.formIndex(after: &end) }
        var scanned = 0
        while end < utf8.endIndex, scanned < 24, !isSpace(utf8[end]) {
            utf8.formIndex(after: &end)
            scanned += 1
        }
        // Whole characters only.
        while end < utf8.endIndex, end.samePosition(in: text) == nil { utf8.formIndex(after: &end) }
        // The text so far ends in white space: it waits for its word.
        let start = utf8.index(utf8.startIndex, offsetBy: releasedLength)
        while end > start, isSpace(utf8[utf8.index(before: end)]) { utf8.formIndex(before: &end) }
        releasedLength = utf8.distance(from: utf8.startIndex, to: end)
        return text[..<end]
    }
}
