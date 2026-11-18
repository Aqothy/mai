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
    private var committedLength = 0
    private var source: [UInt8] = []
    private var parsesWholeDocument = false

    mutating func update(_ text: String) -> Snapshot {
        accept(text)
        if parsesWholeDocument {
            return Snapshot(committed: [], open: MarkdownTailHealer.blocks(forOpenTail: text))
        }
        let tail = Array(source[committedLength...])
        if Self.containsDefinition(tail) {
            parsesWholeDocument = true
            committed = []
            committedLength = 0
            return Snapshot(committed: [], open: MarkdownTailHealer.blocks(forOpenTail: text))
        }
        let boundary = MarkdownCommitBoundary.committedLength(of: tail)
        if boundary > 0 {
            let closed = String(decoding: tail[..<boundary], as: UTF8.self)
            committed += MarkdownPlanner.locatedBlocks(from: closed).map(\.block)
            committedLength += boundary
        }
        let open = String(decoding: tail[boundary...], as: UTF8.self)
        return Snapshot(committed: committed, open: MarkdownTailHealer.blocks(forOpenTail: open))
    }

    /// The finished message's blocks: the tail parsed as written.
    mutating func finish(_ text: String) -> [MarkdownBlock] {
        accept(text)
        if parsesWholeDocument || Self.containsDefinition(Array(source[committedLength...])) {
            parsesWholeDocument = true
            committed = MarkdownPlanner.blocks(from: text)
            committedLength = source.count
            return committed
        }
        let tail = String(decoding: source[committedLength...], as: UTF8.self)
        committed += MarkdownPlanner.locatedBlocks(from: tail).map(\.block)
        committedLength = source.count
        if committed.isEmpty { committed = MarkdownPlanner.blocks(from: text) }
        return committed
    }

    /// Streams only append. Anything else (a replaced message) starts over.
    private mutating func accept(_ text: String) {
        let bytes = Array(text.utf8)
        if bytes.count < committedLength || !bytes.starts(with: source.prefix(committedLength)) {
            committed = []
            committedLength = 0
            parsesWholeDocument = false
        }
        source = bytes
    }

    /// `[label]: destination` or `[^note]: text` at a line start.
    private static func containsDefinition(_ bytes: [UInt8]) -> Bool {
        var lineStart = 0
        while lineStart < bytes.count {
            var cursor = lineStart
            var spaces = 0
            while cursor < bytes.count, bytes[cursor] == UInt8(ascii: " "), spaces < 3 {
                cursor += 1
                spaces += 1
            }
            if cursor < bytes.count, bytes[cursor] == UInt8(ascii: "[") {
                var end = cursor + 1
                while end < bytes.count, bytes[end] != UInt8(ascii: "]"), bytes[end] != 0x0A { end += 1 }
                if end + 1 < bytes.count, bytes[end] == UInt8(ascii: "]"), bytes[end + 1] == UInt8(ascii: ":") {
                    return true
                }
            }
            while cursor < bytes.count, bytes[cursor] != 0x0A { cursor += 1 }
            lineStart = cursor + 1
        }
        return false
    }
}
