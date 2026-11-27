import Foundation

/// HTML character references (`&name;`, `&#123;`, `&#x1F;`), ported from
/// `@pierre/words` `src/entity.wat` (Apache 2.0) with the full WHATWG name table.
nonisolated enum MarkdownEntities {
    private enum Value {
        case scalar(UInt32)
        /// A line of `table`.
        case named(Int)
    }

    /// The length of the character reference at the `&` at `p`, or nil.
    static func match(_ text: UnsafeBufferPointer<UInt8>, at p: Int, end: Int) -> Int? {
        resolve(text, at: p, end: end)?.length
    }

    /// Appends the UTF-8 of the reference `match` accepted at `p`.
    static func decode(_ text: UnsafeBufferPointer<UInt8>, at p: Int, into out: inout [UInt8]) {
        guard let (_, value) = resolve(text, at: p, end: text.count) else { return }
        switch value {
        case .scalar(let v):
            appendUTF8(v, to: &out)
        case .named(let line):
            let ptr = table.utf8Start
            var i = Int(lineStarts[line])
            while ptr[i] != 0x20 { i &+= 1 }
            var v: UInt32 = 0
            while true {
                i &+= 1
                let c = i < table.utf8CodeUnitCount ? ptr[i] : 0x0A
                if c == 0x20 || c == 0x0A {
                    appendUTF8(v, to: &out)
                    v = 0
                    if c == 0x0A { return }
                } else {
                    v = v << 4 | UInt32(c <= 0x39 ? c &- 0x30 : c &- 0x37)
                }
            }
        }
    }

    private static func resolve(_ text: UnsafeBufferPointer<UInt8>, at p: Int, end: Int) -> (length: Int, value: Value)? {
        var q = p &+ 1
        guard q < end else { return nil }
        if text[q] == UInt8(ascii: "#") {
            q &+= 1
            guard q < end else { return nil }
            // At most six hexadecimal or seven decimal digits.
            let hex = text[q] | 0x20 == UInt8(ascii: "x")
            if hex { q &+= 1 }
            var value: UInt32 = 0
            var digits = 0
            let maxDigits = hex ? 6 : 7
            while q < end {
                let c = text[q]
                var d = UInt32(c &- 0x30)
                if d > 9 {
                    d = UInt32((c | 0x20) &- 87)
                    guard hex, d >= 10, d <= 15 else { break }
                }
                digits &+= 1
                if digits > maxDigits { break }
                value = value &* (hex ? 16 : 10) &+ d
                q &+= 1
            }
            guard digits > 0, digits <= maxDigits, q < end, text[q] == UInt8(ascii: ";") else { return nil }
            return (q &+ 1 &- p, .scalar(value))
        }
        guard MarkdownByteScanner.isAlpha(text[q]) else { return nil }
        // Names hold at most 31 characters before the `;`.
        let semicolon = MarkdownByteScanner.findByte(UInt8(ascii: ";"), in: text, from: q, end: min(end, p &+ 33))
        guard semicolon < min(end, p &+ 33), let line = lookup(text, from: q, to: semicolon) else { return nil }
        return (semicolon &+ 1 &- p, .named(line))
    }

    /// The table line whose name is `text[from..<to]`.
    private static func lookup(_ text: UnsafeBufferPointer<UInt8>, from: Int, to: Int) -> Int? {
        let ptr = table.utf8Start
        var lo = 0
        var hi = lineStarts.count
        while lo < hi {
            let mid = (lo &+ hi) >> 1
            var i = Int(lineStarts[mid])
            var j = from
            var order = 0
            while order == 0 {
                let a = ptr[i]
                let atNameEnd = a == 0x20
                if j == to {
                    order = atNameEnd ? 0 : 1
                    break
                }
                if atNameEnd { order = -1 } else if a != text[j] { order = a < text[j] ? -1 : 1 }
                i &+= 1
                j &+= 1
            }
            if order == 0 { return mid }
            if order < 0 { lo = mid &+ 1 } else { hi = mid }
        }
        return nil
    }

    private static let lineStarts: [Int32] = {
        var starts: [Int32] = [0]
        let ptr = table.utf8Start
        for i in 0..<table.utf8CodeUnitCount where ptr[i] == 0x0A { starts.append(Int32(i &+ 1)) }
        return starts
    }()

    /// Encodes `v` as UTF-8, replacing what HTML disallows (NUL, surrogates,
    /// values past U+10FFFF) with U+FFFD.
    static func appendUTF8(_ value: UInt32, to out: inout [UInt8]) {
        let v = value == 0 || value > 0x10FFFF || value & 0xFFFF_F800 == 0xD800 ? 0xFFFD : value
        switch v {
        case ..<0x80:
            out.append(UInt8(truncatingIfNeeded: v))
        case ..<0x800:
            out.append(UInt8(truncatingIfNeeded: 0xC0 | v >> 6))
            out.append(UInt8(truncatingIfNeeded: 0x80 | v & 0x3F))
        case ..<0x10000:
            out.append(UInt8(truncatingIfNeeded: 0xE0 | v >> 12))
            out.append(UInt8(truncatingIfNeeded: 0x80 | v >> 6 & 0x3F))
            out.append(UInt8(truncatingIfNeeded: 0x80 | v & 0x3F))
        default:
            out.append(UInt8(truncatingIfNeeded: 0xF0 | v >> 18))
            out.append(UInt8(truncatingIfNeeded: 0x80 | v >> 12 & 0x3F))
            out.append(UInt8(truncatingIfNeeded: 0x80 | v >> 6 & 0x3F))
            out.append(UInt8(truncatingIfNeeded: 0x80 | v & 0x3F))
        }
    }
}
