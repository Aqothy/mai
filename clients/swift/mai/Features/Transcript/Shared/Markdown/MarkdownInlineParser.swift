import Foundation

/// Pass 2: the inline parser of one leaf's content, ported from `@pierre/words`
/// `src/inline.wat` and `src/extlink.wat` (Apache 2.0).
///
/// One scan records every construct as a flat mark in source order; emphasis
/// resolves afterwards over the delimiter marks with the CommonMark algorithm
/// (nearest opener, openers bottom, rule of three). Emission walks text and
/// marks once and builds each styled run in a reused byte buffer, so a run costs
/// one `String`, never a chain of appends.
nonisolated struct MarkdownInlineParser {
    enum Kind: UInt8 {
        case none, bracket, emph, code, autolink, rawHTML, entity, escape, softBreak, hardBreak
        case linkOpen, linkClose, extLink
    }

    struct Mark {
        var beg: Int32
        var end: Int32
        var kind: Kind
        var flags: UInt8 = 0
        var ch: UInt8 = 0
        /// Delimiters of an emphasis run still unconsumed.
        var rem: Int32 = 0
        /// Emphasis: the previous delimiter. Code: content start. Autolink: 1 for
        /// email. Extended autolink: 0 verbatim, 1 `http://`, 2 `mailto:`. Link
        /// open: its close mark. Link close: its URL slot, -1 for none.
        var data: Int32 = 0
        var next: Int32 = -1
        var openTags: Int32 = -1
        var closeTags: Int32 = -1
    }

    enum Flag {
        static let canOpen: UInt8 = 1
        static let canClose: UInt8 = 2
        static let image: UInt8 = 4
        /// The mark is linked into the delimiter list.
        static let inList: UInt8 = 8
    }

    fileprivate struct Tag {
        var style: MarkdownInline.Style
        var next: Int32
    }

    fileprivate struct Bracket {
        var mark: Int32 = 0
        var delimBottom: Int32 = -1
        var image = false
        var active = false
        var nested = false
    }

    /// Link definitions visible to a leaf. Earlier (committed) definitions win
    /// over the leaf's own document, as the first definition of a label does.
    struct Definitions {
        var local: [String: String] = [:]
        var external: [String: String]?

        var isEmpty: Bool { local.isEmpty && (external?.isEmpty ?? true) }

        func destination(for label: String) -> String? {
            external?[label] ?? local[label]
        }
    }

    /// Work buffers reused across every leaf of a document.
    struct Scratch {
        fileprivate var marks: [Mark] = []
        fileprivate var tags: [Tag] = []
        fileprivate var urls: [URL?] = []
        fileprivate var brackets: [Bracket] = []
        fileprivate var tickMemo: [Int32] = []
        fileprivate var run: [UInt8] = []
        fileprivate var inlines: [MarkdownInline] = []
    }

    private let buffer: UnsafeBufferPointer<UInt8>
    private var count: Int { buffer.count }
    private let definitions: Definitions
    /// Completion closed a trailing `[label]` that may still get its `(`: it
    /// shows as a link once no reference resolves it.
    private let pendingLabelAtEnd: Bool

    private var marks: [Mark]
    private var tags: [Tag]
    private var urls: [URL?]
    private var brackets: [Bracket]
    private var tickMemo: [Int32]
    private var run: [UInt8]
    private var inlines: [MarkdownInline]

    private var delimHead: Int32 = -1
    private var delimTail: Int32 = -1
    /// Open brackets; the newest 256 live in a ring and those below `bracketLo`
    /// were dropped and stay text.
    private var bracketSp = 0
    private var bracketLo = 0
    private var scannedBackticks = false
    private var tickTop = 0
    private var htmlNoClose: MarkdownHTMLScanner.NoClose = []
    private var wwwRejectBefore = 0
    /// End of the newest mark: extended autolinks never reach back into it.
    private(set) var lastMarkEnd = 0

    // MARK: - Entry points

    /// The styled runs of `content` (one leaf's inline content, offsets from 0).
    static func parse(
        _ content: UnsafeBufferPointer<UInt8>, definitions: Definitions, pendingLabelAtEnd: Bool = false,
        scratch: inout Scratch
    ) -> [MarkdownInline] {
        guard !content.isEmpty else { return [] }
        if MarkdownByteScanner.findInlineSyntax(in: content, from: 0, end: content.count) >= content.count {
            return [MarkdownInline(text: String(decoding: content, as: UTF8.self))]
        }
        var parser = MarkdownInlineParser(
            content, definitions: definitions, pendingLabelAtEnd: pendingLabelAtEnd, scratch: &scratch)
        parser.scan()
        let inlines = parser.emit()
        scratch = parser.takeScratch()
        return inlines
    }

    /// The parser state over `content` for the completion scan, which shares
    /// the autolink and code-span scanners.
    init(scanning content: UnsafeBufferPointer<UInt8>, scratch: inout Scratch) {
        self.init(content, definitions: Definitions(), pendingLabelAtEnd: false, scratch: &scratch)
    }

    private init(
        _ content: UnsafeBufferPointer<UInt8>, definitions: Definitions, pendingLabelAtEnd: Bool, scratch: inout Scratch
    ) {
        buffer = content
        self.definitions = definitions
        self.pendingLabelAtEnd = pendingLabelAtEnd
        // Moving the buffers out keeps them uniquely referenced, so appends
        // never copy them.
        marks = scratch.marks
        tags = scratch.tags
        urls = scratch.urls
        brackets = scratch.brackets.isEmpty ? [Bracket](repeating: Bracket(), count: 256) : scratch.brackets
        tickMemo = scratch.tickMemo.isEmpty ? [Int32](repeating: 0, count: 256) : scratch.tickMemo
        run = scratch.run
        inlines = scratch.inlines
        scratch = Scratch()
        marks.removeAll(keepingCapacity: true)
        tags.removeAll(keepingCapacity: true)
        urls.removeAll(keepingCapacity: true)
    }

    func takeScratch() -> Scratch {
        Scratch(marks: marks, tags: tags, urls: urls, brackets: brackets, tickMemo: tickMemo, run: run, inlines: inlines)
    }

    // MARK: - Scan

    @inline(__always)
    private func byte(_ offset: Int) -> UInt8 { buffer[offset] }

    @discardableResult
    private mutating func addMark(_ mark: Mark) -> Int32 {
        marks.append(mark)
        lastMarkEnd = Int(mark.end)
        return Int32(marks.count &- 1)
    }

    private mutating func scan() {
        var cursor = MarkdownByteScanner.SyntaxCursor()
        var p = 0
        while let at = cursor.next(in: buffer, from: p) {
            p = dispatch(at)
        }
        if delimHead >= 0 { processEmphasis(bottom: 0, delimBottom: -1) }
    }

    private mutating func dispatch(_ p: Int) -> Int {
        switch byte(p) {
        case UInt8(ascii: "\\"): return handleBackslash(p)
        case UInt8(ascii: "`"): return handleBackticks(p)
        case UInt8(ascii: "["): return pushBracket(p, image: false)
        case UInt8(ascii: "]"): return handleCloseBracket(p)
        case UInt8(ascii: "@"): return tryEmailAutolink(p)
        case UInt8(ascii: "."): return tryWWWAutolink(p)
        case 0x0A: return handleNewline(p)
        case UInt8(ascii: ":"): return tryURLAutolink(p)
        case UInt8(ascii: "&"): return handleEntity(p)
        case UInt8(ascii: "<"): return handlePointy(p)
        case UInt8(ascii: "!"):
            return p &+ 1 < count && byte(p &+ 1) == UInt8(ascii: "[") ? pushBracket(p, image: true) : p &+ 1
        default: return handleDelimiter(p)
        }
    }

    private mutating func handleBackslash(_ p: Int) -> Int {
        guard p &+ 1 < count else { return p &+ 1 }
        let next = byte(p &+ 1)
        if next == 0x0A {
            addMark(Mark(beg: Int32(p), end: Int32(p &+ 2), kind: .hardBreak))
            return p &+ 2
        }
        guard MarkdownByteScanner.isASCIIPunct(next) else { return p &+ 1 }
        addMark(Mark(beg: Int32(p), end: Int32(p &+ 2), kind: .escape))
        return p &+ 2
    }

    private mutating func handleNewline(_ p: Int) -> Int {
        // A plain soft break needs no mark unless a side holds spaces to trim.
        if p > 0, !MarkdownByteScanner.isSpace(byte(p &- 1)), p &+ 1 >= count || !MarkdownByteScanner.isSpace(byte(p &+ 1)) {
            return p &+ 1
        }
        let q = MarkdownByteScanner.skipSpaces(in: buffer, from: p &+ 1, end: count)
        let hard = p >= 2 && byte(p &- 1) == 0x20 && byte(p &- 2) == 0x20
        addMark(Mark(beg: Int32(p), end: Int32(q), kind: hard ? .hardBreak : .softBreak))
        return q
    }

    private mutating func handleEntity(_ p: Int) -> Int {
        guard let length = MarkdownEntities.match(buffer, at: p, end: count) else { return p &+ 1 }
        addMark(Mark(beg: Int32(p), end: Int32(p &+ length), kind: .entity))
        return p &+ length
    }

    private mutating func handlePointy(_ p: Int) -> Int {
        if let end = Self.scanAutolinkURI(buffer, at: p, end: count) {
            addMark(Mark(beg: Int32(p), end: Int32(end), kind: .autolink, data: 0))
            return end
        }
        if let end = Self.scanAutolinkEmail(buffer, at: p, end: count) {
            addMark(Mark(beg: Int32(p), end: Int32(end), kind: .autolink, data: 1))
            return end
        }
        var atEnd = false
        if let end = MarkdownHTMLScanner.scanAny(buffer, at: p, end: count, noClose: &htmlNoClose, atEnd: &atEnd) {
            addMark(Mark(beg: Int32(p), end: Int32(end), kind: .rawHTML))
            return end
        }
        return p &+ 1
    }

    private mutating func handleBackticks(_ p: Int) -> Int {
        let q = MarkdownByteScanner.runEnd(of: UInt8(ascii: "`"), in: buffer, from: p, end: count)
        guard let close = closingBackticks(from: q, length: q &- p) else { return q }
        addMark(Mark(beg: Int32(p), end: Int32(close), kind: .code, data: Int32(q)))
        return close
    }

    /// The end of the next run of exactly `length` backticks at or after `from`.
    /// Runs over 255 never pair. `tickMemo` holds, per run length, the start of
    /// the latest such run in this leaf: once a scan reached the end, a length
    /// whose latest run starts before `from` has no closer (CommonMark linear
    /// code spans).
    mutating func closingBackticks(from start: Int, length: Int) -> Int? {
        guard length <= 255 else { return nil }
        if scannedBackticks, length > tickTop || Int(tickMemo[length]) <= start { return nil }
        var p = start
        while true {
            p = MarkdownByteScanner.findByte(UInt8(ascii: "`"), in: buffer, from: p, end: count)
            guard p < count else { break }
            let q = MarkdownByteScanner.runEnd(of: UInt8(ascii: "`"), in: buffer, from: p, end: count)
            let ticks = q &- p
            if ticks <= 255, !scannedBackticks {
                while tickTop < ticks {
                    tickTop &+= 1
                    tickMemo[tickTop] = 0
                }
                tickMemo[ticks] = Int32(p)
            }
            if ticks == length { return q }
            p = q
        }
        scannedBackticks = true
        return nil
    }

    // MARK: - Emphasis

    /// Flanking class of a neighbor: 2 whitespace (or the content edge), 1 punctuation, 0 other.
    @inline(__always)
    private func flankClass(_ scalar: Unicode.Scalar?) -> Int {
        guard let scalar else { return 2 }
        if MarkdownByteScanner.isUnicodeWhitespace(scalar) { return 2 }
        return MarkdownByteScanner.isUnicodePunct(scalar) ? 1 : 0
    }

    /// CommonMark flanking of the delimiter run `[p, q)`: `k` is the class
    /// before times four plus the class after; the result has bit 0 can-open
    /// and bit 1 can-close (for `*` and `~`).
    func runFlags(_ p: Int, _ q: Int) -> (k: Int, flags: UInt8) {
        let before = p == 0 ? nil : MarkdownByteScanner.decodeUTF8Backward(buffer, before: p, start: 0)
        let after = q >= count ? nil : MarkdownByteScanner.decodeUTF8Forward(buffer, at: q, end: count).0
        let k = flankClass(before) << 2 | flankClass(after)
        return (k, UInt8(truncatingIfNeeded: (0x52d2b >> (k << 1)) & 3))
    }

    private mutating func handleDelimiter(_ p: Int) -> Int {
        let c = byte(p)
        let q = MarkdownByteScanner.runEnd(of: c, in: buffer, from: p, end: count)
        // Only runs of one or two tildes are strikethrough delimiters.
        if c == UInt8(ascii: "~"), q &- p > 2 { return q }
        let (k, flags) = runFlags(p, q)
        // Only two neighbors that are neither space nor punctuation flank a run
        // both ways besides two punctuation marks, so this is all `_` changes.
        if flags == 0 || (c == UInt8(ascii: "_") && k == 0) { return q }
        let index = addMark(
            Mark(
                beg: Int32(p), end: Int32(q), kind: .emph, flags: flags | Flag.inList, ch: c,
                rem: Int32(q &- p), data: delimTail))
        if delimTail >= 0 { marks[Int(delimTail)].next = index } else { delimHead = index }
        delimTail = index
        return q
    }

    private mutating func removeDelimiter(_ index: Int32) {
        let i = Int(index)
        guard marks[i].flags & Flag.inList != 0 else { return }
        marks[i].flags &= ~Flag.inList
        let prev = marks[i].data
        let next = marks[i].next
        if prev >= 0 { marks[Int(prev)].next = next } else { delimHead = next }
        if next >= 0 { marks[Int(next)].data = prev } else { delimTail = prev }
    }

    /// Resolves the delimiters after `delimBottom` (all when -1), then drops
    /// every delimiter at or above `bottom`.
    private mutating func processEmphasis(bottom: Int32, delimBottom: Int32) {
        var closer = delimBottom >= 0 ? marks[Int(delimBottom)].next : delimHead
        guard closer >= 0 else { return }
        // Openers bottom per character, closer-can-open and length mod 3.
        var openersBottom = (
            bottom, bottom, bottom, bottom, bottom, bottom, bottom, bottom, bottom,
            bottom, bottom, bottom, bottom, bottom, bottom, bottom, bottom, bottom
        )
        while closer >= 0 {
            let cm = marks[Int(closer)]
            guard cm.flags & Flag.canClose != 0 else {
                closer = cm.next
                continue
            }
            let closerLength = cm.end &- cm.beg
            let closerCanOpen = cm.flags & Flag.canOpen != 0
            let slot =
                (cm.ch == UInt8(ascii: "*") ? 0 : cm.ch == UInt8(ascii: "_") ? 6 : 12) &+ (closerCanOpen ? 3 : 0)
                &+ Int(closerLength % 3)
            let floor = withUnsafeBytes(of: &openersBottom) { $0.load(fromByteOffset: slot &* 4, as: Int32.self) }
            var opener = cm.data
            var matched = false
            while opener >= 0 {
                let om = marks[Int(opener)]
                if om.beg < floor { break }
                if om.flags & Flag.canOpen != 0, om.ch == cm.ch {
                    let openerLength = om.end &- om.beg
                    // The rule of three.
                    if !(closerCanOpen || om.flags & Flag.canClose != 0) || closerLength.isMultiple(of: 3)
                        || !(openerLength &+ closerLength).isMultiple(of: 3)
                    {
                        matched = true
                        break
                    }
                }
                opener = om.data
            }
            if matched {
                closer = pair(opener: opener, closer: closer)
            } else {
                withUnsafeMutableBytes(of: &openersBottom) { $0.storeBytes(of: cm.beg, toByteOffset: slot &* 4, as: Int32.self) }
                let old = closer
                closer = cm.next
                if !closerCanOpen { removeDelimiter(old) }
            }
        }
        while delimTail >= 0, marks[Int(delimTail)].beg >= bottom {
            removeDelimiter(delimTail)
        }
    }

    private mutating func pair(opener: Int32, closer: Int32) -> Int32 {
        let o = Int(opener)
        let c = Int(closer)
        let tilde = marks[c].ch == UInt8(ascii: "~")
        var use: Int32 = marks[o].rem >= 2 && marks[c].rem >= 2 ? 2 : 1
        var style: MarkdownInline.Style = use == 2 ? .strong : .emphasis
        if tilde {
            // Strikethrough consumes both runs at once, and only when they match.
            use = marks[o].rem == marks[c].rem ? marks[o].rem : 0
            style = .strikethrough
        }
        marks[o].rem &-= use
        marks[c].rem &-= use
        if use > 0 {
            tags.append(Tag(style: style, next: marks[o].openTags))
            marks[o].openTags = Int32(tags.count &- 1)
            tags.append(Tag(style: style, next: marks[c].closeTags))
            marks[c].closeTags = Int32(tags.count &- 1)
        }
        // Delimiters between the pair can never match anything now.
        var between = marks[o].next
        while between >= 0, between != closer {
            let next = marks[Int(between)].next
            removeDelimiter(between)
            between = next
        }
        let afterCloser = marks[c].next
        if tilde || marks[o].rem == 0 { removeDelimiter(opener) }
        if tilde || marks[c].rem == 0 {
            removeDelimiter(closer)
            return afterCloser
        }
        return closer
    }

    // MARK: - Links and images

    private mutating func pushBracket(_ p: Int, image: Bool) -> Int {
        let end = p &+ (image ? 2 : 1)
        let index = addMark(Mark(beg: Int32(p), end: Int32(end), kind: .bracket, flags: image ? Flag.image : 0))
        if bracketSp &- bracketLo == 256 { bracketLo &+= 1 }
        if bracketSp > 0 { brackets[(bracketSp &- 1) & 255].nested = true }
        brackets[bracketSp & 255] = Bracket(mark: index, delimBottom: delimTail, image: image, active: true)
        bracketSp &+= 1
        return end
    }

    private mutating func handleCloseBracket(_ p: Int) -> Int {
        let initial = p &+ 1
        guard bracketSp > 0 else { return initial }
        if bracketSp == bracketLo {
            bracketLo = bracketSp &- 1
            bracketSp &-= 1
            return initial
        }
        let bracket = brackets[(bracketSp &- 1) & 255]
        guard bracket.active else {
            bracketSp &-= 1
            return initial
        }
        let open = Int(bracket.mark)
        let bottom = Int(marks[open].end)
        var q = initial
        var destination: String?
        var resolved = false

        // An inline link or image: `[text](dest "title")`.
        if q < count, byte(q) == UInt8(ascii: "(") {
            var t = MarkdownByteScanner.skipWhitespace(in: buffer, from: q &+ 1, end: count)
            var atEnd = false
            if let dest = MarkdownLinkSyntax.scanDestination(buffer, from: t, end: count, atEnd: &atEnd) {
                let after = dest.after
                t = MarkdownByteScanner.skipWhitespace(in: buffer, from: after, end: count)
                if t != after, let titleEnd = MarkdownLinkSyntax.scanTitle(buffer, from: t, end: count) {
                    t = MarkdownByteScanner.skipWhitespace(in: buffer, from: titleEnd, end: count)
                }
                if t < count, byte(t) == UInt8(ascii: ")") {
                    q = t &+ 1
                    destination = MarkdownByteScanner.unescape(buffer, start: dest.start, end: dest.end)
                    resolved = true
                }
            }
        }
        // A reference: `[text][label]`, `[label][]` or `[label]`. A missing or
        // empty label uses the text, unless the text holds another bracket.
        if !resolved {
            q = MarkdownLinkSyntax.scanLabel(buffer, from: initial, end: count) ?? initial
            var labelStart = initial &+ 1
            var labelEnd = q &- 1
            if labelStart >= labelEnd {
                labelStart = bottom
                labelEnd = bracket.nested ? bottom : p
            }
            if labelStart < labelEnd, !definitions.isEmpty {
                let key = MarkdownLinkSyntax.normalizeLabel(buffer, start: labelStart, end: labelEnd)
                if !key.isEmpty, let found = definitions.destination(for: key) {
                    destination = found
                    resolved = true
                }
            }
            if !resolved, !bracket.image, pendingLabelAtEnd, initial == count {
                q = initial
                resolved = true
            }
        }
        guard resolved else {
            bracketSp &-= 1
            return initial
        }

        let url = bracket.image ? nil : destination.flatMap { TranscriptLinkPolicy.url(for: $0) }
        urls.append(url)
        let close = addMark(
            Mark(
                beg: Int32(p), end: Int32(q), kind: .linkClose, flags: bracket.image ? Flag.image : 0,
                data: Int32(urls.count &- 1)))
        marks[open].kind = .linkOpen
        marks[open].data = close
        processEmphasis(bottom: Int32(bottom), delimBottom: bracket.delimBottom)
        bracketSp &-= 1
        // A link may not contain another link: open brackets below it are dead.
        if !bracket.image {
            var n = bracketSp
            while n > bracketLo {
                n &-= 1
                if !brackets[n & 255].image {
                    if !brackets[n & 255].active { break }
                    brackets[n & 255].active = false
                }
            }
        }
        return q
    }

    // MARK: - Autolinks

    /// `<scheme:...>` at `p`: the position past `>`.
    static func scanAutolinkURI(_ text: UnsafeBufferPointer<UInt8>, at p: Int, end: Int) -> Int? {
        var q = p &+ 1
        while q < end, q &- p <= 33 {
            let c = text[q]
            guard MarkdownByteScanner.isAlnum(c) || c == UInt8(ascii: ".") || c == UInt8(ascii: "+")
                || c == UInt8(ascii: "-")
            else { break }
            q &+= 1
        }
        // A scheme of 2 to 32 characters starting with a letter.
        guard q &- p &- 3 <= 30, q &- p >= 3, p &+ 1 < end, MarkdownByteScanner.isAlpha(text[p &+ 1]) else {
            return nil
        }
        guard q < end, text[q] == UInt8(ascii: ":") else { return nil }
        while true {
            q &+= 1
            guard q < end else { return nil }
            let c = text[q]
            if c < 0x20 || c == 0x20 || c == UInt8(ascii: "<") || c == 0x7F { return nil }
            if c == UInt8(ascii: ">") { return q &+ 1 }
        }
    }

    /// `<user@host>` at `p`: the position past `>`.
    static func scanAutolinkEmail(_ text: UnsafeBufferPointer<UInt8>, at p: Int, end: Int) -> Int? {
        var q = p &+ 1
        while true {
            guard q < end else { return nil }
            let c = text[q]
            if c == UInt8(ascii: "@") { break }
            guard MarkdownByteScanner.isEmailLocal(c) else { return nil }
            q &+= 1
        }
        guard q > p &+ 1 else { return nil }
        var c: UInt8 = 0
        repeat {
            q &+= 1
            guard q < end, MarkdownByteScanner.isAlnum(text[q]) else { return nil }
            let segment = q
            while true {
                guard q < end else { return nil }
                c = text[q]
                guard MarkdownByteScanner.isAlnum(c) || c == UInt8(ascii: "-") else { break }
                q &+= 1
                if q &- segment > 63 { break }
            }
            if text[q &- 1] == UInt8(ascii: "-") { return nil }
        } while c == UInt8(ascii: ".")
        return c == UInt8(ascii: ">") ? q &+ 1 : nil
    }

    @inline(__always)
    private func isWWW(endingAt p: Int) -> Bool {
        p >= 3 && byte(p &- 3) | 0x20 == UInt8(ascii: "w") && byte(p &- 2) | 0x20 == UInt8(ascii: "w")
            && byte(p &- 1) | 0x20 == UInt8(ascii: "w")
    }

    @inline(__always)
    private func startsSlashes(_ p: Int) -> Bool {
        p &+ 2 < count && byte(p &+ 1) == UInt8(ascii: "/") && byte(p &+ 2) == UInt8(ascii: "/")
    }

    /// Whether `[offset, offset + literal.count)` equals `literal`, ASCII letters folded.
    private func matchesFolded(_ offset: Int, _ literal: StaticString) -> Bool {
        let n = literal.utf8CodeUnitCount
        guard offset >= 0, offset &+ n <= count else { return false }
        let ptr = literal.utf8Start
        for i in 0..<n where byte(offset &+ i) | 0x20 != ptr[i] { return false }
        return true
    }

    /// Trailing punctuation, unbalanced closing parentheses and entity
    /// references are not part of an extended autolink.
    private func autolinkDelim(_ beg: Int, _ scanFrom: Int) -> Int {
        var scan = scanFrom
        var parens = 0
        while scan < count {
            let c = byte(scan)
            if MarkdownByteScanner.isWhitespace(c) || c == UInt8(ascii: "<") { break }
            if c == UInt8(ascii: ")") { parens &+= 1 } else if c == UInt8(ascii: "(") { parens &-= 1 }
            scan &+= 1
        }
        while scan > beg {
            let c = byte(scan &- 1)
            switch c {
            case UInt8(ascii: ")"):
                guard parens > 0 else { return scan }
                parens &-= 1
                scan &-= 1
            case UInt8(ascii: "?"), UInt8(ascii: "!"), UInt8(ascii: "."), UInt8(ascii: ","), UInt8(ascii: ":"),
                UInt8(ascii: "*"), UInt8(ascii: "_"), UInt8(ascii: "~"), UInt8(ascii: "'"), UInt8(ascii: "\""):
                scan &-= 1
            case UInt8(ascii: ";"):
                var ne = scan &- 2
                while ne > beg, MarkdownByteScanner.isAlpha(byte(ne)) { ne &-= 1 }
                scan = ne < scan &- 2 && byte(ne) == UInt8(ascii: "&") ? ne : scan &- 1
            default:
                return scan
            }
        }
        return scan
    }

    /// The length of the domain at `p`, or 0. An underscore in the last two
    /// segments rejects it.
    private mutating func checkDomain(_ p: Int, allowShort: Bool) -> Int {
        var segment = p
        var previousSegment = p
        var underscores1 = 0
        var underscores2 = 0
        var dots = 0
        var i = p &+ 1
        while i &+ 1 < count {
            var c = byte(i)
            if c == UInt8(ascii: "\\"), i &+ 2 < count {
                i &+= 1
                c = byte(i)
            }
            if c == UInt8(ascii: "_") {
                underscores2 &+= 1
            } else if c == UInt8(ascii: ".") {
                previousSegment = segment
                segment = i &+ 1
                underscores1 = underscores2
                underscores2 = 0
                dots &+= 1
            } else if c < 0x80 {
                guard MarkdownByteScanner.isAlnum(c) || c == UInt8(ascii: "-") else { break }
            } else {
                let (scalar, _) = MarkdownByteScanner.decodeUTF8Forward(buffer, at: i, end: count)
                if MarkdownByteScanner.isUnicodeWhitespace(scalar) || MarkdownByteScanner.isUnicodePunct(scalar) {
                    break
                }
            }
            i &+= 1
        }
        _ = segment
        if underscores1 > 0 || underscores2 > 0 {
            wwwRejectBefore = previousSegment
            return 0
        }
        return allowShort || dots > 0 ? i &- p : 0
    }

    private mutating func urlAutolink(_ beg: Int, host: Int, www: Bool) -> Int? {
        let n = checkDomain(host, allowShort: !www)
        guard n > 0 else { return nil }
        let end = autolinkDelim(beg, host &+ n)
        guard end > host &+ (www ? 4 : 0) else { return nil }
        addMark(Mark(beg: Int32(beg), end: Int32(end), kind: .extLink, data: www ? 1 : 0))
        return end
    }

    /// Completion skips autolinks as the parser reads them: the end of the
    /// autolink at the `:` or `.` at `p`, with `openBrackets` open before it.
    mutating func autolinkEnd(at p: Int, openBrackets: Int, www: Bool) -> Int {
        marks.removeAll(keepingCapacity: true)
        bracketSp = openBrackets
        bracketLo = 0
        return www ? tryWWWAutolink(p) : tryURLAutolink(p)
    }

    /// `www.` at its `.`.
    private mutating func tryWWWAutolink(_ p: Int) -> Int {
        let beg = p &- 3
        guard isWWW(endingAt: p), bracketSp == 0, beg >= lastMarkEnd else { return p &+ 1 }
        // Only after whitespace, `*`, `_`, `~` or `(`.
        if beg > 0 {
            let c = byte(beg &- 1)
            guard MarkdownByteScanner.isWhitespace(c) || c == UInt8(ascii: "*") || c == UInt8(ascii: "_")
                || c == UInt8(ascii: "~") || c == UInt8(ascii: "(")
            else { return p &+ 1 }
        }
        guard beg >= wwwRejectBefore, let end = urlAutolink(beg, host: beg, www: true) else { return p &+ 1 }
        return end
    }

    /// `scheme://` at its `:`.
    private mutating func tryURLAutolink(_ p: Int) -> Int {
        guard startsSlashes(p), bracketSp == 0, p &+ 4 <= count else { return p &+ 1 }
        var beg = p
        while beg > lastMarkEnd, MarkdownByteScanner.isAlpha(byte(beg &- 1)) { beg &-= 1 }
        let scheme = p &- beg &+ 1
        guard (scheme == 5 && matchesFolded(beg, "http:")) || (scheme == 6 && matchesFolded(beg, "https:"))
            || (scheme == 4 && matchesFolded(beg, "ftp:"))
        else { return p &+ 1 }
        // The host starts with a letter, digit, or non-ASCII non-space non-punctuation.
        let first = byte(p &+ 3)
        if first < 0x80 {
            guard MarkdownByteScanner.isAlnum(first) else { return p &+ 1 }
        } else {
            let (scalar, _) = MarkdownByteScanner.decodeUTF8Forward(buffer, at: p &+ 3, end: count)
            if MarkdownByteScanner.isUnicodeWhitespace(scalar) || MarkdownByteScanner.isUnicodePunct(scalar) {
                return p &+ 1
            }
        }
        return urlAutolink(beg, host: p &+ 3, www: false) ?? p &+ 1
    }

    /// A bare email address, or one with a `mailto:` or `xmpp:` scheme, at its `@`.
    private mutating func tryEmailAutolink(_ p: Int) -> Int {
        guard bracketSp == 0 else { return p &+ 1 }
        var beg = p
        // Marks `[k, marks.count)` are `_` runs the local part absorbs: the
        // newest marks, unresolved because no bracket is open.
        var k = marks.count
        var stop = lastMarkEnd
        while true {
            if beg <= stop {
                guard k > 0 else { break }
                let m = marks[k &- 1]
                guard Int(m.end) == beg, m.kind == .emph, m.ch == UInt8(ascii: "_") else { break }
                beg = Int(m.beg)
                k &-= 1
                stop = k > 0 ? Int(marks[k &- 1].end) : 0
                continue
            }
            let c = byte(beg &- 1)
            guard MarkdownByteScanner.isAlnum(c) || c == UInt8(ascii: ".") || c == UInt8(ascii: "+")
                || c == UInt8(ascii: "-") || c == UInt8(ascii: "_")
            else { break }
            beg &-= 1
        }
        guard beg != p else { return p &+ 1 }
        // An explicit scheme keeps the address verbatim; glued to a word before
        // it, the scheme is text before a bare address.
        var scheme = 0
        if beg >= stop &+ 7, matchesFolded(beg &- 7, "mailto:") {
            scheme = 7
        } else if beg >= stop &+ 5, matchesFolded(beg &- 5, "xmpp:") {
            scheme = 5
        }
        if scheme > 0, beg != scheme, MarkdownByteScanner.isAlnum(byte(beg &- scheme &- 1)) { scheme = 0 }
        beg &-= scheme
        let xmpp = scheme == 5
        var q = p &+ 1
        var dots = 0
        while q < count {
            let c = byte(q)
            if c == UInt8(ascii: ".") {
                // A dot only between alphanumerics.
                guard q &+ 1 < count, MarkdownByteScanner.isAlnum(byte(q &+ 1)) else { break }
                dots &+= 1
            } else if !(MarkdownByteScanner.isAlnum(c) || c == UInt8(ascii: "-") || c == UInt8(ascii: "_")
                || (xmpp && c == UInt8(ascii: "/")))
            {
                break
            }
            q &+= 1
        }
        guard q &- p >= 3, dots > 0, MarkdownByteScanner.isAlpha(byte(q &- 1)) else { return p &+ 1 }
        for absorbed in k..<marks.count { removeDelimiter(Int32(absorbed)) }
        marks.removeSubrange(k...)
        addMark(Mark(beg: Int32(beg), end: Int32(q), kind: .extLink, data: scheme == 0 ? 2 : 0))
        return q
    }

    // MARK: - Emission

    /// Builds runs. A run that is one source range becomes a `String` straight
    /// from the source; only a run of several pieces (or decoded text) collects
    /// in `run`. Links compare by slot in `urls`, URLs only when a run closes.
    private struct Emitter {
        let source: UnsafeBufferPointer<UInt8>
        var output: [MarkdownInline]
        var run: [UInt8]
        /// The current run while it is still one source range.
        var slice = 0..<0
        var style: MarkdownInline.Style = []
        var slot: Int32 = -1
        var depth = (em: 0, strong: 0, strike: 0)

        var currentStyle: MarkdownInline.Style {
            var style: MarkdownInline.Style = []
            if depth.em > 0 { style.insert(.emphasis) }
            if depth.strong > 0 { style.insert(.strong) }
            if depth.strike > 0 { style.insert(.strikethrough) }
            return style
        }

        /// Starts appending in `style` and `slot`, closing the run if either changed.
        @inline(__always)
        mutating func use(_ newStyle: MarkdownInline.Style, _ newSlot: Int32, _ urls: [URL?]) {
            if newStyle != style || newSlot != slot {
                flush(urls)
                style = newStyle
                slot = newSlot
            }
        }

        /// Appends `source[from..<to]`.
        mutating func text(_ from: Int, _ to: Int) {
            guard from < to else { return }
            if run.isEmpty {
                if slice.isEmpty {
                    slice = from..<to
                    return
                }
                if from == slice.upperBound {
                    slice = slice.lowerBound..<to
                    return
                }
                materialize()
            }
            run.append(contentsOf: UnsafeBufferPointer(rebasing: source[from..<to]))
        }

        /// Moves a pending source range into `run`, before bytes that are not source.
        mutating func materialize() {
            guard !slice.isEmpty else { return }
            run.append(contentsOf: UnsafeBufferPointer(rebasing: source[slice]))
            slice = 0..<0
        }

        mutating func flush(_ urls: [URL?]) {
            let text: String
            if !run.isEmpty {
                text = String(decoding: run, as: UTF8.self)
                run.removeAll(keepingCapacity: true)
            } else if !slice.isEmpty {
                text = String(decoding: UnsafeBufferPointer(rebasing: source[slice]), as: UTF8.self)
                slice = 0..<0
            } else {
                return
            }
            let link = slot >= 0 ? urls[Int(slot)] : nil
            if let last = output.indices.last, output[last].style == style, output[last].link == link {
                output[last].text += text
            } else {
                output.append(MarkdownInline(text: text, style: style, link: link))
            }
        }

        mutating func apply(_ tags: [Tag], from head: Int32, opening: Bool) {
            var t = head
            let delta = opening ? 1 : -1
            while t >= 0 {
                let tag = tags[Int(t)]
                switch tag.style {
                case .emphasis: depth.em &+= delta
                case .strong: depth.strong &+= delta
                default: depth.strike &+= delta
                }
                t = tag.next
            }
        }
    }

    private mutating func emit() -> [MarkdownInline] {
        var out = Emitter(source: buffer, output: inlines, run: run)
        out.output.removeAll(keepingCapacity: true)
        out.run.removeAll(keepingCapacity: true)
        var linkSlot: Int32 = -1
        var p = 0

        func append(_ from: Int, _ to: Int, style: MarkdownInline.Style, slot: Int32, _ out: inout Emitter) {
            guard from < to else { return }
            out.use(style, slot, urls)
            out.text(from, to)
        }

        var i = 0
        while i < marks.count {
            let m = marks[i]
            i &+= 1
            let beg = Int(m.beg)
            // Marks inside an earlier mark (an image's source) are covered.
            guard beg >= p, m.kind != .none else { continue }
            var textEnd = beg
            if m.kind == .softBreak || m.kind == .hardBreak, byte(beg) == 0x0A {
                // The spaces before a line break are not content.
                textEnd = MarkdownByteScanner.trimSpacesBack(in: buffer, from: beg, limit: p)
            }
            append(p, textEnd, style: out.currentStyle, slot: linkSlot, &out)
            p = Int(m.end)
            switch m.kind {
            case .none:
                break
            case .bracket:
                append(beg, p, style: out.currentStyle, slot: linkSlot, &out)
            case .escape:
                append(beg &+ 1, p, style: out.currentStyle, slot: linkSlot, &out)
            case .softBreak, .hardBreak:
                out.use(out.currentStyle, linkSlot, urls)
                out.materialize()
                out.run.append(0x0A)
            case .entity:
                out.use(out.currentStyle, linkSlot, urls)
                out.materialize()
                MarkdownEntities.decode(buffer, at: beg, into: &out.run)
            case .code:
                out.use(out.currentStyle.union(.code), linkSlot, urls)
                appendCodeSpan(content: Int(m.data), end: p &- (Int(m.data) &- beg), into: &out)
            case .rawHTML:
                append(beg, p, style: out.currentStyle.union(.code), slot: linkSlot, &out)
            case .autolink, .extLink:
                var slot = linkSlot
                if slot < 0 {
                    let inner = m.kind == .autolink ? (beg &+ 1)..<(p &- 1) : beg..<p
                    let raw = String(decoding: UnsafeBufferPointer(rebasing: buffer[inner]), as: UTF8.self)
                    let prefix = m.kind == .autolink ? (m.data == 1 ? "mailto:" : "") : (m.data == 1 ? "http://" : m.data == 2 ? "mailto:" : "")
                    urls.append(TranscriptLinkPolicy.url(for: prefix + raw))
                    slot = Int32(urls.count &- 1)
                }
                let shown = m.kind == .autolink ? (beg &+ 1, p &- 1) : (beg, p)
                append(shown.0, shown.1, style: out.currentStyle, slot: slot, &out)
            case .linkOpen:
                let close = marks[Int(m.data)]
                if m.flags & Flag.image != 0 {
                    // App policy: an image shows its source as code.
                    p = Int(close.end)
                    append(beg, p, style: out.currentStyle.union(.code), slot: linkSlot, &out)
                } else {
                    linkSlot = close.data
                }
            case .linkClose:
                linkSlot = -1
            case .emph:
                out.apply(tags, from: m.closeTags, opening: false)
                append(beg, beg &+ Int(m.rem), style: out.currentStyle, slot: linkSlot, &out)
                out.apply(tags, from: m.openTags, opening: true)
            }
        }
        append(p, count, style: out.currentStyle, slot: linkSlot, &out)
        out.flush(urls)
        run = out.run
        // The runs live as long as their block: copy them to an exact-size array.
        let result = Array(out.output[...])
        out.output.removeAll(keepingCapacity: true)
        inlines = out.output
        return result
    }

    /// A code span's content: line endings become spaces, and one space (or
    /// line ending) comes off each side when both have one and the content is
    /// not all spaces.
    private func appendCodeSpan(content start: Int, end: Int, into out: inout Emitter) {
        var b = start
        var e = end
        if e &- b >= 2 {
            let first = byte(b)
            let last = byte(e &- 1)
            if first == 0x20 || first == 0x0A, last == 0x20 || last == 0x0A {
                var q = b
                while q < e, byte(q) == 0x20 || byte(q) == 0x0A { q &+= 1 }
                if q < e {
                    b &+= 1
                    e &-= 1
                }
            }
        }
        var newline = MarkdownByteScanner.findByte(0x0A, in: buffer, from: b, end: e)
        guard newline < e else { return out.text(b, e) }
        out.materialize()
        while true {
            out.run.append(contentsOf: UnsafeBufferPointer(rebasing: buffer[b..<newline]))
            guard newline < e else { return }
            out.run.append(0x20)
            b = newline &+ 1
            newline = MarkdownByteScanner.findByte(0x0A, in: buffer, from: b, end: e)
        }
    }

}
