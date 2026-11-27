import Foundation

/// CommonMark raw HTML grammar shared by inline HTML, HTML block starts and
/// streaming completion, ported from `@pierre/words` `src/htmlscan.wat`
/// (Apache 2.0). `atEnd` reports a scan that failed only because the input
/// ended, so more bytes could still finish the tag.
nonisolated enum MarkdownHTMLScanner {
    /// Constructs whose closer is missing from the rest of a leaf: a later
    /// opener of the same kind would search a suffix of the failed range, so
    /// remembering the miss keeps runs of unclosed openers linear.
    struct NoClose: OptionSet {
        let rawValue: UInt8
        static let comment = NoClose(rawValue: 1)
        static let processing = NoClose(rawValue: 2)
        static let cdata = NoClose(rawValue: 4)
        static let declaration = NoClose(rawValue: 8)
    }

    /// The end of a complete raw HTML construct starting at the `<` at `p`.
    static func scanAny(
        _ text: UnsafeBufferPointer<UInt8>, at p: Int, end: Int, noClose: inout NoClose, atEnd: inout Bool
    ) -> Int? {
        guard p &+ 1 < end else { return nil }
        switch text[p &+ 1] {
        case UInt8(ascii: "!"):
            guard p &+ 4 <= end else { return nil }
            // A comment ends at the first `-->`, so `<!-->` and `<!--->` are whole.
            if text[p &+ 2] == UInt8(ascii: "-"), text[p &+ 3] == UInt8(ascii: "-") {
                return findSequence(text, from: p &+ 2, end: end, "-->", kind: .comment, noClose: &noClose)
            }
            if text[p &+ 2] == UInt8(ascii: "[") {
                guard p &+ 9 <= end, matches(text, at: p &+ 3, "CDATA[") else { return nil }
                return findSequence(text, from: p &+ 9, end: end, "]]>", kind: .cdata, noClose: &noClose)
            }
            var q = p &+ 2
            while q < end, MarkdownByteScanner.isAlpha(text[q]) { q &+= 1 }
            guard q > p &+ 2 else { return nil }
            return findSequence(text, from: q, end: end, ">", kind: .declaration, noClose: &noClose)
        case UInt8(ascii: "?"):
            return findSequence(text, from: p &+ 2, end: end, "?>", kind: .processing, noClose: &noClose)
        case UInt8(ascii: "/"):
            return scanCloseTag(text, at: p &+ 2, end: end, atEnd: &atEnd)
        default:
            return scanOpenTag(text, at: p &+ 1, end: end, atEnd: &atEnd)
        }
    }

    /// `tagname = [A-Za-z][A-Za-z0-9-]*` at `p`: its length, or 0.
    static func tagNameLength(_ text: UnsafeBufferPointer<UInt8>, at p: Int, end: Int, atEnd: inout Bool) -> Int {
        guard p < end else {
            atEnd = true
            return 0
        }
        guard MarkdownByteScanner.isAlpha(text[p]) else { return 0 }
        var q = p &+ 1
        while q < end, MarkdownByteScanner.isAlnum(text[q]) || text[q] == UInt8(ascii: "-") { q &+= 1 }
        return q &- p
    }

    /// `opentag = tagname attribute* whitespace* [/] >` from the tag name at
    /// `p`: the position past `>`.
    static func scanOpenTag(_ text: UnsafeBufferPointer<UInt8>, at start: Int, end: Int, atEnd: inout Bool) -> Int? {
        let n = tagNameLength(text, at: start, end: end, atEnd: &atEnd)
        guard n > 0 else { return nil }
        var p = start &+ n
        while true {
            // An attribute needs whitespace before its name.
            var q = MarkdownByteScanner.skipWhitespace(in: text, from: p, end: end)
            guard q != p else { break }
            p = q
            // attributename = [a-zA-Z_:][a-zA-Z0-9:._-]*
            while q < end, isAttributeNameByte(text[q], first: q == p) { q &+= 1 }
            guard q != p else { break }
            p = q
            q = MarkdownByteScanner.skipWhitespace(in: text, from: p, end: end)
            guard q < end, text[q] == UInt8(ascii: "=") else { continue }
            q = MarkdownByteScanner.skipWhitespace(in: text, from: q &+ 1, end: end)
            guard q < end else {
                atEnd = true
                return nil
            }
            let quote = text[q]
            if quote == UInt8(ascii: "'") || quote == UInt8(ascii: "\"") {
                p = MarkdownByteScanner.findByte(quote, in: text, from: q &+ 1, end: end)
                guard p < end else {
                    atEnd = true
                    return nil
                }
                p &+= 1
            } else {
                // unquotedvalue = [^ \t\n\v\f\r"'=<>`]+
                p = q
                while p < end, !isUnquotedValueStop(text[p]) { p &+= 1 }
                guard p != q else { return nil }
            }
        }
        p = MarkdownByteScanner.skipWhitespace(in: text, from: p, end: end)
        if p < end, text[p] == UInt8(ascii: "/") { p &+= 1 }
        guard p < end else {
            atEnd = true
            return nil
        }
        return text[p] == UInt8(ascii: ">") ? p &+ 1 : nil
    }

    /// `closetag = tagname whitespace* >` from just past `</`.
    static func scanCloseTag(_ text: UnsafeBufferPointer<UInt8>, at start: Int, end: Int, atEnd: inout Bool) -> Int? {
        let n = tagNameLength(text, at: start, end: end, atEnd: &atEnd)
        guard n > 0 else { return nil }
        let p = MarkdownByteScanner.skipWhitespace(in: text, from: start &+ n, end: end)
        guard p < end else {
            atEnd = true
            return nil
        }
        return text[p] == UInt8(ascii: ">") ? p &+ 1 : nil
    }

    /// Whether `[p, p + length)` names an HTML block of type 6, in any case.
    static func isBlockTag(_ text: UnsafeBufferPointer<UInt8>, at p: Int, length: Int) -> Bool {
        guard length <= 10 else { return false }
        var key: UInt64 = 0
        var hi: UInt16 = 0
        for i in 0..<length {
            let folded = UInt64(text[p &+ i] | 0x20)
            if i < 8 { key |= folded << (UInt64(i) &* 8) } else { hi |= UInt16(folded) << (UInt16(i &- 8) &* 8) }
        }
        return blockTags.contains(BlockTag(key: key, hi: hi))
    }

    /// `pre`, `script`, `style` or `textarea` (HTML block type 1), in any case.
    static func isRawTag(_ text: UnsafeBufferPointer<UInt8>, at p: Int, length: Int) -> Bool {
        switch length {
        case 3: matchesFolded(text, at: p, "pre")
        case 5: matchesFolded(text, at: p, "style")
        case 6: matchesFolded(text, at: p, "script")
        case 8: matchesFolded(text, at: p, "textarea")
        default: false
        }
    }

    // MARK: - Helpers

    private struct BlockTag: Hashable {
        let key: UInt64
        let hi: UInt16
    }

    private static let blockTags: Set<BlockTag> = Set(
        [
            "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col",
            "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure",
            "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr",
            "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol",
            "optgroup", "option", "p", "param", "search", "section", "summary", "table", "tbody", "td", "tfoot",
            "th", "thead", "title", "tr", "track", "ul",
        ].map { name in
            var key: UInt64 = 0
            var hi: UInt16 = 0
            for (i, byte) in name.utf8.enumerated() {
                if i < 8 { key |= UInt64(byte) << (UInt64(i) * 8) } else { hi |= UInt16(byte) << (UInt16(i - 8) * 8) }
            }
            return BlockTag(key: key, hi: hi)
        })

    @inline(__always)
    private static func isAttributeNameByte(_ c: UInt8, first: Bool) -> Bool {
        if MarkdownByteScanner.isAlpha(c) || c == UInt8(ascii: "_") || c == UInt8(ascii: ":") { return true }
        return !first && (MarkdownByteScanner.isDigit(c) || c == UInt8(ascii: ".") || c == UInt8(ascii: "-"))
    }

    @inline(__always)
    private static func isUnquotedValueStop(_ c: UInt8) -> Bool {
        switch c {
        case 0x09...0x0D, 0x20, UInt8(ascii: "\""), UInt8(ascii: "'"), UInt8(ascii: "="), UInt8(ascii: "<"),
            UInt8(ascii: ">"), UInt8(ascii: "`"):
            true
        default: false
        }
    }

    private static func findSequence(
        _ text: UnsafeBufferPointer<UInt8>, from start: Int, end: Int, _ sequence: StaticString, kind: NoClose,
        noClose: inout NoClose
    ) -> Int? {
        guard !noClose.contains(kind) else { return nil }
        let n = sequence.utf8CodeUnitCount
        let first = sequence.utf8Start[0]
        var p = start
        while true {
            p = MarkdownByteScanner.findByte(first, in: text, from: p, end: end)
            guard p &+ n <= end else { break }
            if matches(text, at: p, sequence) { return p &+ n }
            p &+= 1
        }
        noClose.insert(kind)
        return nil
    }

    @inline(__always)
    static func matches(_ text: UnsafeBufferPointer<UInt8>, at p: Int, _ literal: StaticString) -> Bool {
        let n = literal.utf8CodeUnitCount
        guard p &+ n <= text.count else { return false }
        let ptr = literal.utf8Start
        for i in 0..<n where text[p &+ i] != ptr[i] { return false }
        return true
    }

    @inline(__always)
    static func matchesFolded(_ text: UnsafeBufferPointer<UInt8>, at p: Int, _ literal: StaticString) -> Bool {
        let n = literal.utf8CodeUnitCount
        guard p &+ n <= text.count else { return false }
        let ptr = literal.utf8Start
        for i in 0..<n where text[p &+ i] | 0x20 != ptr[i] { return false }
        return true
    }
}
