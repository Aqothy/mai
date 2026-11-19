import CoreGraphics
import Foundation

/// Makes a streaming tail's unfinished syntax render sensibly. Only the
/// displayed copy changes; the message's source is never touched and is
/// parsed as written once the stream ends. Covers common model output, not
/// all of CommonMark (the behavior of the chat's earlier repairer, rewritten).
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
        for delimiter in ["~~", "**", "__", "*", "_"] { balance(delimiter, in: &text) }
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
        let paragraph = trailingParagraphStart(of: text)
        let ticks = backticks(in: text)
        var searchEnd = text.endIndex
        while let open = text[paragraph..<searchEnd].lastIndex(of: "[") {
            searchEnd = open
            if open > text.startIndex, text[text.index(before: open)] == "!" { continue }
            if isEscaped(open, in: text) || isInsideInlineCode(open, backticks: ticks) { continue }
            let labelStart = text.index(after: open)
            guard let close = text[labelStart...].firstIndex(of: "]") else {
                text.remove(at: open)
                return true
            }
            let destination = text.index(after: close)
            guard destination < text.endIndex, text[destination] == "(",
                !hasMatchingParenthesis(in: text, from: destination)
            else { continue }
            text.replaceSubrange(open..., with: String(text[labelStart..<close]))
            return true
        }
        return false
    }

    private static func simplifyIncompleteAutolink(_ text: inout String) {
        let paragraph = trailingParagraphStart(of: text)
        guard let open = text[paragraph...].lastIndex(of: "<"),
            !text[open...].contains(">")
        else { return }
        let destination = text[text.index(after: open)...].lowercased()
        guard ["https://", "http://", "mailto:"].contains(where: { destination.hasPrefix($0) }) else { return }
        text.remove(at: open)
    }

    private static func hasMatchingParenthesis(in text: String, from open: String.Index) -> Bool {
        var depth = 0
        var cursor = open
        while cursor < text.endIndex {
            if !isEscaped(cursor, in: text) {
                if text[cursor] == "(" { depth += 1 }
                if text[cursor] == ")" {
                    depth -= 1
                    if depth == 0 { return true }
                }
            }
            cursor = text.index(after: cursor)
        }
        return false
    }

    // MARK: Inline code, block markers, emphasis

    /// An unclosed backtick run in the last paragraph is closed, or dropped
    /// when nothing follows it yet.
    private static func closeOpenInlineCode(_ text: inout String) {
        var open: [Int: String.Index] = [:]
        var cursor = trailingParagraphStart(of: text)
        while cursor < text.endIndex {
            guard text[cursor] == "`", !isEscaped(cursor, in: text) else {
                cursor = text.index(after: cursor)
                continue
            }
            let start = cursor
            var length = 0
            while cursor < text.endIndex, text[cursor] == "`" {
                length += 1
                cursor = text.index(after: cursor)
            }
            open[length] = open[length] == nil ? start : nil
        }
        guard let (length, start) = open.max(by: { $0.value < $1.value }) else { return }
        let contentStart = text.index(start, offsetBy: length)
        if text[contentStart...].contains(where: { !$0.isWhitespace }) {
            text += String(repeating: "`", count: length)
        } else {
            text.removeSubrange(start..<contentStart)
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

    /// An odd delimiter count means one is unclosed: dropped when nothing
    /// follows it, closed when a word does.
    private static func balance(_ delimiter: String, in text: inout String) {
        let ranges = delimiterRanges(delimiter, in: text)
        guard ranges.count % 2 == 1, let last = ranges.last else { return }
        let suffix = text[last.upperBound...]
        if suffix.isEmpty {
            text.removeSubrange(last)
        } else if let first = suffix.first, !first.isWhitespace, !suffix.contains("\n"),
            delimiterRanges("`", in: String(suffix)).count % 2 == 0
        {
            text += delimiter
        }
    }

    private static func delimiterRanges(_ delimiter: String, in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        let ticks = backticks(in: text)
        var cursor = text.startIndex
        while cursor < text.endIndex, let range = text.range(of: delimiter, range: cursor..<text.endIndex) {
            cursor = range.upperBound
            guard !isEscaped(range.lowerBound, in: text), !isInsideInlineCode(range.lowerBound, backticks: ticks)
            else { continue }
            if delimiter.count == 1 {
                // `*` inside `**` belongs to the double delimiter.
                let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
                let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
                if before.map(String.init) == delimiter || after.map(String.init) == delimiter { continue }
            }
            result.append(range)
        }
        return result
    }

    // MARK: Helpers

    private static func trailingParagraphStart(of text: String) -> String.Index {
        text.range(of: "\n\n", options: .backwards)?.upperBound ?? text.startIndex
    }

    /// The unescaped backticks of the last paragraph, in order: found once
    /// per pass and searched, since a long paragraph has hundreds of
    /// delimiters to check.
    private static func backticks(in text: String) -> [String.Index] {
        var result: [String.Index] = []
        var cursor = trailingParagraphStart(of: text)
        while cursor < text.endIndex {
            if text[cursor] == "`", !isEscaped(cursor, in: text) { result.append(cursor) }
            cursor = text.index(after: cursor)
        }
        return result
    }

    /// Inside inline code: an odd number of the last paragraph's backticks
    /// come before `index`.
    private static func isInsideInlineCode(_ index: String.Index, backticks: [String.Index]) -> Bool {
        var low = 0
        var high = backticks.count
        while low < high {
            let middle = (low + high) / 2
            if backticks[middle] < index { low = middle + 1 } else { high = middle }
        }
        return low % 2 == 1
    }

    private static func isEscaped(_ index: String.Index, in text: String) -> Bool {
        var cursor = index
        var slashes = 0
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            guard text[previous] == "\\" else { break }
            slashes += 1
            cursor = previous
        }
        return slashes % 2 == 1
    }
}
