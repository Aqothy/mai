import Foundation

/// Parses a growing message as `@pierre/words` `lib/core.ts` keeps an HTML
/// session (Apache 2.0): blocks before the parser's last safe boundary (a
/// blank line at document depth) are final and parsed once; each update parses
/// only the rest, with completion repairing its unfinished last block.
///
/// Once a parse validated a single-line paragraph ending in a literal word, or
/// an unindented top-level fence, appended text that cannot change its syntax
/// extends it without parsing. Syntax bytes, a possible closing fence, control
/// bytes and structural changes go back to the parser.
///
/// A link reference definition can change earlier text: committed blocks that
/// hold a `[` parse again when the definitions they see change, so a
/// definition near the top keeps the stream incremental.
nonisolated struct StreamingMarkdownParser: Sendable {
    struct Snapshot: Equatable, Sendable {
        /// Final blocks, in order; earlier snapshots' committed blocks are a
        /// prefix of these unless a definition resolved an earlier `[...]`.
        var committed: [MarkdownBlock]
        /// The unfinished tail as it shows now.
        var open: [MarkdownBlock]

        var blocks: [MarkdownBlock] { committed + open }
    }

    /// A committed source range and the blocks it produced.
    private struct Chunk: Sendable {
        var bytes: Range<Int>
        var blocks: Range<Int>
        /// Holds a `[`, so a new definition can change its blocks.
        var hasBracket: Bool
    }

    private enum Literal: Sendable {
        case none
        /// The open block is one paragraph whose last run is plain and ends in a
        /// literal word; trailing spaces wait until text follows them.
        case paragraph(trailingSpaces: Int, hasBracket: Bool)
        /// The open block is a top-level fence opened on the tail's first line.
        case fence(marker: UInt8, length: Int, bodyStart: Int, lastLine: Int)
    }

    /// Incremented when committed blocks change: a replaced message, or a
    /// definition that resolves an earlier reference.
    private(set) var committedResetCount = 0

    private var source: [UInt8] = []
    private var committed: [MarkdownBlock] = []
    private var committedLength = 0
    private var chunks: [Chunk] = []
    /// Definitions in committed text, first wins.
    private var definitions: [String: String] = [:]
    /// The definitions committed blocks were last parsed with.
    private var resolvedDefinitions: [String: String] = [:]
    private var open: [MarkdownBlock] = []
    private var literal = Literal.none

    mutating func update(_ text: String) -> Snapshot {
        let previousLength = source.count
        if accept(text) {
            if source.count == previousLength { return Snapshot(committed: committed, open: open) }
            if extendLiterally(from: previousLength) { return Snapshot(committed: committed, open: open) }
        }
        parseTail(incomplete: true)
        return Snapshot(committed: committed, open: open)
    }

    /// The finished message's blocks: the tail parsed as written.
    mutating func finish(_ text: String) -> [MarkdownBlock] {
        accept(text)
        parseTail(incomplete: false)
        var blocks = committed + open
        if blocks.isEmpty, text.contains(where: { !$0.isWhitespace }) {
            blocks = [.paragraph([MarkdownInline(text: text)])]
        }
        return blocks
    }

    // MARK: - Parsing

    private mutating func parseTail(incomplete: Bool) {
        literal = .none
        // A byte order mark after the boundary is text, but a tail parse would
        // drop it as the document's: parse the whole message instead.
        if committedLength > 0, source[committedLength...].starts(with: [0xEF, 0xBB, 0xBF]) { reset() }
        let parsed = source.withUnsafeBufferPointer { buffer in
            MarkdownPlanner.parse(
                bytes: UnsafeBufferPointer(rebasing: buffer[committedLength...]), externalLinkDefinitions: definitions,
                incomplete: incomplete)
        }
        // Committed blocks see every definition, as a whole-message parse does.
        var visible = definitions
        visible.merge(parsed.linkDefinitions) { first, _ in first }
        if visible != resolvedDefinitions {
            resolvedDefinitions = visible
            resolveCommitted()
        }
        if parsed.committedBlockCount > 0 || parsed.committedLength > 0 {
            let bytes = committedLength..<(committedLength &+ parsed.committedLength)
            let blocks = committed.count..<(committed.count &+ parsed.committedBlockCount)
            committed.append(contentsOf: parsed.blocks[..<parsed.committedBlockCount])
            let hasBracket = source.withUnsafeBufferPointer {
                MarkdownByteScanner.findByte(UInt8(ascii: "["), in: $0, from: bytes.lowerBound, end: bytes.upperBound)
                    < bytes.upperBound
            }
            chunks.append(Chunk(bytes: bytes, blocks: blocks, hasBracket: hasBracket))
            definitions.merge(parsed.committedDefinitions) { first, _ in first }
            committedLength = bytes.upperBound
        }
        open = Array(parsed.blocks[parsed.committedBlockCount...])
        if incomplete, !parsed.repaired, parsed.linkDefinitions.isEmpty { armLiteral() }
    }

    /// Parses again the committed chunks a definition could change.
    private mutating func resolveCommitted() {
        var changed = false
        for chunk in chunks where chunk.hasBracket {
            let blocks = source.withUnsafeBufferPointer { buffer in
                MarkdownPlanner.parse(
                    bytes: UnsafeBufferPointer(rebasing: buffer[chunk.bytes]), externalLinkDefinitions: resolvedDefinitions
                ).blocks
            }
            if !committed[chunk.blocks].elementsEqual(blocks) {
                committed.replaceSubrange(chunk.blocks, with: blocks)
                changed = true
            }
        }
        if changed { committedResetCount &+= 1 }
    }

    // MARK: - Literal extension

    /// Whether the parsed open tail can extend without parsing, per `core.ts`.
    private mutating func armLiteral() {
        guard open.count == 1 else { return }
        source.withUnsafeBufferPointer { buffer in
            let tail = UnsafeBufferPointer(rebasing: buffer[committedLength...])
            switch open[0] {
            case .paragraph(let inlines):
                literal = paragraphLiteral(tail, inlines) ?? .none
            case .code:
                literal = fenceLiteral(buffer) ?? .none
            default:
                break
            }
        }
    }

    /// A paragraph extends literally when its final word is literal: no syntax
    /// waits to close and appended text cannot start any.
    private func paragraphLiteral(_ tail: UnsafeBufferPointer<UInt8>, _ inlines: [MarkdownInline]) -> Literal? {
        var end = tail.count
        while end > 0, tail[end &- 1] == 0x20 { end &-= 1 }
        var start = 0
        while start < end, MarkdownByteScanner.isWhitespace(tail[start]) { start &+= 1 }
        guard start < end, let lastRun = inlines.last, lastRun.style.isEmpty, lastRun.link == nil else { return nil }
        let text = UnsafeBufferPointer(rebasing: tail[start..<end])
        var wordStart = text.count
        while wordStart > 0, text[wordStart &- 1] != 0x20 { wordStart &-= 1 }
        let word = UnsafeBufferPointer(rebasing: text[wordStart...])
        // The last two characters hold no syntax, and the last is visible:
        // completion skips trailing whitespace, so only a visible character
        // shows it left nothing waiting to close.
        let lastScalar = MarkdownByteScanner.decodeUTF8Backward(text, before: text.count, start: 0)
        let beforeLast = text.count &- UTF8.width(lastScalar)
        guard !lastScalar.properties.isWhitespace, lastScalar != "\u{FEFF}",
            !MarkdownByteScanner.containsLiteralBreak(
                in: text, from: max(0, beforeLast &- UTF8.width(
                    MarkdownByteScanner.decodeUTF8Backward(text, before: beforeLast, start: 0))), end: text.count)
        else { return nil }
        // Entities, raw HTML and autolinks need the parser.
        guard !word.contains(where: { $0 == UInt8(ascii: "&") || $0 == UInt8(ascii: "<") || $0 == UInt8(ascii: ">")
            || $0 == UInt8(ascii: "@") || $0 == UInt8(ascii: ":") }),
            !containsWWW(word), lastRun.text.utf8.reversed().starts(with: word.reversed())
        else { return nil }
        // Only digits or only marker characters can still become a list
        // marker, a heading or a thematic break; `[label]:` a definition.
        if isMarkerLike(text) { return nil }
        if text[0] == UInt8(ascii: "["), containsSequence(text, UInt8(ascii: "]"), UInt8(ascii: ":")) { return nil }
        // One line, no tabs or tags (this reads the whole paragraph, so it runs last).
        guard !text.contains(where: { $0 == UInt8(ascii: "<") || $0 == 0x0D || $0 == 0x0A || $0 == 0x09 || $0 == 0 })
        else { return nil }
        return .paragraph(trailingSpaces: tail.count &- end, hasBracket: text.contains(UInt8(ascii: "[")))
    }

    /// An unindented fence opened on the tail's first line, its opening line
    /// ended and no line closing it or able to grow into its closer.
    private func fenceLiteral(_ source: UnsafeBufferPointer<UInt8>) -> Literal? {
        let start = committedLength
        let openerEnd = MarkdownByteScanner.findLineEnd(source, from: start, end: source.count)
        guard openerEnd < source.count, source[openerEnd] == 0x0A, source[source.count &- 1] != 0x0D else { return nil }
        let marker = source[start]
        guard marker == UInt8(ascii: "`") || marker == UInt8(ascii: "~") else { return nil }
        let length = MarkdownByteScanner.runEnd(of: marker, in: source, from: start, end: openerEnd) &- start
        let bodyStart = openerEnd &+ 1
        guard length >= 3, !fenceMayClose(source, previous: bodyStart, line: bodyStart, marker: marker, length: length)
        else { return nil }
        var lastLine = source.count
        while lastLine > bodyStart, source[lastLine &- 1] != 0x0A, source[lastLine &- 1] != 0x0D { lastLine &-= 1 }
        return .fence(marker: marker, length: length, bodyStart: bodyStart, lastLine: lastLine)
    }

    /// Extends the literal open block with `source[previousLength...]`.
    private mutating func extendLiterally(from previousLength: Int) -> Bool {
        switch literal {
        case .none:
            return false
        case .paragraph(let spaces, let hasBracket):
            let extended: (String, Int)? = source.withUnsafeBufferPointer { buffer in
                let added = UnsafeBufferPointer(rebasing: buffer[previousLength...])
                guard !MarkdownByteScanner.containsLiteralBreak(in: added, from: 0, end: added.count),
                    !hasBracket || !added.contains(where: { $0 == UInt8(ascii: "(") || $0 == UInt8(ascii: ")") }),
                    !containsWWW(UnsafeBufferPointer(rebasing: buffer[max(0, previousLength &- 3)...]))
                else { return nil }
                var end = added.count
                while end > 0, added[end &- 1] == 0x20 { end &-= 1 }
                guard end > 0 else { return ("", spaces &+ added.count) }
                let text = String(repeating: " ", count: spaces) + String(decoding: added[..<end], as: UTF8.self)
                return (text, added.count &- end)
            }
            guard let (text, trailing) = extended, case .paragraph(var inlines) = open[0] else { return false }
            if !text.isEmpty { inlines[inlines.count &- 1].text += text }
            open = [.paragraph(inlines)]
            literal = .paragraph(trailingSpaces: trailing, hasBracket: hasBracket)
            return true
        case .fence(let marker, let length, let bodyStart, let lastLine):
            let extended: (String, Int)? = source.withUnsafeBufferPointer { buffer in
                let added = UnsafeBufferPointer(rebasing: buffer[previousLength...])
                guard !added.contains(where: { $0 == 0 || $0 == 0x0D }),
                    !fenceMayClose(buffer, previous: previousLength, line: lastLine, marker: marker, length: length)
                else { return nil }
                // The code excludes the body's final line feed.
                var text = previousLength > bodyStart && buffer[previousLength &- 1] == 0x0A ? "\n" : ""
                let end = added.last == 0x0A ? added.count &- 1 : added.count
                text += String(decoding: added[..<end], as: UTF8.self)
                let newline = added.lastIndex(of: 0x0A).map { previousLength &+ $0 &+ 1 } ?? lastLine
                return (text, newline)
            }
            guard let (text, newLastLine) = extended, case .code(let language, var code) = open[0] else { return false }
            code += text
            open = [.code(language: language, code: code)]
            literal = .fence(marker: marker, length: length, bodyStart: bodyStart, lastLine: newLastLine)
            return true
        }
    }

    /// A finished line that closes the fence, or a last line that can still
    /// grow into one, needs the parser (`core.ts` `fenceMayClose`).
    private func fenceMayClose(
        _ input: UnsafeBufferPointer<UInt8>, previous: Int, line start: Int, marker: UInt8, length: Int
    ) -> Bool {
        var line = start
        while true {
            var at = line
            while at < min(input.count, line &+ 3), input[at] == 0x20 { at &+= 1 }
            let run = at
            while at < input.count, input[at] == marker { at &+= 1 }
            if at > run {
                let count = at &- run
                while at < input.count, MarkdownByteScanner.isSpace(input[at]) { at &+= 1 }
                if at == input.count || (input[at] == 0x0A && count >= length) { return true }
            }
            let next = MarkdownByteScanner.findByte(0x0A, in: input, from: max(line, previous), end: input.count)
            guard next < input.count else { return false }
            line = next &+ 1
        }
    }

    // MARK: - Helpers

    /// Streams only append; anything else (a replaced message) starts over.
    /// Returns whether `text` appended to the source.
    @discardableResult
    private mutating func accept(_ text: String) -> Bool {
        let utf8 = text.utf8
        let appended =
            utf8.count >= source.count
            && (utf8.withContiguousStorageIfAvailable { new in
                source.withUnsafeBufferPointer { old in
                    old.isEmpty || memcmp(old.baseAddress, new.baseAddress, old.count) == 0
                }
            } ?? utf8.starts(with: source))
        if appended {
            source.append(contentsOf: utf8.dropFirst(source.count))
            return true
        }
        source = Array(utf8)
        reset()
        return false
    }

    private mutating func reset() {
        committed = []
        committedLength = 0
        chunks = []
        definitions = [:]
        resolvedDefinitions = [:]
        open = []
        literal = .none
        committedResetCount &+= 1
    }

    private func containsWWW(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard bytes.count >= 4 else { return false }
        for i in 0...(bytes.count &- 4)
        where bytes[i] | 0x20 == UInt8(ascii: "w") && bytes[i &+ 1] | 0x20 == UInt8(ascii: "w")
            && bytes[i &+ 2] | 0x20 == UInt8(ascii: "w") && bytes[i &+ 3] == UInt8(ascii: ".")
        {
            return true
        }
        return false
    }

    private func containsSequence(_ bytes: UnsafeBufferPointer<UInt8>, _ a: UInt8, _ b: UInt8) -> Bool {
        guard bytes.count >= 2 else { return false }
        return (0..<(bytes.count &- 1)).contains { bytes[$0] == a && bytes[$0 &+ 1] == b }
    }

    /// `\d+[.)]?` or `[-=+# ]+`.
    private func isMarkerLike(_ text: UnsafeBufferPointer<UInt8>) -> Bool {
        if text.allSatisfy({ $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "=") || $0 == UInt8(ascii: "+")
            || $0 == UInt8(ascii: "#") || $0 == 0x20 })
        {
            return true
        }
        var digits = text.prefix { MarkdownByteScanner.isDigit($0) }.count
        guard digits > 0 else { return false }
        if digits < text.count, text[digits] == UInt8(ascii: ".") || text[digits] == UInt8(ascii: ")") { digits &+= 1 }
        return digits == text.count
    }
}
