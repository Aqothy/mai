import CoreGraphics
import Foundation

/// Parses a growing message: blocks before the commit boundary are parsed
/// once and never again; only the open tail is re-parsed, healed, each
/// update. Committed blocks are exactly what a one-shot parse of the
/// finished message gives (the commit boundary only cuts where a block can
/// no longer change), so the rows a stream leaves are the rows the message
/// has when opened later.
///
/// A link reference definition or footnote can change how earlier text
/// parses, so once one appears the parser re-parses the whole message each
/// update instead.
nonisolated struct StreamingMarkdownParser: Sendable {
    struct Snapshot: Equatable, Sendable {
        /// Final blocks, in order; earlier snapshots' committed blocks are a
        /// prefix of these.
        var committed: [MarkdownBlock]
        /// The open tail's blocks as they render now (usually one).
        var open: [MarkdownBlock]

        var blocks: [MarkdownBlock] { committed + open }
    }

    private(set) var committed: [MarkdownBlock] = []
    /// Counts the times committed blocks were dropped (a replaced message, or
    /// a definition switching to whole-message parsing): the stream worker
    /// skips re-checking committed blocks only while it stays the same.
    private(set) var committedResetCount = 0
    private var committedLength = 0
    private var source: [UInt8] = []
    private(set) var parsesWholeDocument = false
    /// Where the definition scan resumes: the start of the first line not
    /// yet scanned to its end, and the fence open there (a definition's
    /// syntax inside code is code).
    private var definitionScanStart = 0
    private var definitionFence: (marker: UInt8, length: Int)?

    mutating func update(_ text: String) -> Snapshot {
        accept(text)
        if parsesWholeDocument {
            return Snapshot(committed: [], open: MarkdownTailHealer.blocks(forOpenTail: text))
        }
        if scanForDefinition() {
            parsesWholeDocument = true
            committedResetCount &+= 1
            committed = []
            committedLength = 0
            return Snapshot(committed: [], open: MarkdownTailHealer.blocks(forOpenTail: text))
        }
        let boundary = MarkdownCommitBoundary.committedLength(of: source[committedLength...])
        if boundary > 0 {
            let closed = String(decoding: source[committedLength..<(committedLength + boundary)], as: UTF8.self)
            committed += MarkdownPlanner.parseBlocks(from: closed)
            committedLength += boundary
        }
        let open = String(decoding: source[committedLength...], as: UTF8.self)
        return Snapshot(committed: committed, open: MarkdownTailHealer.blocks(forOpenTail: open))
    }

    /// The finished message's blocks: the tail parsed as written.
    mutating func finish(_ text: String) -> [MarkdownBlock] {
        accept(text)
        if parsesWholeDocument || scanForDefinition() {
            parsesWholeDocument = true
            committedResetCount &+= 1
            committed = MarkdownPlanner.blocks(from: text)
            committedLength = source.count
            return committed
        }
        let tail = String(decoding: source[committedLength...], as: UTF8.self)
        committed += MarkdownPlanner.parseBlocks(from: tail)
        committedLength = source.count
        if committed.isEmpty { committed = MarkdownPlanner.blocks(from: text) }
        return committed
    }

    /// Streams only append. Anything else (a replaced message) starts over.
    /// An append adds only its new bytes: the message is not copied again
    /// every update.
    private mutating func accept(_ text: String) {
        let utf8 = text.utf8
        if utf8.count >= source.count {
            let isAppend = utf8.withContiguousStorageIfAvailable { new in
                source.withUnsafeBufferPointer { old in
                    guard let oldBase = old.baseAddress else { return true }
                    guard let newBase = new.baseAddress else { return false }
                    return memcmp(oldBase, newBase, old.count) == 0
                }
            }
            if isAppend == true {
                source.append(contentsOf: utf8.dropFirst(source.count))
                return
            }
        }
        let bytes = Array(utf8)
        if bytes.count < committedLength || !bytes.starts(with: source.prefix(committedLength)) {
            committed = []
            committedLength = 0
            committedResetCount &+= 1
            parsesWholeDocument = false
            definitionScanStart = 0
            definitionFence = nil
        } else if !bytes.starts(with: source) {
            // The tail was replaced: scan it again from the committed
            // boundary, which is never inside a fence.
            definitionScanStart = min(definitionScanStart, committedLength)
            definitionFence = nil
        }
        source = bytes
    }

    /// `[label]: destination` or `[^note]: text` at a line start, outside
    /// fenced code, in the text not scanned yet: each line is scanned once.
    private mutating func scanForDefinition() -> Bool {
        var lineStart = definitionScanStart
        while lineStart < source.count {
            var lineEnd = lineStart
            while lineEnd < source.count, source[lineEnd] != 0x0A { lineEnd += 1 }
            let isTerminated = lineEnd < source.count
            let contentEnd = lineEnd > lineStart && source[lineEnd - 1] == 0x0D ? lineEnd - 1 : lineEnd
            var indent = 0
            var cursor = lineStart
            while cursor < contentEnd {
                let byte = source[cursor]
                if byte == UInt8(ascii: " ") {
                    indent += 1
                } else if byte == UInt8(ascii: "\t") {
                    indent += 4 - indent % 4
                } else {
                    break
                }
                cursor += 1
            }
            if let open = definitionFence {
                if indent < 4, cursor < contentEnd, source[cursor] == open.marker {
                    var runEnd = cursor
                    while runEnd < contentEnd, source[runEnd] == open.marker { runEnd += 1 }
                    let closes =
                        runEnd - cursor >= open.length
                        && source[runEnd..<contentEnd].allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }
                    if closes, isTerminated { definitionFence = nil }
                }
            } else if indent < 4, cursor < contentEnd {
                let first = source[cursor]
                if first == UInt8(ascii: "`") || first == UInt8(ascii: "~") {
                    var runEnd = cursor
                    while runEnd < contentEnd, source[runEnd] == first { runEnd += 1 }
                    let opens =
                        runEnd - cursor >= 3
                        && (first != UInt8(ascii: "`") || !source[runEnd..<contentEnd].contains(UInt8(ascii: "`")))
                    if opens, isTerminated { definitionFence = (first, runEnd - cursor) }
                } else if first == UInt8(ascii: "[") {
                    var end = cursor + 1
                    while end < contentEnd, source[end] != UInt8(ascii: "]") { end += 1 }
                    if end + 1 < contentEnd, source[end] == UInt8(ascii: "]"), source[end + 1] == UInt8(ascii: ":") {
                        return true
                    }
                }
            }
            // The last line can still change: it is scanned again next time.
            guard isTerminated else { break }
            lineStart = lineEnd + 1
            definitionScanStart = lineStart
        }
        return false
    }
}
