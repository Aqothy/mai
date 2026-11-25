import Foundation

/// Splits oversized Markdown blocks, user messages, and thoughts into bounded
/// transcript rows so Core Text layout time, `TextLayout` RAM, and eviction
/// stay bounded regardless of message size. All chunks of one logical block or
/// message share the same `sourceID` so reading-place anchoring and cross-row
/// selection remain seamless.
nonisolated enum TranscriptRowChunker {
    static let maxParagraphBytes = 16_384
    static let maxCodeLines = 200
    static let maxCodeBytes = 32_768
    static let maxListItems = 100
    static let maxUserMessageBytes = 16_384
    static let maxUserMessageLines = 200
    static let maxThoughtBytes = 16_384

    /// Turns parsed assistant `blocks` into bounded `TranscriptRow`s. Normal
    /// messages take the fast path with identical IDs (`messageID#0`, …) and
    /// zero extra allocations.
    static func assistantRows(
        messageID: String, turnID: String? = nil, blocks: [MarkdownBlock]
    ) -> [TranscriptRow] {
        var needsChunking = false
        for block in blocks where exceedsLimit(block) {
            needsChunking = true
            break
        }
        if !needsChunking {
            return blocks.indices.map { index in
                TranscriptRow(
                    id: "\(messageID)#\(index)", sourceID: messageID,
                    kind: .markdownBlock(blocks[index], .of(index, in: blocks)),
                    messageID: messageID, role: .assistant, turnID: turnID)
            }
        }
        var rows: [TranscriptRow] = []
        rows.reserveCapacity(blocks.count + 4)
        var rowIndex = 0
        for blockIndex in blocks.indices {
            let block = blocks[blockIndex]
            let outer = TranscriptBlockPosition.of(blockIndex, in: blocks)
            for piece in split(block, outer: outer) {
                rows.append(
                    TranscriptRow(
                        id: "\(messageID)#\(rowIndex)", sourceID: messageID,
                        kind: .markdownBlock(piece.block, piece.position),
                        messageID: messageID, role: .assistant, turnID: turnID,
                        separatorBefore: piece.joinsWithoutNewline ? "" : "\n"))
                rowIndex += 1
            }
        }
        return rows
    }

    /// Splits an oversized user message into bounded bubble rows sharing
    /// `sourceID = messageID`, at Markdown block boundaries so each renders
    /// as the whole message does there (`markdownPieces`). Normal prompts
    /// produce one row with id `"user|\(messageID)"`.
    static func userRows(messageID: String, turnID: String?, source: String) -> [TranscriptRow] {
        guard exceedsTextLimit(source, maxBytes: maxUserMessageBytes, maxLines: maxUserMessageLines) else {
            return [
                TranscriptRow(
                    id: "user|\(messageID)", sourceID: messageID,
                    kind: .userMessage(source: source, position: .single),
                    messageID: messageID, role: .user, turnID: turnID)
            ]
        }
        let pieces = markdownPieces(source, maxBytes: maxUserMessageBytes, maxLines: maxUserMessageLines)
        return pieces.enumerated().map { index, piece in
            let position = TranscriptBlockPosition(
                isFirst: index == 0, isLast: index == pieces.count - 1,
                joinsAbove: index > 0, joinsBelow: index < pieces.count - 1, startsBlock: index > 0 && piece.startsBlock)
            let rowID = index == 0 ? "user|\(messageID)" : "user|\(messageID)#\(index)"
            return TranscriptRow(
                id: rowID, sourceID: messageID,
                kind: .userMessage(source: piece.prefix + piece.text, position: position),
                messageID: messageID, role: .user, turnID: turnID, separatorBefore: piece.separator)
        }
    }

    /// A piece of a split Markdown message: its slice of the source, what
    /// joins it to the piece before (`TranscriptRow.separatorBefore`), and the
    /// lines a continuation repeats so it renders as it would in place (a
    /// fence's opening line, a table's header and delimiter rows).
    struct MarkdownPiece {
        let prefix: String
        let text: Substring
        let separator: String
        /// The piece starts a Markdown block (cut at a blank line or fence).
        let startsBlock: Bool
    }

    /// Splits Markdown at block boundaries (a blank line outside a fence,
    /// or a fence opening or closing) into pieces within the limits. A
    /// block too big for one piece splits at a line, its continuation
    /// repeating a fence's opening line or a table's header (as a printed
    /// table repeats its header on every page); a line too long splits at
    /// a space, else at a character boundary. One pass over the bytes, no
    /// parse: it runs on the main thread when rows are built.
    static func markdownPieces(_ text: String, maxBytes: Int, maxLines: Int) -> [MarkdownPiece] {
        var text = text
        text.makeContiguousUTF8()
        return text.utf8.withContiguousStorageIfAvailable { bytes in
            markdownPieces(text, bytes, maxBytes: maxBytes, maxLines: maxLines)
        } ?? []
    }

    private static func markdownPieces(
        _ text: String, _ bytes: UnsafeBufferPointer<UInt8>, maxBytes: Int, maxLines: Int
    ) -> [MarkdownPiece] {
        func index(_ offset: Int) -> String.Index { text.utf8.index(text.utf8.startIndex, offsetBy: offset) }
        func string(_ range: Range<Int>) -> String { String(decoding: UnsafeBufferPointer(rebasing: bytes[range]), as: UTF8.self) }
        var pieces: [MarkdownPiece] = []
        var pieceStart = 0
        var piecePrefix = ""
        var pieceSeparator = "\n"
        var pieceStartsBlock = false
        var pieceLines = 0
        var pieceBytes = 0
        // The latest block start inside the piece, with the piece's counts
        // before it.
        var boundary: (offset: Int, lines: Int, bytes: Int)?
        // The open fence, and the current block's first line, line count and
        // table header (its first two lines, when they are a table's).
        var fence: (marker: UInt8, length: Int, opener: Range<Int>)?
        var blockFirstLine: Range<Int>?
        var blockLines = 0
        var blockTable: String?
        var nextStartsBlock = true
        var cursor = 0

        func emit(upTo end: Int, next: Int, separator: String, startsBlock: Bool, prefix: String) {
            pieces.append(
                MarkdownPiece(
                    prefix: piecePrefix, text: text[index(pieceStart)..<index(end)], separator: pieceSeparator,
                    startsBlock: pieceStartsBlock))
            pieceStart = next
            piecePrefix = prefix
            pieceSeparator = separator
            pieceStartsBlock = startsBlock
        }

        while cursor < bytes.count {
            var lineEnd = cursor
            var isBlank = true
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A {
                let byte = bytes[lineEnd]
                if byte != 0x20, byte != 0x09, byte != 0x0D { isBlank = false }
                lineEnd &+= 1
            }
            let hasNewline = lineEnd < bytes.count
            let line = cursor..<lineEnd
            // What the line is, given the lines before it.
            let run = isBlank ? nil : fenceMarker(bytes, line)
            let closesFence =
                fence.map { open in run.map { $0.marker == open.marker && $0.length >= open.length && $0.isBare } ?? false }
                ?? false
            let opensFence = fence == nil && run != nil
            let startsBlock = fence == nil && (opensFence || (!isBlank && nextStartsBlock))
            if startsBlock, pieceLines > 0 { boundary = (cursor, pieceLines, pieceBytes) }
            // Cut before the line when it does not fit: at the latest block
            // start (the lines after it move on), else here, the continuation
            // reopening the block.
            let lineBytes = lineEnd - cursor
            if pieceLines > 0, pieceBytes + lineBytes + 1 > maxBytes || pieceLines >= maxLines {
                if let boundary {
                    emit(upTo: boundary.offset - 1, next: boundary.offset, separator: "\n", startsBlock: true, prefix: "")
                    pieceLines -= boundary.lines
                    pieceBytes -= boundary.bytes
                } else {
                    let prefix = fence.map { string($0.opener) + "\n" } ?? blockTable ?? ""
                    emit(upTo: cursor - 1, next: cursor, separator: "\n", startsBlock: false, prefix: prefix)
                    pieceLines = 0
                    pieceBytes = 0
                }
                boundary = nil
            }
            // A line longer than a piece (`lineCut`).
            var lineStart = cursor
            while lineEnd - lineStart + pieceBytes > maxBytes {
                let cut = lineCut(in: text, from: index(lineStart), maxBytes: max(1, maxBytes - pieceBytes))
                let end = text.utf8.distance(from: text.utf8.startIndex, to: cut.end)
                let next = text.utf8.distance(from: text.utf8.startIndex, to: cut.next)
                guard end > lineStart, next < lineEnd else { break }
                emit(
                    upTo: end, next: next, separator: cut.separator, startsBlock: false,
                    prefix: fence.map { string($0.opener) + "\n" } ?? "")
                pieceLines = 0
                pieceBytes = 0
                boundary = nil
                lineStart = next
            }
            pieceLines &+= 1
            pieceBytes &+= lineEnd - lineStart + (hasNewline ? 1 : 0)
            // The state after the line.
            if fence != nil {
                if closesFence {
                    fence = nil
                    nextStartsBlock = true
                }
            } else if let run, opensFence {
                fence = (run.marker, run.length, line)
                blockTable = nil
                nextStartsBlock = false
            } else if isBlank {
                nextStartsBlock = true
                blockFirstLine = nil
                blockTable = nil
            } else {
                if startsBlock {
                    blockFirstLine = line
                    blockLines = 1
                    blockTable = nil
                } else {
                    blockLines += 1
                    if blockLines == 2, let first = blockFirstLine, isTableDelimiter(bytes, line),
                        bytes[first].contains(0x7C)
                    {
                        blockTable = string(first.lowerBound..<lineEnd) + "\n"
                    }
                }
                nextStartsBlock = false
            }
            cursor = hasNewline ? lineEnd + 1 : lineEnd
        }
        pieces.append(
            MarkdownPiece(
                prefix: piecePrefix, text: text[index(pieceStart)...], separator: pieceSeparator,
                startsBlock: pieceStartsBlock))
        return pieces
    }

    /// Where to cut a line too long for a piece, within `maxBytes` of
    /// `start` (and past half of it): at a space before a letter, the space
    /// becoming the seam's separator (Markdown would drop it at either end of
    /// a piece) and the letter starting the next piece (no block syntax
    /// starts with one: never a list, quote or heading); else between two
    /// ASCII letters; else at any character boundary.
    private static func lineCut(
        in text: String, from start: String.Index, maxBytes: Int
    ) -> (end: String.Index, next: String.Index, separator: String) {
        let utf8 = text.utf8
        let limit = utf8.index(start, offsetBy: maxBytes, limitedBy: utf8.endIndex) ?? utf8.endIndex
        let floor = utf8.index(start, offsetBy: maxBytes / 2, limitedBy: limit) ?? start
        func isASCIILetter(_ byte: UInt8) -> Bool { (byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A }
        var index = limit
        while index > floor {
            let previous = utf8.index(before: index)
            if utf8[previous] == 0x20, index < utf8.endIndex,
                let scalarIndex = index.samePosition(in: text.unicodeScalars),
                case let scalar = text.unicodeScalars[scalarIndex], scalar.properties.isAlphabetic,
                scalar.properties.generalCategory != .nonspacingMark, scalar.properties.generalCategory != .spacingMark
            {
                return (previous, index, " ")
            }
            index = previous
        }
        index = limit
        while index > floor {
            let previous = utf8.index(before: index)
            if index < utf8.endIndex, isASCIILetter(utf8[previous]), isASCIILetter(utf8[index]) {
                return (index, index, "")
            }
            index = previous
        }
        let cut = snapToCharacterBoundary(in: text, from: start, candidate: limit)
        return (cut, cut, "")
    }

    /// A fence marker run at the start of `line` (CommonMark: up to three
    /// spaces, then three or more backticks or tildes), and whether only
    /// spaces follow it (a closing fence).
    private static func fenceMarker(
        _ bytes: UnsafeBufferPointer<UInt8>, _ line: Range<Int>
    ) -> (marker: UInt8, length: Int, isBare: Bool)? {
        var index = line.lowerBound
        while index < line.upperBound, bytes[index] == 0x20, index - line.lowerBound < 4 { index += 1 }
        guard index - line.lowerBound < 4, index < line.upperBound, bytes[index] == 0x60 || bytes[index] == 0x7E
        else { return nil }
        let marker = bytes[index]
        let runStart = index
        while index < line.upperBound, bytes[index] == marker { index += 1 }
        guard index - runStart >= 3 else { return nil }
        var isBare = true
        var hasBacktick = false
        for byte in bytes[index..<line.upperBound] {
            if byte != 0x20, byte != 0x09, byte != 0x0D { isBare = false }
            if byte == 0x60 { hasBacktick = true }
        }
        // A backtick fence's info string has no backtick (CommonMark 4.5).
        return marker == 0x60 && hasBacktick ? nil : (marker, index - runStart, isBare)
    }

    /// A GFM table delimiter row: `|`-separated cells of dashes with
    /// optional alignment colons.
    private static func isTableDelimiter(_ bytes: UnsafeBufferPointer<UInt8>, _ line: Range<Int>) -> Bool {
        var dashes = false
        for byte in bytes[line] {
            switch byte {
            case 0x2D: dashes = true
            case 0x7C, 0x3A, 0x20, 0x09, 0x0D: continue
            default: return false
            }
        }
        return dashes
    }

    /// Splits an oversized reasoning block into bounded `.thought` rows sharing
    /// `sourceID`.
    static func thoughtRows(turnID: String, ref: String, text: String) -> [TranscriptRow] {
        let baseID = "thought|\(turnID)|\(ref)"
        guard exceedsTextLimit(text, maxBytes: maxThoughtBytes, maxLines: maxUserMessageLines) else {
            return [TranscriptRow(id: baseID, sourceID: baseID, kind: .thought(text), turnID: turnID)]
        }
        let pieces = splitPlainText(text, maxBytes: maxThoughtBytes, maxLines: maxUserMessageLines)
        return pieces.enumerated().map { index, piece in
            let rowID = index == 0 ? baseID : "\(baseID)#\(index)"
            return TranscriptRow(
                id: rowID, sourceID: baseID, kind: .thought(piece.text), turnID: turnID,
                separatorBefore: piece.joinsWithoutNewline ? "" : "\n")
        }
    }

    // MARK: Block checks & splitting

    private struct BlockPiece {
        let block: MarkdownBlock
        let position: TranscriptBlockPosition
        let joinsWithoutNewline: Bool
    }

    private static func exceedsLimit(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .paragraph(let inlines):
            var bytes = 0
            for inline in inlines {
                bytes &+= inline.text.utf8.count
                if bytes > maxParagraphBytes { return true }
            }
            return false
        case .code(_, let code):
            if code.utf8.count > maxCodeBytes {
                return code.utf8.contains(0x0A)
            }
            var lines = 1
            for byte in code.utf8 where byte == 0x0A {
                lines &+= 1
                if lines > maxCodeLines { return true }
            }
            return false
        case .list(let list):
            return list.items.count > maxListItems
        case .heading, .quote, .table, .rule:
            return false
        }
    }

    private static func split(_ block: MarkdownBlock, outer: TranscriptBlockPosition) -> [BlockPiece] {
        guard exceedsLimit(block) else {
            return [BlockPiece(block: block, position: outer, joinsWithoutNewline: false)]
        }
        switch block {
        case .paragraph(let inlines):
            return splitParagraph(inlines, outer: outer)
        case .code(let language, let code):
            return splitCode(language: language, code: code, outer: outer)
        case .list(let list):
            return splitList(list, outer: outer)
        default:
            return [BlockPiece(block: block, position: outer, joinsWithoutNewline: false)]
        }
    }

    private static func splitCode(
        language: String?, code: String, outer: TranscriptBlockPosition
    ) -> [BlockPiece] {
        var contiguous = code
        contiguous.makeContiguousUTF8()
        // One pass over the bytes: where chunks start and the widest line.
        let (chunks, widestLine) =
            contiguous.utf8.withContiguousStorageIfAvailable { bytes -> ([String], Int) in
                var chunks: [String] = []
                var chunkStart = 0
                var chunkBytes = 0
                var chunkLines = 0
                var widest = 0
                var cursor = 0
                while cursor < bytes.count {
                    var lineEnd = cursor
                    var columns = 0
                    while lineEnd < bytes.count, bytes[lineEnd] != 0x0A {
                        let byte = bytes[lineEnd]
                        columns =
                            byte == 0x09 ? (columns / 4 + 1) * 4
                            : byte < 0x80 ? columns + 1 : columns + nonASCIIColumns(bytes, at: lineEnd)
                        lineEnd &+= 1
                    }
                    widest = max(widest, columns)
                    let lineBytes = lineEnd - cursor
                    let hasNewline = lineEnd < bytes.count
                    if chunkLines > 0 && (chunkLines >= maxCodeLines || chunkBytes + lineBytes + 1 > maxCodeBytes) {
                        // End the chunk before the newline that preceded `cursor`.
                        chunks.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[chunkStart..<(cursor - 1)]), as: UTF8.self))
                        chunkStart = cursor
                        chunkBytes = 0
                        chunkLines = 0
                    }
                    chunkLines &+= 1
                    chunkBytes &+= lineBytes + (hasNewline ? 1 : 0)
                    cursor = hasNewline ? lineEnd + 1 : lineEnd
                }
                if !chunks.isEmpty {
                    chunks.append(String(decoding: UnsafeBufferPointer(rebasing: bytes[chunkStart...]), as: UTF8.self))
                }
                return (chunks, widest)
            } ?? ([], 0)
        if chunks.count <= 1 {
            return [BlockPiece(block: .code(language: language, code: code), position: outer, joinsWithoutNewline: false)]
        }
        return chunks.enumerated().map { index, chunk in
            let pos = TranscriptBlockPosition(
                isFirst: index == 0 && outer.isFirst,
                isLast: index == chunks.count - 1 && outer.isLast,
                joinsAbove: index > 0 || outer.joinsAbove,
                joinsBelow: index < chunks.count - 1 || outer.joinsBelow,
                widestLineColumns: widestLine)
            return BlockPiece(block: .code(language: language, code: chunk), position: pos, joinsWithoutNewline: false)
        }
    }

    /// The monospace columns of the character whose UTF-8 sequence holds
    /// the non-ASCII byte at `index`, counted at its lead byte, as a terminal
    /// counts them (wcwidth; Zed sizes a scroll width the same way, longest
    /// row times the em width): East Asian wide and emoji (astral, and the
    /// symbols and dingbats replies use: ✅ ❌ ⚠️ ✨ ⭐) 2, combining and
    /// zero-width marks 0, else 1, as the code font draws its own symbols
    /// (box drawing, arrows, quotes).
    private static func nonASCIIColumns(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Int {
        let byte = bytes[index]
        switch byte {
        case 0xC0..<0xE0:
            // U+0300-U+036F, combining diacritical marks.
            return byte == 0xCC || byte == 0xCD ? 0 : 1
        case 0xE0..<0xF0:
            guard index + 2 < bytes.count else { return 1 }
            let scalar =
                (UInt32(byte & 0x0F) << 12) | (UInt32(bytes[index + 1] & 0x3F) << 6) | UInt32(bytes[index + 2] & 0x3F)
            switch scalar {
            case 0x200B...0x200F, 0x20D0...0x20FF, 0xFE00...0xFE0F:
                return 0
            case 0x1100...0x115F, 0x231A...0x231B, 0x23E9...0x23F3, 0x2600...0x27BF, 0x2B1B...0x2B55, 0x2E80...0xA4CF,
                0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6:
                return 2
            default:
                return 1
            }
        case 0xF0...:
            return 2
        default:
            // A continuation byte: its character counted at its lead byte.
            return 0
        }
    }

    private static func splitParagraph(
        _ inlines: [MarkdownInline], outer: TranscriptBlockPosition
    ) -> [BlockPiece] {
        var chunks: [[MarkdownInline]] = []
        var current: [MarkdownInline] = []
        var currentBytes = 0

        func flush() {
            guard !current.isEmpty else { return }
            chunks.append(current)
            current.removeAll(keepingCapacity: true)
            currentBytes = 0
        }

        for inline in inlines {
            let text = inline.text
            let utf8 = text.utf8
            var start = utf8.startIndex
            while start < utf8.endIndex {
                let remaining = utf8.distance(from: start, to: utf8.endIndex)
                let budget = maxParagraphBytes - currentBytes
                if remaining <= budget {
                    var piece = inline
                    piece.text = start == utf8.startIndex ? text : String(text[start..<utf8.endIndex])
                    current.append(piece)
                    currentBytes &+= remaining
                    break
                }
                if budget < 256 && !current.isEmpty {
                    flush()
                    continue
                }
                let cut = findSplitIndex(in: text, from: start, maxBytes: max(1, budget))
                var piece = inline
                piece.text = String(text[start..<cut])
                if !piece.text.isEmpty {
                    current.append(piece)
                }
                flush()
                start = cut
            }
        }
        flush()
        guard chunks.count > 1 else {
            return [BlockPiece(block: .paragraph(inlines), position: outer, joinsWithoutNewline: false)]
        }
        return chunks.enumerated().map { index, chunk in
            let pos = TranscriptBlockPosition(
                isFirst: index == 0 && outer.isFirst,
                isLast: index == chunks.count - 1 && outer.isLast,
                joinsAbove: index > 0 || outer.joinsAbove,
                joinsBelow: index < chunks.count - 1 || outer.joinsBelow)
            return BlockPiece(block: .paragraph(chunk), position: pos, joinsWithoutNewline: index > 0)
        }
    }

    private static func splitList(_ list: MarkdownList, outer: TranscriptBlockPosition) -> [BlockPiece] {
        var chunks: [MarkdownList] = []
        var offset = 0
        while offset < list.items.count {
            let end = min(list.items.count, offset + maxListItems)
            let slice = Array(list.items[offset..<end])
            let startIndex = list.startIndex.map { $0 + offset }
            chunks.append(MarkdownList(startIndex: startIndex, items: slice))
            offset = end
        }
        return chunks.enumerated().map { index, chunk in
            let pos = TranscriptBlockPosition(
                isFirst: index == 0 && outer.isFirst,
                isLast: index == chunks.count - 1 && outer.isLast,
                joinsAbove: index > 0 || outer.joinsAbove,
                joinsBelow: index < chunks.count - 1 || outer.joinsBelow)
            return BlockPiece(block: .list(chunk), position: pos, joinsWithoutNewline: false)
        }
    }

    // MARK: Plain-text splitting (user messages & thoughts)

    private struct TextPiece {
        let text: String
        let joinsWithoutNewline: Bool
    }

    private static func exceedsTextLimit(_ text: String, maxBytes: Int, maxLines: Int) -> Bool {
        if text.utf8.count > maxBytes { return true }
        var lines = 1
        for byte in text.utf8 where byte == 0x0A {
            lines &+= 1
            if lines > maxLines { return true }
        }
        return false
    }

    private static func splitPlainText(_ text: String, maxBytes: Int, maxLines: Int) -> [TextPiece] {
        var pieces: [TextPiece] = []
        let utf8 = text.utf8
        var start = utf8.startIndex
        var nextJoinsWithoutNewline = false

        while start < utf8.endIndex {
            var cursor = start
            var lines = 1
            var lastNewline: String.Index?
            var lastSpaceAfter: String.Index?
            var bytes = 0
            while cursor < utf8.endIndex {
                let byte = utf8[cursor]
                if byte == 0x0A {
                    lastNewline = cursor
                    lines &+= 1
                    if lines > maxLines { break }
                } else if byte == 0x20 || byte == 0x09 {
                    let after = utf8.index(after: cursor)
                    lastSpaceAfter = after
                }
                bytes &+= 1
                utf8.formIndex(after: &cursor)
                if bytes >= maxBytes { break }
            }
            if cursor >= utf8.endIndex {
                pieces.append(TextPiece(text: String(text[start..<utf8.endIndex]), joinsWithoutNewline: nextJoinsWithoutNewline))
                break
            }
            if let nl = lastNewline {
                pieces.append(TextPiece(text: String(text[start..<nl]), joinsWithoutNewline: nextJoinsWithoutNewline))
                start = utf8.index(after: nl)
                nextJoinsWithoutNewline = false
                // Preserve a trailing newline when it sits right on the maxLines boundary.
                if start == utf8.endIndex {
                    pieces.append(TextPiece(text: "", joinsWithoutNewline: false))
                }
            } else if let spaceAfter = lastSpaceAfter, spaceAfter > start {
                pieces.append(TextPiece(text: String(text[start..<spaceAfter]), joinsWithoutNewline: nextJoinsWithoutNewline))
                start = spaceAfter
                nextJoinsWithoutNewline = true
            } else {
                let cut = snapToCharacterBoundary(in: text, from: start, candidate: cursor)
                pieces.append(TextPiece(text: String(text[start..<cut]), joinsWithoutNewline: nextJoinsWithoutNewline))
                start = cut
                nextJoinsWithoutNewline = true
            }
        }
        return pieces
    }

    /// Finds a clean split index in `text` starting at `start` within `maxBytes`,
    /// preferring right after a newline or space, falling back to an extended
    /// grapheme cluster (`Character`) boundary so surrogate pairs, ZWJ emoji,
    /// and combining marks are never split.
    private static func findSplitIndex(in text: String, from start: String.Index, maxBytes: Int) -> String.Index {
        let utf8 = text.utf8
        let limit = utf8.index(start, offsetBy: maxBytes, limitedBy: utf8.endIndex) ?? utf8.endIndex
        guard limit < utf8.endIndex else { return utf8.endIndex }

        var scan = limit
        let minScan = utf8.index(start, offsetBy: maxBytes / 2, limitedBy: limit) ?? start
        var lastSpaceAfter: String.Index?
        while scan > minScan {
            let prev = utf8.index(before: scan)
            let byte = utf8[prev]
            if byte == 0x0A {
                return scan
            }
            if lastSpaceAfter == nil && (byte == 0x20 || byte == 0x09) {
                lastSpaceAfter = scan
            }
            scan = prev
        }
        if let lastSpaceAfter { return lastSpaceAfter }
        return snapToCharacterBoundary(in: text, from: start, candidate: limit)
    }

    /// Snaps `candidate` to a valid `Character` (extended grapheme cluster)
    /// boundary strictly after `start`.
    private static func snapToCharacterBoundary(
        in text: String, from start: String.Index, candidate: String.Index
    ) -> String.Index {
        let utf8 = text.utf8
        // Step back to a UTF-8 scalar boundary first.
        var idx = candidate
        while idx > start, idx.samePosition(in: text.unicodeScalars) == nil {
            utf8.formIndex(before: &idx)
        }
        // Then snap to a Character boundary (`rangeOfComposedCharacterSequence`
        // equivalent in pure Swift String indexing).
        let charIdx = text.index(idx, offsetBy: 0)
        if charIdx > start && charIdx <= candidate {
            return charIdx
        }
        // Single grapheme cluster exceeds `maxBytes`: advance past one full Character.
        let startChar = text.index(start, offsetBy: 0)
        return startChar < text.endIndex ? text.index(after: startChar) : text.endIndex
    }
}
