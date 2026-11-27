import Foundation

/// UTF-8 and SIMD scanning primitives, following `@pierre/words` `src/scan.wat`
/// (Apache 2.0): 16-byte scans, the first-byte block-start set, and the plain
/// paragraph run that proves a leaf needs no inline analysis.
///
/// A SIMD comparison becomes a 64-bit mask with four bits per lane (NEON
/// `shrn`), so a scan finds every match in a window from one load. Windows that
/// cross the end are zero-padded: NUL is in no set, so tails need no scalar path.
nonisolated enum MarkdownByteScanner {
    // MARK: - Lane masks

    /// 16 bytes at `offset`, zero past `end`.
    @inline(__always)
    static func load16(_ base: UnsafePointer<UInt8>, _ offset: Int, end: Int) -> SIMD16<UInt8> {
        if end &- offset >= 16 {
            return UnsafeRawPointer(base.advanced(by: offset)).loadUnaligned(as: SIMD16<UInt8>.self)
        }
        var v = SIMD16<UInt8>()
        withUnsafeMutableBytes(of: &v) { dst in
            dst.copyMemory(from: UnsafeRawBufferPointer(start: base.advanced(by: offset), count: end &- offset))
        }
        return v
    }

    /// Four bits per lane, lane 0 lowest.
    @inline(__always)
    static func laneBits(_ mask: SIMDMask<SIMD16<Int8>>) -> UInt64 {
        let wide = unsafeBitCast(mask, to: SIMD8<UInt16>.self) &>> 4
        return unsafeBitCast(SIMD8<UInt8>(truncatingIfNeeded: wide), to: UInt64.self)
    }

    /// The first lane set in `bits` as an offset from `start`, or nil.
    @inline(__always)
    private static func firstLane(_ bits: UInt64, _ start: Int) -> Int? {
        bits == 0 ? nil : start &+ (bits.trailingZeroBitCount &>> 2)
    }

    /// The first `start..<end` position whose window `bits` matches, or `end`.
    @inline(__always)
    private static func scan(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, end: Int, _ bits: (SIMD16<UInt8>) -> UInt64
    ) -> Int {
        guard let base = bytes.baseAddress else { return end }
        var p = start
        while p < end {
            if let hit = firstLane(bits(load16(base, p, end: end)), p) { return min(hit, end) }
            p &+= 16
        }
        return end
    }

    // MARK: - Block-start set

    /// Bytes that can begin a block construct (or a blank or indented line) at
    /// the start of a line: `\t \n \r space # * + - 0-9 : < = > [ _ \` | ~`.
    private static let blockStartLo: UInt64 =
        (1 << 0x09) | (1 << 0x0A) | (1 << 0x0D) | (1 << 0x20) | (1 << 0x23) | (1 << 0x2A) | (1 << 0x2B)
        | (1 << 0x2D) | (0x3FF << 0x30) | (1 << 0x3A) | (1 << 0x3C) | (1 << 0x3D) | (1 << 0x3E)

    private static let blockStartHi: UInt64 =
        (1 << (0x5B - 64)) | (1 << (0x5F - 64)) | (1 << (0x60 - 64)) | (1 << (0x7C - 64)) | (1 << (0x7E - 64))

    @inline(__always)
    static func mayStartBlock(_ byte: UInt8) -> Bool {
        if byte < 64 { return blockStartLo & (1 &<< UInt64(byte)) != 0 }
        if byte < 128 { return blockStartHi & (1 &<< UInt64(byte &- 64)) != 0 }
        return false
    }

    // MARK: - Character classes

    @inline(__always)
    static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }

    /// Space, tab, line feed, line tabulation, form feed, carriage return.
    @inline(__always)
    static func isWhitespace(_ byte: UInt8) -> Bool { byte == 0x20 || byte &- 0x09 <= 4 }

    @inline(__always)
    static func isDigit(_ byte: UInt8) -> Bool { byte &- 0x30 <= 9 }

    @inline(__always)
    static func isAlpha(_ byte: UInt8) -> Bool { (byte | 0x20) &- 0x61 <= 25 }

    @inline(__always)
    static func isAlnum(_ byte: UInt8) -> Bool { isAlpha(byte) || isDigit(byte) }

    @inline(__always)
    static func isASCIIPunct(_ byte: UInt8) -> Bool { byte &- 0x21 <= 93 && !isAlnum(byte) }

    /// A byte of an email autolink's local part: letters, digits and ``.!#$%&'*+/=?^_`{|}~-``.
    @inline(__always)
    static func isEmailLocal(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "."), UInt8(ascii: "!"), UInt8(ascii: "#")...UInt8(ascii: "'"), UInt8(ascii: "*"),
            UInt8(ascii: "+"), UInt8(ascii: "/"), UInt8(ascii: "="), UInt8(ascii: "?"), UInt8(ascii: "^")...UInt8(ascii: "`"),
            UInt8(ascii: "{")...UInt8(ascii: "~"), UInt8(ascii: "-"):
            true
        default:
            isAlnum(byte)
        }
    }

    /// CommonMark Unicode whitespace: the Zs category, tab, line feed, form feed, carriage return.
    @inline(__always)
    static func isUnicodeWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v < 0x80 { return isWhitespace(UInt8(v)) }
        return v == 0xA0 || v == 0x1680 || (v >= 0x2000 && v <= 0x200A) || v == 0x202F || v == 0x205F
            || v == 0x3000
    }

    /// CommonMark Unicode punctuation: the P and S categories.
    @inline(__always)
    static func isUnicodePunct(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v < 0x80 { return isASCIIPunct(UInt8(v)) }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
            .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    // MARK: - Byte scans

    /// The next `\n` or `\r` in `start..<end`, or `end`.
    static func findLineEnd(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, end: Int) -> Int {
        scan(bytes, from: start, end: end) { v in
            laneBits((v .== SIMD16(repeating: 0x0A)) .| (v .== SIMD16(repeating: 0x0D)))
        }
    }

    /// The position after the line ending at `lineEnd` (`\r\n`, `\n`, `\r` or the end).
    @inline(__always)
    static func lineAfter(_ lineEnd: Int, in bytes: UnsafeBufferPointer<UInt8>, end: Int) -> Int {
        guard lineEnd < end else { return end }
        if bytes[lineEnd] == 0x0D, lineEnd &+ 1 < end, bytes[lineEnd &+ 1] == 0x0A { return lineEnd &+ 2 }
        return lineEnd &+ 1
    }

    /// The next `target` in `start..<end`, or `end`.
    static func findByte(_ target: UInt8, in bytes: UnsafeBufferPointer<UInt8>, from start: Int, end: Int) -> Int {
        scan(bytes, from: start, end: end) { v in laneBits(v .== SIMD16(repeating: target)) }
    }

    /// The next fence byte or `\r` in `start..<end`, or `end`.
    static func findCodeRunEnd(in bytes: UnsafeBufferPointer<UInt8>, from start: Int, end: Int, fence: UInt8) -> Int {
        scan(bytes, from: start, end: end) { v in
            laneBits((v .== SIMD16(repeating: fence)) .| (v .== SIMD16(repeating: 0x0D)))
        }
    }

    /// The next `|` or `\` in `start..<end` (they differ only in bit 5), or `end`.
    static func findCellBoundary(in bytes: UnsafeBufferPointer<UInt8>, from start: Int, end: Int) -> Int {
        scan(bytes, from: start, end: end) { v in
            laneBits((v | SIMD16(repeating: 0x20)) .== SIMD16(repeating: UInt8(ascii: "|")))
        }
    }

    /// The start of the LF-terminated line holding `pos`, never before `limit`.
    static func lineStartBefore(_ pos: Int, limit: Int, in bytes: UnsafeBufferPointer<UInt8>) -> Int {
        var cur = pos
        while cur > limit {
            if bytes[cur &- 1] == 0x0A { return cur }
            cur &-= 1
        }
        return limit
    }

    @inline(__always)
    static func runEnd(of byte: UInt8, in bytes: UnsafeBufferPointer<UInt8>, from start: Int, end: Int) -> Int {
        var pos = start
        while pos < end, bytes[pos] == byte { pos &+= 1 }
        return pos
    }

    @inline(__always)
    static func skipSpaces(in bytes: UnsafeBufferPointer<UInt8>, from start: Int, end: Int) -> Int {
        var pos = start
        while pos < end, isSpace(bytes[pos]) { pos &+= 1 }
        return pos
    }

    @inline(__always)
    static func skipWhitespace(in bytes: UnsafeBufferPointer<UInt8>, from start: Int, end: Int) -> Int {
        var pos = start
        while pos < end, isWhitespace(bytes[pos]) { pos &+= 1 }
        return pos
    }

    @inline(__always)
    static func trimSpacesBack(in bytes: UnsafeBufferPointer<UInt8>, from end: Int, limit: Int) -> Int {
        var pos = end
        while pos > limit, isSpace(bytes[pos &- 1]) { pos &-= 1 }
        return pos
    }

    // MARK: - Inline syntax

    /// The bytes that can start inline syntax: `\n ! & * . : < @ [ \ ] _ \` ~`.
    @inline(__always)
    static func syntaxBits(_ v: SIMD16<UInt8>) -> UInt64 {
        var m = v .== SIMD16(repeating: 0x0A)
        m .|= v .== SIMD16(repeating: UInt8(ascii: "!"))
        m .|= v .== SIMD16(repeating: UInt8(ascii: "&"))
        m .|= v .== SIMD16(repeating: UInt8(ascii: "*"))
        m .|= v .== SIMD16(repeating: UInt8(ascii: "."))
        m .|= v .== SIMD16(repeating: UInt8(ascii: ":"))
        m .|= v .== SIMD16(repeating: UInt8(ascii: "<"))
        m .|= v .== SIMD16(repeating: UInt8(ascii: "@"))
        m .|= v .== SIMD16(repeating: UInt8(ascii: "~"))
        m .|= (v &- SIMD16(repeating: UInt8(ascii: "["))) .<= SIMD16(repeating: 2)
        m .|= (v &- SIMD16(repeating: UInt8(ascii: "_"))) .<= SIMD16(repeating: 1)
        return laneBits(m)
    }

    /// The next inline syntax byte in `start..<end`, or `end`.
    static func findInlineSyntax(in bytes: UnsafeBufferPointer<UInt8>, from start: Int, end: Int) -> Int {
        scan(bytes, from: start, end: end, syntaxBits)
    }

    /// Iterates inline syntax positions, keeping each window's mask until the
    /// scan moves past it, so a window with several marks costs one load.
    struct SyntaxCursor {
        private var windowStart = -16
        private var bits: UInt64 = 0

        mutating func next(in bytes: UnsafeBufferPointer<UInt8>, from p: Int) -> Int? {
            guard let base = bytes.baseAddress else { return nil }
            let end = bytes.count
            var start = p
            if p >= windowStart, p &- windowStart < 16 {
                bits &= ~0 << UInt64((p &- windowStart) &<< 2)
                start = windowStart &+ 16
            } else {
                bits = 0
            }
            while bits == 0 {
                guard start < end else { return nil }
                bits = syntaxBits(load16(base, start, end: end))
                windowStart = start
                start &+= 16
            }
            return windowStart &+ (bits.trailingZeroBitCount &>> 2)
        }
    }

    /// Whether appended bytes could change how a validated literal paragraph
    /// parses: control bytes, ``"&<>@[\]`*_~:``.
    static func containsLiteralBreak(in bytes: UnsafeBufferPointer<UInt8>, from start: Int, end: Int) -> Bool {
        let hit = scan(bytes, from: start, end: end) { v in
            var m = v .<= SIMD16(repeating: 0x1F)
            m .|= v .== SIMD16(repeating: UInt8(ascii: "\""))
            m .|= v .== SIMD16(repeating: UInt8(ascii: "&"))
            m .|= v .== SIMD16(repeating: UInt8(ascii: "*"))
            m .|= v .== SIMD16(repeating: UInt8(ascii: ":"))
            m .|= v .== SIMD16(repeating: UInt8(ascii: "<"))
            m .|= v .== SIMD16(repeating: UInt8(ascii: ">"))
            m .|= v .== SIMD16(repeating: UInt8(ascii: "@"))
            m .|= v .== SIMD16(repeating: UInt8(ascii: "~"))
            m .|= (v &- SIMD16(repeating: UInt8(ascii: "["))) .<= SIMD16(repeating: 2)
            m .|= (v &- SIMD16(repeating: UInt8(ascii: "_"))) .<= SIMD16(repeating: 1)
            // A padded tail lane is NUL, which is a control byte.
            return laneBits(m)
        }
        return hit < end
    }

    // MARK: - Plain paragraph runs

    struct PlainParagraphRun {
        let lastLineStart: Int
        let lastLineEnd: Int
        let isPlainInline: Bool
        let lineCount: Int
    }

    /// Consecutive unindented root paragraph lines from `start` (whose first
    /// byte starts no block), stopping before a possible block start or `\r`.
    /// While no line holds inline syntax (or trailing spaces, a hard break),
    /// the run is proven plain; after that a line-end scan collects the rest.
    static func findPlainParagraphRun(
        in bytes: UnsafeBufferPointer<UInt8>, from start: Int, end: Int
    ) -> PlainParagraphRun {
        guard let base = bytes.baseAddress else {
            return PlainParagraphRun(lastLineStart: start, lastLineEnd: start, isPlainInline: true, lineCount: 1)
        }
        var lineStart = start
        var lines = 1
        var window = start
        var general = end
        scanning: while window < end {
            let v = load16(base, window, end: end)
            var bits = syntaxBits(v) | laneBits(v .== SIMD16(repeating: 0x0D))
            while bits != 0 {
                let lane = bits.trailingZeroBitCount &>> 2
                bits &= ~(0xF << UInt64(lane &<< 2))
                let p = window &+ lane
                switch base[p] {
                case 0x0A:
                    // Interior trailing whitespace may make a hard break.
                    if isSpace(base[p &- 1]) {
                        general = p
                        break scanning
                    }
                    let next = p &+ 1
                    if next >= end || mayStartBlock(base[next]) {
                        return PlainParagraphRun(
                            lastLineStart: lineStart, lastLineEnd: p, isPlainInline: true, lineCount: lines)
                    }
                    lineStart = next
                    lines &+= 1
                case 0x0D:
                    return PlainParagraphRun(
                        lastLineStart: lineStart, lastLineEnd: p, isPlainInline: false, lineCount: lines)
                case UInt8(ascii: "."):
                    // A dot matters only after `www`.
                    if p &- lineStart >= 3, base[p &- 3] | 0x20 == UInt8(ascii: "w"),
                        base[p &- 2] | 0x20 == UInt8(ascii: "w"), base[p &- 1] | 0x20 == UInt8(ascii: "w")
                    {
                        general = p
                        break scanning
                    }
                default:
                    general = p
                    break scanning
                }
            }
            window &+= 16
        }
        guard general < end else {
            return PlainParagraphRun(lastLineStart: lineStart, lastLineEnd: end, isPlainInline: true, lineCount: lines)
        }
        var p = general
        while true {
            let lineEnd = findLineEnd(bytes, from: p, end: end)
            let next = lineEnd &+ 1
            if lineEnd >= end || base[lineEnd] != 0x0A || next >= end || mayStartBlock(base[next]) {
                return PlainParagraphRun(
                    lastLineStart: lineStart, lastLineEnd: lineEnd, isPlainInline: false, lineCount: lines)
            }
            lineStart = next
            lines &+= 1
            p = next
        }
    }

    // MARK: - UTF-8

    /// The scalar at `pos` and the position after it; ill-formed bytes are one U+FFFD.
    @inline(__always)
    static func decodeUTF8Forward(_ bytes: UnsafeBufferPointer<UInt8>, at pos: Int, end: Int) -> (Unicode.Scalar, Int) {
        guard pos < end else { return ("\u{FFFD}", end) }
        let b0 = bytes[pos]
        if b0 < 0x80 { return (Unicode.Scalar(b0), pos &+ 1) }
        var iterator = UnsafeBufferPointer(rebasing: bytes[pos..<min(end, pos &+ 4)]).makeIterator()
        var utf8 = UTF8()
        if case .scalarValue(let scalar) = utf8.decode(&iterator) { return (scalar, pos &+ UTF8.width(scalar)) }
        return ("\u{FFFD}", pos &+ 1)
    }

    /// The scalar ending just before `pos`, not reading before `start`.
    @inline(__always)
    static func decodeUTF8Backward(_ bytes: UnsafeBufferPointer<UInt8>, before pos: Int, start: Int) -> Unicode.Scalar {
        guard pos > start else { return " " }
        let last = bytes[pos &- 1]
        if last < 0x80 { return Unicode.Scalar(last) }
        var cur = pos &- 1
        let floor = max(start, pos &- 4)
        while cur > floor, bytes[cur] & 0xC0 == 0x80 { cur &-= 1 }
        let (scalar, next) = decodeUTF8Forward(bytes, at: cur, end: pos)
        return next == pos ? scalar : "\u{FFFD}"
    }

    // MARK: - Unescaping

    /// `start..<end` with backslash escapes and character references resolved.
    static func unescape(_ bytes: UnsafeBufferPointer<UInt8>, start: Int, end: Int) -> String {
        guard start < end else { return "" }
        var special = start
        while special < end, bytes[special] != UInt8(ascii: "\\"), bytes[special] != UInt8(ascii: "&") {
            special &+= 1
        }
        let slice = UnsafeBufferPointer(rebasing: bytes[start..<end])
        guard special < end else { return String(decoding: slice, as: UTF8.self) }
        var out: [UInt8] = []
        out.reserveCapacity(end &- start)
        out.append(contentsOf: bytes[start..<special])
        var pos = special
        while pos < end {
            let b = bytes[pos]
            if b == UInt8(ascii: "\\"), pos &+ 1 < end, isASCIIPunct(bytes[pos &+ 1]) {
                out.append(bytes[pos &+ 1])
                pos &+= 2
            } else if b == UInt8(ascii: "&"), let length = MarkdownEntities.match(slice, at: pos &- start, end: end &- start) {
                MarkdownEntities.decode(slice, at: pos &- start, into: &out)
                pos &+= length
            } else {
                out.append(b)
                pos &+= 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}
