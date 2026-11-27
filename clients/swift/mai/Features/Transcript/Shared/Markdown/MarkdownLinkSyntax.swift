import Foundation

/// Link labels, destinations and titles, shared by inline links, reference
/// definitions and streaming completion; ported from `@pierre/words`
/// `src/link.wat` (Apache 2.0).
nonisolated enum MarkdownLinkSyntax {
    struct Destination {
        /// The destination without its angle brackets.
        let start: Int
        let end: Int
        /// The position after the destination.
        let after: Int
    }

    /// A link label starting at the `[` at `p`: the position past its `]`. It
    /// holds at most 999 characters and no unescaped `[`.
    static func scanLabel(_ text: UnsafeBufferPointer<UInt8>, from p: Int, end: Int) -> Int? {
        guard p < end, text[p] == UInt8(ascii: "[") else { return nil }
        var q = p &+ 1
        var characters = 0
        while true {
            guard q < end else { return nil }
            let c = text[q]
            if c == UInt8(ascii: "[") { return nil }
            if c == UInt8(ascii: "]") { return q &+ 1 }
            if c == UInt8(ascii: "\\") {
                q &+= 1
                if q < end, MarkdownByteScanner.isASCIIPunct(text[q]) {
                    q &+= 1
                    characters &+= 1
                }
            } else if c >= 0x80 {
                q = MarkdownByteScanner.decodeUTF8Forward(text, at: q, end: end).1
            } else {
                q &+= 1
            }
            characters &+= 1
            if characters > 999 { return nil }
        }
    }

    /// A link destination at `p`, `<...>` or bare with balanced parentheses.
    /// `atEnd` reports one the input ended inside.
    static func scanDestination(
        _ text: UnsafeBufferPointer<UInt8>, from p: Int, end: Int, atEnd: inout Bool
    ) -> Destination? {
        guard p < end else { return nil }
        var i = p
        if text[p] == UInt8(ascii: "<") {
            // No line ending or unescaped `<`; `\` skips the next byte.
            while true {
                i &+= 1
                guard i < end else {
                    atEnd = true
                    return nil
                }
                let c = text[i]
                if c == UInt8(ascii: "\\") {
                    i &+= 1
                    continue
                }
                if c == 0x0A || c == UInt8(ascii: "<") { return nil }
                if c == UInt8(ascii: ">") { return Destination(start: p &+ 1, end: i, after: i &+ 1) }
            }
        }
        var depth = 0
        while i < end {
            let c = text[i]
            if c > UInt8(ascii: ")"), c != UInt8(ascii: "\\"), c != 0x7F {
                i &+= 1
                continue
            }
            if c == UInt8(ascii: "\\") {
                if i &+ 1 < end, MarkdownByteScanner.isASCIIPunct(text[i &+ 1]) { i &+= 1 }
            } else if c == UInt8(ascii: "(") {
                depth &+= 1
                if depth > 32 { return nil }
            } else if c == UInt8(ascii: ")") {
                if depth == 0 { break }
                depth &-= 1
            } else if (c > 0 && c <= 0x20) || c == 0x7F {
                // ASCII controls and space end it.
                if i == p { return nil }
                break
            }
            i &+= 1
        }
        if depth != 0 {
            atEnd = i >= end
            return nil
        }
        return Destination(start: p, end: i, after: i)
    }

    /// A link title in double quotes, single quotes or parentheses at `p`: the
    /// position past its closer.
    static func scanTitle(_ text: UnsafeBufferPointer<UInt8>, from p: Int, end: Int) -> Int? {
        guard p < end else { return nil }
        let open = text[p]
        let close: UInt8
        switch open {
        case UInt8(ascii: "\""), UInt8(ascii: "'"): close = open
        case UInt8(ascii: "("): close = UInt8(ascii: ")")
        default: return nil
        }
        var q = p &+ 1
        while true {
            guard q < end else { return nil }
            let c = text[q]
            if c == UInt8(ascii: "\\"), q &+ 1 < end, MarkdownByteScanner.isASCIIPunct(text[q &+ 1]) {
                q &+= 2
                continue
            }
            if c == close { return q &+ 1 }
            // The parenthesized form may not hold an unescaped `(`.
            if close == UInt8(ascii: ")"), c == UInt8(ascii: "(") { return nil }
            q &+= 1
        }
    }

    /// CommonMark label normalization: case fold, trim, and collapse runs of
    /// spaces, tabs and line endings to one space (only ASCII whitespace, so a
    /// label of U+00A0 is not empty).
    static func normalizeLabel(_ text: UnsafeBufferPointer<UInt8>, start: Int, end: Int) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(end &- start)
        var space = false
        var ascii = true
        for i in start..<end {
            let c = text[i]
            if MarkdownByteScanner.isWhitespace(c) {
                space = true
                continue
            }
            if space, !out.isEmpty { out.append(0x20) }
            space = false
            if c >= 0x80 { ascii = false }
            out.append(c &- 0x41 < 26 ? c | 0x20 : c)
        }
        let label = String(decoding: out, as: UTF8.self)
        // Full case folding maps both cases to one form; for the scalars that
        // differ from simple lowercasing (ß, final sigma, ligatures) folding
        // equals lowercasing the uppercase form.
        return ascii ? label : label.uppercased().lowercased()
    }

    /// Spaces and tabs, at most one line ending, then spaces and tabs again.
    static func skipLineSpace(_ text: UnsafeBufferPointer<UInt8>, from start: Int, end: Int) -> Int {
        var p = MarkdownByteScanner.skipSpaces(in: text, from: start, end: end)
        if p < end, text[p] == 0x0A { p = MarkdownByteScanner.skipSpaces(in: text, from: p &+ 1, end: end) }
        return p
    }
}
