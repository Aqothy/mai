import CoreGraphics
import Foundation

/// Makes a streaming tail's unfinished syntax render sensibly. Only the
/// displayed copy changes; the message's source is never touched and is
/// parsed as written once the stream ends. Covers common model output, not
/// all of CommonMark.
nonisolated enum MarkdownTailHealer {
    /// The tail's blocks while it streams.
    static func blocks(forOpenTail tail: String) -> [MarkdownBlock] {
        guard tail.contains(where: { !$0.isWhitespace }) else { return [] }
        // An open fence owns the rest of the tail, so punctuation inside it
        // stays literal. A fence that opens the tail is the whole tail: no
        // parse needed while code streams.
        if let fence = openFence(in: tail) {
            if fence.isFirstBlock {
                var code = String(tail[fence.contentStart...])
                if code.hasSuffix("\n") { code.removeLast() }
                return [.code(language: fence.language, code: code)]
            }
            return MarkdownPlanner.locatedBlocks(from: tail).map(\.block)
        }
        return MarkdownPlanner.locatedBlocks(from: healed(tail)).map(\.block)
    }

    static func healed(_ tail: String) -> String {
        var text = tail
        completePartialTableDelimiter(&text)
        if !simplifyIncompleteLink(&text) { simplifyIncompleteAutolink(&text) }
        closeOpenInlineCode(&text)
        dropTrailingBlockMarker(&text)
        balanceEmphasis(&text)
        return text
    }

    // MARK: Fences

    private struct OpenFence {
        let contentStart: String.Index
        let language: String?
        let isFirstBlock: Bool
    }

    private static func openFence(in source: String) -> OpenFence? {
        var open: (marker: Character, length: Int, fence: OpenFence)?
        var lineStart = source.startIndex
        while lineStart < source.endIndex {
            let lineEnd = source[lineStart...].firstIndex(of: "\n") ?? source.endIndex
            let line = source[lineStart..<lineEnd]
            let indent = line.prefix { $0 == " " }.count
            let body = line.dropFirst(indent)
            if indent < 4, let marker = body.first, marker == "`" || marker == "~" {
                let length = body.prefix { $0 == marker }.count
                let rest = body.dropFirst(length)
                if length >= 3 {
                    if let current = open {
                        if marker == current.marker, length >= current.length,
                            rest.allSatisfy(\.isWhitespace)
                        {
                            open = nil
                        }
                    } else if marker != "`" || !rest.contains("`") {
                        let language = rest.trimmingCharacters(in: .whitespaces)
                        let contentStart = lineEnd < source.endIndex ? source.index(after: lineEnd) : lineEnd
                        open = (
                            marker, length,
                            OpenFence(
                                contentStart: contentStart, language: language.isEmpty ? nil : language,
                                isFirstBlock: source[..<lineStart].allSatisfy(\.isWhitespace))
                        )
                    }
                }
            }
            lineStart = lineEnd < source.endIndex ? source.index(after: lineEnd) : source.endIndex
        }
        return open?.fence
    }

    // MARK: Tables

    /// A header and a partly typed delimiter row are enough to show a table:
    /// the missing delimiter cells are filled in.
    private static func completePartialTableDelimiter(_ text: inout String) {
        guard let lastBreak = text.lastIndex(of: "\n") else { return }
        let delimiterStart = text.index(after: lastBreak)
        let headerStart = text[..<lastBreak].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let headerCells = cells(in: text[headerStart..<lastBreak])
        let delimiter = text[delimiterStart...].trimmingCharacters(in: .whitespaces)
        guard headerCells.count >= 2, delimiter.contains("|"), delimiter.contains("-"),
            delimiter.allSatisfy({ "|:-".contains($0) || $0.isWhitespace })
        else { return }
        let typed = cells(in: Substring(delimiter))
        let isComplete =
            typed.count == headerCells.count && typed.allSatisfy { $0.filter { $0 == "-" }.count >= 3 }
        guard !isComplete else { return }
        let filled = headerCells.indices.map { column -> String in
            let partial = typed.indices.contains(column) ? typed[column].trimmingCharacters(in: .whitespaces) : ""
            return (partial.hasPrefix(":") ? ":" : "") + "---" + (partial.count > 1 && partial.hasSuffix(":") ? ":" : "")
        }
        text.replaceSubrange(delimiterStart..., with: "| " + filled.joined(separator: " | ") + " |")
    }

    private static func cells(in line: Substring) -> [Substring] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false)
        if cells.first?.allSatisfy(\.isWhitespace) == true { cells.removeFirst() }
        if cells.last?.allSatisfy(\.isWhitespace) == true { cells.removeLast() }
        return cells
    }

    // MARK: Links

    /// `[label](partial` shows as its label; a lone `[` is dropped.
    @discardableResult
    private static func simplifyIncompleteLink(_ text: inout String) -> Bool {
        let utf8 = text.utf8
        let paragraph = trailingParagraphStart(of: text)
        let codeSpans = inlineCodeSpans(in: utf8, from: paragraph)
        var searchEnd = utf8.endIndex
        while let open = lastByte(UInt8(ascii: "["), in: utf8, from: paragraph, before: searchEnd) {
            searchEnd = open
            if open > utf8.startIndex, utf8[utf8.index(before: open)] == UInt8(ascii: "!") { continue }
            if isEscaped(open, in: utf8) || isInside(open, spans: codeSpans) { continue }
            let labelStart = utf8.index(after: open)
            guard let close = firstByte(UInt8(ascii: "]"), in: utf8, from: labelStart) else {
                text.remove(at: open)
                return true
            }
            let destination = utf8.index(after: close)
            guard destination < utf8.endIndex, utf8[destination] == UInt8(ascii: "("),
                !hasMatchingParenthesis(in: utf8, from: destination)
            else { continue }
            text.replaceSubrange(open..., with: String(text[labelStart..<close]))
            return true
        }
        return false
    }

    private static func simplifyIncompleteAutolink(_ text: inout String) {
        let utf8 = text.utf8
        let paragraph = trailingParagraphStart(of: text)
        guard let open = lastByte(UInt8(ascii: "<"), in: utf8, from: paragraph, before: utf8.endIndex),
            firstByte(UInt8(ascii: ">"), in: utf8, from: open) == nil
        else { return }
        let destination = text[utf8.index(after: open)...].lowercased()
        guard ["https://", "http://", "mailto:"].contains(where: { destination.hasPrefix($0) }) else { return }
        text.remove(at: open)
    }

    private static func hasMatchingParenthesis(in utf8: String.UTF8View, from open: String.Index) -> Bool {
        var depth = 0
        var cursor = open
        while cursor < utf8.endIndex {
            let byte = utf8[cursor]
            if (byte == UInt8(ascii: "(") || byte == UInt8(ascii: ")")), !isEscaped(cursor, in: utf8) {
                if byte == UInt8(ascii: "(") {
                    depth += 1
                } else {
                    depth -= 1
                    if depth == 0 { return true }
                }
            }
            utf8.formIndex(after: &cursor)
        }
        return false
    }

    // MARK: Inline code, block markers, emphasis

    /// An unclosed backtick run in the last paragraph is closed, or dropped
    /// when nothing follows it yet. Scans sequentially using CommonMark's
    /// backtick-matching rule so inner backticks inside multi-backtick code
    /// spans and trailing backslashes (`\` inside code) never mismatch.
    private static func closeOpenInlineCode(_ text: inout String) {
        let utf8 = text.utf8
        var cursor = trailingParagraphStart(of: text)
        while cursor < utf8.endIndex {
            guard utf8[cursor] == UInt8(ascii: "`"), !isEscaped(cursor, in: utf8) else {
                utf8.formIndex(after: &cursor)
                continue
            }
            let start = cursor
            var length = 0
            while cursor < utf8.endIndex, utf8[cursor] == UInt8(ascii: "`") {
                length += 1
                utf8.formIndex(after: &cursor)
            }
            if let closeEnd = matchingBacktickClose(in: utf8, from: cursor, length: length) {
                cursor = closeEnd
                continue
            }
            if text[cursor...].contains(where: { !$0.isWhitespace }) {
                text += String(repeating: "`", count: length)
            } else {
                text.removeSubrange(start..<cursor)
            }
            return
        }
    }

    /// A line holding only a block marker (`#`, `>`, `-`, `1.`, `|`) would
    /// render as an empty heading, quote or item; it waits for its text.
    private static func dropTrailingBlockMarker(_ text: inout String) {
        let lineStart = text.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let marker = text[lineStart...].trimmingCharacters(in: .whitespaces)
        guard !marker.isEmpty else { return }
        let isHeading = marker.count <= 6 && marker.allSatisfy { $0 == "#" }
        let isQuote = marker.allSatisfy { $0 == ">" }
        let isBullet = ["-", "+", "*", "|"].contains(marker)
        let isOrdered =
            (marker.last == "." || marker.last == ")") && marker.count > 1
            && marker.dropLast().allSatisfy(\.isNumber)
        if isHeading || isQuote || isBullet || isOrdered { text.removeSubrange(lineStart...) }
    }

    /// An odd count of a delimiter means its last one is unclosed: dropped
    /// when nothing follows it (with the unclosed ones it touches, so `***`
    /// goes whole), closed when a word follows on its line. One pass over the
    /// trailing paragraph; code spans and intra-word `_`, which CommonMark
    /// never reads as emphasis, don't count.
    private static func balanceEmphasis(_ text: inout String) {
        enum Kind: Int, CaseIterable {
            case tilde2 = 0, star2, under2, star1, under1
            var string: String {
                switch self {
                case .tilde2: "~~"
                case .star2: "**"
                case .under2: "__"
                case .star1: "*"
                case .under1: "_"
                }
            }
        }
        var counts = [0, 0, 0, 0, 0]
        // Store UTF-8 byte offsets (never `String.Index`) so subsequent
        // mutations to `text` never use invalidated indices.
        var lastRanges: [Range<Int>?] = [nil, nil, nil, nil, nil]

        let utf8 = text.utf8
        let totalBytes = utf8.count
        let start = trailingParagraphStart(of: text)
        var cursor = start
        var byteOffset = utf8.distance(from: utf8.startIndex, to: start)
        while cursor < utf8.endIndex {
            let byte = utf8[cursor]
            if byte == UInt8(ascii: "\\") {
                utf8.formIndex(after: &cursor)
                byteOffset += 1
                if cursor < utf8.endIndex {
                    utf8.formIndex(after: &cursor)
                    byteOffset += 1
                }
                continue
            }
            // Skip balanced inline-code spans in one jump (unclosed backticks
            // were already closed or dropped by `closeOpenInlineCode`).
            if byte == UInt8(ascii: "`") {
                var runEnd = cursor
                var runLength = 0
                while runEnd < utf8.endIndex, utf8[runEnd] == UInt8(ascii: "`") {
                    runLength += 1
                    utf8.formIndex(after: &runEnd)
                }
                if let closeEnd = matchingBacktickClose(in: utf8, from: runEnd, length: runLength) {
                    byteOffset += utf8.distance(from: cursor, to: closeEnd)
                    cursor = closeEnd
                } else {
                    byteOffset += runLength
                    cursor = runEnd
                }
                continue
            }
            if byte == UInt8(ascii: "~") {
                let runStartByte = byteOffset
                var runLength = 0
                while cursor < utf8.endIndex, utf8[cursor] == byte {
                    runLength += 1
                    utf8.formIndex(after: &cursor)
                }
                byteOffset += runLength
                var offset = runStartByte
                for _ in 0..<(runLength / 2) {
                    counts[Kind.tilde2.rawValue] += 1
                    lastRanges[Kind.tilde2.rawValue] = offset..<(offset + 2)
                    offset += 2
                }
                continue
            }
            if byte == UInt8(ascii: "*") || byte == UInt8(ascii: "_") {
                let runStart = cursor
                let runStartByte = byteOffset
                var runLength = 0
                while cursor < utf8.endIndex, utf8[cursor] == byte {
                    runLength += 1
                    utf8.formIndex(after: &cursor)
                }
                byteOffset += runLength
                if byte == UInt8(ascii: "_") {
                    let beforeWord = runStart > utf8.startIndex && isASCIIWord(utf8[utf8.index(before: runStart)])
                    let afterWord = cursor < utf8.endIndex && isASCIIWord(utf8[cursor])
                    // CommonMark forbids intra-word `_`/`__` from opening or
                    // closing emphasis (e.g. `foo_bar`).
                    if beforeWord && afterWord { continue }
                }
                let doubleKind: Kind = byte == UInt8(ascii: "*") ? .star2 : .under2
                let singleKind: Kind = byte == UInt8(ascii: "*") ? .star1 : .under1
                var offset = runStartByte
                for _ in 0..<(runLength / 2) {
                    counts[doubleKind.rawValue] += 1
                    lastRanges[doubleKind.rawValue] = offset..<(offset + 2)
                    offset += 2
                }
                if runLength % 2 == 1 {
                    counts[singleKind.rawValue] += 1
                    lastRanges[singleKind.rawValue] = offset..<(offset + 1)
                }
                continue
            }
            utf8.formIndex(after: &cursor)
            byteOffset += 1
        }

        // Apply fixes using UTF-8 offsets: drop any unclosed delimiter(s)
        // touching the end (including `***`), then close earlier unclosed
        // openers innermost-first when non-whitespace text follows on the line.
        var dropFromByte = totalBytes
        var toClose: [(lowerByte: Int, upperByte: Int, kind: Kind)] = []
        var oddOpeners: [(lowerByte: Int, upperByte: Int, kind: Kind)] = []
        for kind in Kind.allCases where counts[kind.rawValue] % 2 == 1 {
            if let range = lastRanges[kind.rawValue] {
                oddOpeners.append((range.lowerBound, range.upperBound, kind))
            }
        }
        oddOpeners.sort { $0.upperByte > $1.upperByte }
        for opener in oddOpeners {
            if opener.upperByte == dropFromByte {
                dropFromByte = min(dropFromByte, opener.lowerByte)
            } else {
                toClose.append(opener)
            }
        }
        if dropFromByte < totalBytes {
            let cut = text.utf8.index(text.utf8.startIndex, offsetBy: dropFromByte)
            text.removeSubrange(cut...)
        }
        toClose.sort { $0.lowerByte > $1.lowerByte }
        for opener in toClose {
            let currentBytes = text.utf8.count
            guard opener.upperByte <= currentBytes else { continue }
            let upper = text.utf8.index(text.utf8.startIndex, offsetBy: opener.upperByte)
            let suffix = text[upper...]
            if suffix.isEmpty {
                let lower = text.utf8.index(text.utf8.startIndex, offsetBy: opener.lowerByte)
                text.removeSubrange(lower..<upper)
            } else if let first = suffix.first, !first.isWhitespace, !suffix.utf8.contains(0x0A) {
                text += opener.kind.string
            }
        }
    }

    // MARK: Helpers

    private static func trailingParagraphStart(of text: String) -> String.Index {
        text.range(of: "\n\n", options: .backwards)?.upperBound ?? text.startIndex
    }

    /// Balanced inline-code ranges `[open..<closeEnd]` from `start`.
    private static func inlineCodeSpans(in utf8: String.UTF8View, from start: String.Index) -> [Range<String.Index>] {
        var spans: [Range<String.Index>] = []
        var cursor = start
        while cursor < utf8.endIndex {
            if utf8[cursor] == UInt8(ascii: "`"), !isEscaped(cursor, in: utf8) {
                let open = cursor
                var length = 0
                while cursor < utf8.endIndex, utf8[cursor] == UInt8(ascii: "`") {
                    length += 1
                    utf8.formIndex(after: &cursor)
                }
                if let closeEnd = matchingBacktickClose(in: utf8, from: cursor, length: length) {
                    spans.append(open..<closeEnd)
                    cursor = closeEnd
                }
                continue
            }
            utf8.formIndex(after: &cursor)
        }
        return spans
    }

    private static func matchingBacktickClose(
        in utf8: String.UTF8View, from start: String.Index, length: Int
    ) -> String.Index? {
        var cursor = start
        while cursor < utf8.endIndex {
            if utf8[cursor] == UInt8(ascii: "`") {
                var runEnd = cursor
                var count = 0
                while runEnd < utf8.endIndex, utf8[runEnd] == UInt8(ascii: "`") {
                    count += 1
                    utf8.formIndex(after: &runEnd)
                }
                if count == length { return runEnd }
                cursor = runEnd
                continue
            }
            utf8.formIndex(after: &cursor)
        }
        return nil
    }

    private static func isInside(_ index: String.Index, spans: [Range<String.Index>]) -> Bool {
        var low = 0
        var high = spans.count
        while low < high {
            let middle = (low + high) / 2
            if spans[middle].upperBound <= index { low = middle + 1 } else { high = middle }
        }
        return low < spans.count && spans[low].lowerBound <= index
    }

    private static func firstByte(_ target: UInt8, in utf8: String.UTF8View, from start: String.Index) -> String.Index? {
        var cursor = start
        while cursor < utf8.endIndex {
            if utf8[cursor] == target { return cursor }
            utf8.formIndex(after: &cursor)
        }
        return nil
    }

    private static func lastByte(
        _ target: UInt8, in utf8: String.UTF8View, from start: String.Index? = nil, before end: String.Index
    ) -> String.Index? {
        let lower = start ?? utf8.startIndex
        var cursor = end
        while cursor > lower {
            utf8.formIndex(before: &cursor)
            if utf8[cursor] == target { return cursor }
        }
        return nil
    }

    private static func isEscaped(_ index: String.Index, in utf8: String.UTF8View) -> Bool {
        var cursor = index
        var slashes = 0
        while cursor > utf8.startIndex {
            utf8.formIndex(before: &cursor)
            guard utf8[cursor] == UInt8(ascii: "\\") else { break }
            slashes += 1
        }
        return slashes % 2 == 1
    }

    private static func isASCIIWord(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
    }
}
