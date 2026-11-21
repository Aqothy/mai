import CoreGraphics
import Foundation

/// How much of a streaming Markdown tail is final: the UTF-8 length of the
/// prefix whose blocks no later text can change, so they can be parsed once
/// and appended as rows. Conservative by design (the rule from rill's
/// `CommitBoundary`, PLAN 3.5): a block is final after a blank line that
/// follows closed content, after its closing fence, or, for a heading or
/// thematic break, at its own newline. The last paragraph, list or table
/// stays open, since a later line could extend it. Every boundary is at a
/// line start, so a committed prefix parses alone exactly as it would in
/// place.
nonisolated enum MarkdownCommitBoundary {
    static func committedLength(of bytes: [UInt8]) -> Int {
        let lines = Line.split(bytes)
        var committed = 0
        var regionStart = true
        var regionHasList = false
        var regionIsIndentedCode = false
        var fence: Fence?
        var fenceOpenedAtRegionStart = false
        var htmlEnd: [UInt8]?

        var index = 0
        while index < lines.count {
            let line = lines[index]
            defer { index += 1 }
            // The last, partial line can still become anything.
            guard line.isTerminated else { break }
            let content = line.content(in: bytes)

            if let open = fence {
                if open.isClosed(by: content, indent: line.indent) {
                    fence = nil
                    if fenceOpenedAtRegionStart {
                        committed = line.end
                        regionStart = true
                    }
                }
                continue
            }
            if let end = htmlEnd {
                if Self.containsASCIICaseInsensitive(content, needle: end) { htmlEnd = nil }
                continue
            }
            if line.isBlank {
                if regionStart {
                    committed = line.end
                    continue
                }
                if regionHasList || regionIsIndentedCode {
                    // A blank line inside a list may separate loose items,
                    // and one inside indented code belongs to the code: only
                    // a following line that cannot continue the block closes it.
                    guard let next = lines[(index + 1)...].first(where: { !$0.isBlank }),
                        next.isTerminated
                    else { break }
                    let nextContent = next.content(in: bytes)
                    let continues =
                        regionIsIndentedCode
                        ? next.indent >= 4
                        : next.indent > 0 || Self.startsListItem(nextContent)
                    guard !continues else { continue }
                }
                committed = line.end
                regionStart = true
                regionHasList = false
                regionIsIndentedCode = false
                continue
            }
            if line.indent < 4, let opened = Fence(opening: content) {
                fence = opened
                fenceOpenedAtRegionStart = regionStart
                regionStart = false
                continue
            }
            if line.indent < 4, let end = Self.htmlBlockEnd(opening: content) {
                if !Self.containsASCIICaseInsensitive(content.dropFirst(1), needle: end) { htmlEnd = end }
                regionStart = false
                continue
            }
            if regionStart, line.indent < 4, Self.isSingleLineBlock(content) {
                committed = line.end
                continue
            }
            if regionStart, line.indent >= 4 { regionIsIndentedCode = true }
            if line.indent < 4, Self.startsListItem(content) { regionHasList = true }
            regionStart = false
        }
        return committed
    }

    // MARK: Recognizers

    /// An ATX heading or a thematic break: complete at its newline.
    private static func isSingleLineBlock(_ content: ArraySlice<UInt8>) -> Bool {
        let hashes = content.prefix { $0 == UInt8(ascii: "#") }.count
        if (1...6).contains(hashes) {
            let rest = content.dropFirst(hashes)
            return rest.isEmpty || rest.first == UInt8(ascii: " ") || rest.first == UInt8(ascii: "\t")
        }
        var marker: UInt8?
        var count = 0
        for byte in content where byte != UInt8(ascii: " ") && byte != UInt8(ascii: "\t") {
            guard byte == UInt8(ascii: "-") || byte == UInt8(ascii: "*") || byte == UInt8(ascii: "_"),
                marker == nil || marker == byte
            else { return false }
            marker = byte
            count += 1
        }
        return count >= 3
    }

    static func startsListItem(_ content: ArraySlice<UInt8>) -> Bool {
        guard let first = content.first else { return false }
        func endsMarker(_ rest: ArraySlice<UInt8>) -> Bool {
            rest.isEmpty || rest.first == UInt8(ascii: " ") || rest.first == UInt8(ascii: "\t")
        }
        if first == UInt8(ascii: "-") || first == UInt8(ascii: "*") || first == UInt8(ascii: "+") {
            return endsMarker(content.dropFirst())
        }
        let digits = content.prefix { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }.count
        guard (1...9).contains(digits) else { return false }
        let rest = content.dropFirst(digits)
        guard let punctuation = rest.first,
            punctuation == UInt8(ascii: ".") || punctuation == UInt8(ascii: ")")
        else { return false }
        return endsMarker(rest.dropFirst())
    }

    /// The end marker of an HTML block that can span blank lines (CommonMark
    /// types 1 and 2); other HTML blocks end at a blank line like a paragraph.
    private static func htmlBlockEnd(opening content: ArraySlice<UInt8>) -> [UInt8]? {
        guard content.first == UInt8(ascii: "<") else { return nil }
        let text = String(decoding: content.prefix(10), as: UTF8.self).lowercased()
        if text.hasPrefix("<!--") { return Array("-->".utf8) }
        for tag in ["pre", "script", "style", "textarea"] where text.hasPrefix("<\(tag)") {
            let after = text.dropFirst(tag.count + 1).first
            if after == nil || after == ">" || after == " " || after == "\t" { return Array("</\(tag)>".utf8) }
        }
        return nil
    }

    /// Whether `haystack` holds `needle` (lowercase ASCII) in any letter case:
    /// CommonMark matches HTML block end conditions case-insensitively.
    private static func containsASCIICaseInsensitive(_ haystack: ArraySlice<UInt8>, needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        var start = haystack.startIndex
        while start <= haystack.endIndex - needle.count {
            var matches = true
            for offset in needle.indices {
                var byte = haystack[start + offset]
                if byte >= UInt8(ascii: "A"), byte <= UInt8(ascii: "Z") { byte += 32 }
                if byte != needle[offset] {
                    matches = false
                    break
                }
            }
            if matches { return true }
            start += 1
        }
        return false
    }
}

extension MarkdownCommitBoundary {
    /// One source line: where its text starts after its indentation, where
    /// it ends, and where the next line starts. `indent` is in columns, with
    /// tab stops of 4 (CommonMark 2.2), so it is not a byte count.
    fileprivate nonisolated struct Line {
        let contentStart: Int
        let contentEnd: Int
        /// Past the newline.
        let end: Int
        let isTerminated: Bool
        let indent: Int
        let isBlank: Bool

        func content(in bytes: [UInt8]) -> ArraySlice<UInt8> {
            bytes[contentStart..<contentEnd]
        }

        static func split(_ bytes: [UInt8]) -> [Line] {
            var lines: [Line] = []
            var start = 0
            while start < bytes.count {
                var end = start
                while end < bytes.count, bytes[end] != 0x0A { end += 1 }
                var indent = 0
                var cursor = start
                while cursor < end {
                    let byte = bytes[cursor]
                    if byte == UInt8(ascii: " ") {
                        indent += 1
                    } else if byte == UInt8(ascii: "\t") {
                        indent += 4 - indent % 4
                    } else {
                        break
                    }
                    cursor += 1
                }
                let terminated = end < bytes.count
                lines.append(
                    Line(
                        contentStart: cursor, contentEnd: end, end: terminated ? end + 1 : end,
                        isTerminated: terminated, indent: indent, isBlank: cursor == end))
                start = end + 1
            }
            return lines
        }
    }

    /// An open code fence and what closes it.
    fileprivate nonisolated struct Fence {
        let marker: UInt8
        let length: Int

        init?(opening content: ArraySlice<UInt8>) {
            guard let first = content.first, first == UInt8(ascii: "`") || first == UInt8(ascii: "~")
            else { return nil }
            let length = content.prefix { $0 == first }.count
            guard length >= 3 else { return nil }
            // A backtick fence's info string cannot contain a backtick.
            if first == UInt8(ascii: "`"), content.dropFirst(length).contains(first) { return nil }
            marker = first
            self.length = length
        }

        func isClosed(by content: ArraySlice<UInt8>, indent: Int) -> Bool {
            guard indent < 4 else { return false }
            let run = content.prefix { $0 == marker }.count
            guard run >= length else { return false }
            return content.dropFirst(run).allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }
        }
    }
}
