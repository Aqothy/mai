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
                        joinsPreviousWithoutNewline: piece.joinsWithoutNewline))
                rowIndex += 1
            }
        }
        return rows
    }

    /// Splits an oversized user message into bounded bubble rows sharing
    /// `sourceID = messageID`. Normal prompts produce one row with id
    /// `"user|\(messageID)"`.
    static func userRows(messageID: String, turnID: String?, source: String) -> [TranscriptRow] {
        guard exceedsTextLimit(source, maxBytes: maxUserMessageBytes, maxLines: maxUserMessageLines) else {
            return [
                TranscriptRow(
                    id: "user|\(messageID)", sourceID: messageID,
                    kind: .userMessage(source: source, position: .single),
                    messageID: messageID, role: .user, turnID: turnID)
            ]
        }
        let pieces = splitPlainText(source, maxBytes: maxUserMessageBytes, maxLines: maxUserMessageLines)
        return pieces.enumerated().map { index, piece in
            let position = TranscriptBlockPosition(
                isFirst: index == 0, isLast: index == pieces.count - 1,
                joinsAbove: index > 0, joinsBelow: index < pieces.count - 1)
            let rowID = index == 0 ? "user|\(messageID)" : "user|\(messageID)#\(index)"
            return TranscriptRow(
                id: rowID, sourceID: messageID,
                kind: .userMessage(source: piece.text, position: position),
                messageID: messageID, role: .user, turnID: turnID,
                joinsPreviousWithoutNewline: piece.joinsWithoutNewline)
        }
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
                joinsPreviousWithoutNewline: piece.joinsWithoutNewline)
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
        var chunks: [String] = []
        let utf8 = code.utf8
        var chunkStart = utf8.startIndex
        var cursor = utf8.startIndex
        var chunkBytes = 0
        var chunkLines = 0

        while cursor < utf8.endIndex {
            var lineEnd = cursor
            while lineEnd < utf8.endIndex, utf8[lineEnd] != 0x0A {
                utf8.formIndex(after: &lineEnd)
            }
            let lineBytes = utf8.distance(from: cursor, to: lineEnd)
            let hasNewline = lineEnd < utf8.endIndex
            if chunkLines > 0 && (chunkLines >= maxCodeLines || chunkBytes + lineBytes + 1 > maxCodeBytes) {
                // End chunk right before the `\n` that preceded `cursor`.
                let prevEnd = utf8.index(before: cursor)
                chunks.append(String(code[chunkStart..<prevEnd]))
                chunkStart = cursor
                chunkBytes = 0
                chunkLines = 0
            }
            chunkLines &+= 1
            chunkBytes &+= lineBytes + (hasNewline ? 1 : 0)
            cursor = hasNewline ? utf8.index(after: lineEnd) : lineEnd
        }
        if chunkStart < utf8.endIndex || chunks.isEmpty {
            chunks.append(String(code[chunkStart..<utf8.endIndex]))
        }
        if chunks.count <= 1 {
            return [BlockPiece(block: .code(language: language, code: code), position: outer, joinsWithoutNewline: false)]
        }
        return chunks.enumerated().map { index, chunk in
            let pos = TranscriptBlockPosition(
                isFirst: index == 0 && outer.isFirst,
                isLast: index == chunks.count - 1 && outer.isLast,
                joinsAbove: index > 0 || outer.joinsAbove,
                joinsBelow: index < chunks.count - 1 || outer.joinsBelow)
            return BlockPiece(block: .code(language: language, code: chunk), position: pos, joinsWithoutNewline: false)
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
