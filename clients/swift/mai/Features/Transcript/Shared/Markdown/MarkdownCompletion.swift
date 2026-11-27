import Foundation

/// Streaming completion: a display copy of an unfinished document whose last
/// block shows as it will once its syntax closes, ported from `@pierre/words`
/// `src/complete.wat` (Apache 2.0). The source never changes.
///
/// It runs after block analysis and reads only the last leaf (a paragraph,
/// heading or the last table cell), skipping code spans, raw HTML, link
/// destinations and bare URLs as the inline parser does. A bounded stack of
/// open delimiter runs pairs closers as the parser would (flanking, nearest
/// opener, rule of three); when a closer might not pair it writes none, since
/// an unpaired closer shows as text nobody typed. Unfinished links get a
/// placeholder destination, unfinished tags and images are dropped.
nonisolated enum MarkdownCompletion {
    struct Repair {
        /// The repaired input, or nil when only `labelAtEnd` applies.
        var bytes: [UInt8]?
        /// A trailing `[label]` that may still get its `(`: inline analysis shows
        /// it as a link once no reference resolves it.
        var labelAtEnd: Bool
    }

    /// The placeholder for an unfinished destination; the space keeps the line
    /// from reading as a link reference definition.
    private static let placeholder = Array("]( streamdown:incomplete-link)".utf8)

    private struct Delimiter {
        /// The run's byte | 256 can also close | 512 gets no closers | (length % 3) << 16.
        var word: Int
        /// Delimiters still unused.
        var rem: Int
        /// The content offset after the run.
        var end: Int
    }

    private struct Bracket {
        /// The content offset after the `[`.
        var offset: Int
        /// Emphasis depth there | 256 image | 512 cannot be a link | 1024 `[^` | 2048 lost an opener to a closer inside.
        var meta: Int
    }

    private enum Bit {
        static let image = 256
        static let dead = 512
        static let footnote = 1024
        static let lowered = 2048
        static let canClose = 256
        static let noClosers = 512
    }

    static func repair(
        _ input: UnsafeBufferPointer<UInt8>, _ result: MarkdownBlockParser.Result,
        definitions: MarkdownInlineParser.Definitions, scratch: inout MarkdownInlineParser.Scratch
    ) -> Repair? {
        let r = result.lastLeaf
        guard r >= 0 else { return nil }
        let record = result.records[r]
        let type = record.kind
        let count = Int(record.lineCount)
        guard count > 0, type == .paragraph || type == .heading || type == .table,
            record.flags & MarkdownBlockParser.Flags.plainInline == 0
        else { return nil }
        let eof = input.count
        let spans = result.lines[Int(record.lineStart)..<(Int(record.lineStart) &+ count)]
        let last = Int(spans[spans.endIndex &- 1].end)

        // The content: one input range, or the lines joined by `\n`.
        var contentStart = Int(spans[spans.startIndex].start)
        var joined: [UInt8]?
        switch type {
        case .paragraph:
            // A paragraph can continue after one line break and indentation.
            let after = MarkdownByteScanner.lineAfter(
                MarkdownByteScanner.skipSpaces(in: input, from: last, end: eof), in: input, end: eof)
            guard MarkdownByteScanner.skipSpaces(in: input, from: after, end: eof) >= eof else { return nil }
            joined = joinedContent(input, spans)
        case .heading:
            // Headings and table rows end at their line break.
            guard MarkdownByteScanner.findLineEnd(input, from: last, end: eof) >= eof else { return nil }
            joined = joinedContent(input, spans)
        default:
            guard MarkdownByteScanner.findLineEnd(input, from: last, end: eof) >= eof else { return nil }
            // Cells parse apart, so a row repairs only its last cell.
            contentStart = Int(spans[spans.endIndex &- 1].start)
            var t = contentStart
            while true {
                t = MarkdownByteScanner.findCellBoundary(in: input, from: t, end: last)
                guard t < last else { break }
                if input[t] == UInt8(ascii: "\\") {
                    t &+= 1 &+ (t &+ 1 < last && MarkdownByteScanner.isASCIIPunct(input[t &+ 1]) ? 1 : 0)
                } else {
                    t &+= 1
                    contentStart = t
                }
            }
            contentStart = MarkdownByteScanner.skipSpaces(in: input, from: contentStart, end: last)
        }
        let contentInputEnd = last
        let contentLength = joined?.count ?? (last &- contentStart)
        guard contentLength > 0 else { return nil }

        /// The input position of content offset `offset`.
        func inputAt(_ offset: Int) -> Int {
            guard joined != nil else { return contentStart &+ offset }
            var off = offset
            for span in spans {
                let length = Int(span.end &- span.start)
                if off <= length { return Int(span.start) &+ off }
                off &-= length &+ 1
            }
            return last
        }

        let plan = withContent(input, from: contentStart, length: contentLength, joined: joined) { text in
            scan(
                text, type: type, startsItem: result.lastLeafStartsItem, contentAtEOF: contentInputEnd == eof,
                definitions: definitions, scratch: &scratch)
        }
        guard let closeAt = plan.closeAt else { return plan.labelAtEnd ? Repair(bytes: nil, labelAtEnd: true) : nil }

        var from = inputAt(closeAt)
        // A heading's closing `#` run is not content: the closers replace it.
        var to = plan.cut < contentLength ? inputAt(plan.cut) : (type == .heading ? last : eof)
        // A placeholder or a tick after a bare list marker would give that item
        // content, and an item with content ends the paragraph.
        if plan.open || plan.ticks > 0, type == .paragraph {
            var line = spans.endIndex &- 1
            while Int(spans[line].start) > from, line > spans.startIndex { line &-= 1 }
            let q = Int(spans[line].start)
            if q &+ listMarkerLength(input, at: q, lineEnd: from) >= from { to = from }
        }
        // Only closers written right after a `\` make it an escape: before
        // whitespace it stays text, and before a line break it is a hard break.
        var backslash = plan.backslash
        if plan.closers.isEmpty, plan.ticks == 0, !plan.open || from < to { backslash = 0 }
        // Ticks stay on the last line: after a line break they could start a fence.
        if plan.ticks > 0 {
            while from < to, input[from] != 0x0A, input[from] != 0x0D { from &+= 1 }
        }

        var out: [UInt8] = []
        out.reserveCapacity(to &+ plan.ticks &+ plan.closers.count &+ placeholder.count &+ plan.outerClosers.count)
        out.append(contentsOf: input[0..<(from &- backslash)])
        out.append(contentsOf: repeatElement(UInt8(ascii: "`"), count: plan.ticks))
        out.append(contentsOf: plan.closers)
        out.append(contentsOf: input[from..<to])
        if plan.open {
            out.append(contentsOf: placeholder)
            out.append(contentsOf: plan.outerClosers)
        }
        return Repair(bytes: out, labelAtEnd: plan.labelAtEnd)
    }

    // MARK: - Scan

    private struct Plan {
        /// Where the closers go, or nil when nothing changes.
        var closeAt: Int?
        /// Content from here on is dropped.
        var cut: Int
        /// 1 when a `\` before the closers is replaced.
        var backslash: Int
        var ticks: Int
        /// Closers inside a pending link's text, innermost first.
        var closers: [UInt8]
        var open: Bool
        /// Closers after the placeholder.
        var outerClosers: [UInt8]
        var labelAtEnd: Bool
    }

    private static func scan(
        _ text: UnsafeBufferPointer<UInt8>, type: MarkdownBlockParser.RecordKind, startsItem: Bool, contentAtEOF: Bool,
        definitions: MarkdownInlineParser.Definitions, scratch: inout MarkdownInlineParser.Scratch
    ) -> Plan {
        var e = text.count
        var cut = e
        var inline = MarkdownInlineParser(scanning: text, scratch: &scratch)
        defer { scratch = inline.takeScratch() }
        var noClose: MarkdownHTMLScanner.NoClose = []

        // The start of a task marker stays hidden until the item shows what it is.
        if startsItem, e <= 3, type == .paragraph, text[0] == UInt8(ascii: "[") {
            let c = e > 1 ? text[1] : 0
            if e == 1 || ((c == 0x20 || c | 0x20 == UInt8(ascii: "x")) && (e == 2 || text[2] == UInt8(ascii: "]"))) {
                cut = 0
                e = 0
            }
        }

        var links: [Bracket] = []
        var extra = 0
        var delims: [Delimiter] = []
        var depth = 0
        var escapeEnd = 0
        var ticks = 0
        var dirty = 0
        var join = 0
        var labelAtEnd = false
        func unchanged() -> Plan {
            Plan(closeAt: nil, cut: cut, backslash: 0, ticks: 0, closers: [], open: false, outerClosers: [], labelAtEnd: labelAtEnd)
        }

        func lookup(_ b: Int, _ end: Int) -> Bool {
            guard !definitions.isEmpty, b < end else { return false }
            let key = MarkdownLinkSyntax.normalizeLabel(text, start: b, end: end)
            return !key.isEmpty && definitions.destination(for: key) != nil
        }

        var p = 0
        scanning: while true {
            while p < e, !isSyntax(text[p]) { p &+= 1 }
            guard p < e else { break }
            let c = text[p]
            switch c {
            case UInt8(ascii: "<"):
                var tagAtEnd = false
                if let end = MarkdownInlineParser.scanAutolinkURI(text, at: p, end: e)
                    ?? MarkdownInlineParser.scanAutolinkEmail(text, at: p, end: e)
                    ?? MarkdownHTMLScanner.scanAny(text, at: p, end: e, noClose: &noClose, atEnd: &tagAtEnd)
                {
                    p = end
                    continue
                }
                // An unfinished tag on the last line goes with what follows. A `<`
                // right after a word is more likely a comparison or a generic type.
                if tagAtEnd, !(p != 0 && MarkdownByteScanner.isAlnum(text[p &- 1])),
                    MarkdownByteScanner.findByte(0x0A, in: text, from: p, end: e) >= e
                {
                    cut = p
                    break scanning
                }
                p &+= 1
            case UInt8(ascii: "\\"):
                // Only ASCII punctuation is escaped; an escaped `!` before `[` starts no image.
                p &+= 1 &+ (p &+ 1 < e && MarkdownByteScanner.isASCIIPunct(text[p &+ 1]) ? 1 : 0)
                escapeEnd = p
            case UInt8(ascii: ":"):
                p = inline.autolinkEnd(at: p, openBrackets: links.count &+ extra, www: false)
            case UInt8(ascii: "."):
                p = inline.autolinkEnd(at: p, openBrackets: links.count &+ extra, www: true)
            case UInt8(ascii: "["):
                // Past 64 brackets they are only counted.
                if links.count < 64 {
                    var meta = depth
                    if p != escapeEnd, p > 0, text[p &- 1] == UInt8(ascii: "!") { meta |= Bit.image }
                    if p &+ 1 < e, text[p &+ 1] == UInt8(ascii: "^") { meta |= Bit.footnote }
                    links.append(Bracket(offset: p &+ 1, meta: meta))
                } else {
                    extra &+= 1
                }
                p &+= 1
            case UInt8(ascii: "]"):
                let q = p &+ 1
                if extra > 0 {
                    extra &-= 1
                    p = q
                    continue
                }
                guard let top = links.last else {
                    p = q
                    continue
                }
                let meta = top.meta
                // Each path to `closed` sets `t`, the content offset after the link.
                var t = q
                var closed = false
                notLink: if meta & Bit.dead == 0 {
                    var c2: UInt8 = q < e ? text[q] : 0
                    if c2 == UInt8(ascii: "(") {
                        var pending = false
                        inlineForm: do {
                            t = MarkdownByteScanner.skipWhitespace(in: text, from: q &+ 1, end: e)
                            guard t < e else {
                                pending = true
                                break inlineForm
                            }
                            var destinationAtEnd = false
                            guard let dest = MarkdownLinkSyntax.scanDestination(text, from: t, end: e, atEnd: &destinationAtEnd)
                            else {
                                pending = destinationAtEnd
                                break inlineForm
                            }
                            t = MarkdownByteScanner.skipWhitespace(in: text, from: dest.after, end: e)
                            guard t < e else {
                                pending = true
                                break inlineForm
                            }
                            if t != dest.after {
                                let opener = text[t]
                                if let titleEnd = MarkdownLinkSyntax.scanTitle(text, from: t, end: e) {
                                    t = MarkdownByteScanner.skipWhitespace(in: text, from: titleEnd, end: e)
                                    guard t < e else {
                                        pending = true
                                        break inlineForm
                                    }
                                } else if opener == UInt8(ascii: "(") || opener == UInt8(ascii: "\"")
                                    || opener == UInt8(ascii: "'")
                                {
                                    // An opened title has not ended yet.
                                    pending = true
                                    break inlineForm
                                }
                            }
                            guard text[t] == UInt8(ascii: ")") else { break inlineForm }
                            t &+= 1
                            closed = true
                        }
                        if !closed {
                            if pending {
                                // The label keeps a placeholder for its unfinished destination.
                                cut = p
                                break scanning
                            }
                            // A title byte must not read as the next check's `[`.
                            c2 = UInt8(ascii: "(")
                        }
                    }
                    if !closed, c2 == UInt8(ascii: "[") {
                        // `[text][label` waits for its label the same way.
                        let from = q &+ 1
                        if MarkdownByteScanner.findByte(UInt8(ascii: "]"), in: text, from: from, end: e) >= e,
                            MarkdownByteScanner.findByte(UInt8(ascii: "["), in: text, from: from, end: e) >= e
                        {
                            cut = p
                            break scanning
                        }
                    }
                    if !closed {
                        // A reference, found as inline analysis finds it.
                        t = MarkdownLinkSyntax.scanLabel(text, from: q, end: e) ?? q
                        closed = t &- q > 2 ? lookup(q &+ 1, t &- 1) : lookup(top.offset, p)
                    }
                    // A delivery can stop between a label's `]` and its `(`. A
                    // label inside another bracket leaves that bracket unusable.
                    if !closed, q >= e, meta & (Bit.image | Bit.footnote) == 0, contentAtEOF {
                        if links.count > 1 {
                            links.removeSubrange(1...)
                        } else {
                            labelAtEnd = true
                            t = q
                            closed = true
                        }
                    }
                    guard closed else { break notLink }
                    // Emphasis opened in a link's text cannot close outside it.
                    depth = min(depth, meta & 255)
                    links.removeLast()
                    p = t
                    // A link cannot hold a link: brackets below it stop being links.
                    if meta & Bit.image == 0 {
                        for i in links.indices where links[i].meta & Bit.image == 0 { links[i].meta |= Bit.dead }
                    }
                    continue scanning
                }
                links.removeLast()
                p = q
            default:
                // `p..<q` is the run of `c`.
                var q = p &+ 1
                while q < e, text[q] == c { q &+= 1 }
                let n = q &- p
                if c == UInt8(ascii: "`") {
                    if let close = inline.closingBackticks(from: q, length: n) {
                        p = close
                        continue
                    }
                    // Without a closing run the rest is code and gets closing ticks.
                    // A run over 255 never pairs, and closing ticks would join a
                    // tick that ends the content.
                    if n <= 255, text[MarkdownByteScanner.trimSpacesBack(in: text, from: e, limit: q) &- 1] != c {
                        ticks = n
                        break scanning
                    }
                    p = q
                    continue
                }
                let (k, runFlags) = inline.runFlags(p, q)
                var flags = Int(runFlags)
                if c == UInt8(ascii: "~") {
                    // Three or more tildes are text.
                    if n > 2 {
                        p = q
                        continue
                    }
                } else if c == UInt8(ascii: "_"), k == 0 {
                    flags = 0
                }
                // `m` counts the delimiters of the run not used yet.
                var m = n
                if flags & 2 != 0 {
                    // Close as the parser does: the nearest opener of this byte the
                    // rule of three allows, then the ones below it while the run lasts.
                    var t = depth
                    var low = t
                    while t > 0 {
                        t &-= 1
                        let word = delims[t].word
                        guard word & 255 == Int(c) else { continue }
                        // The rule of three rejects these lengths when the closer can
                        // open or the opener can close.
                        let ruleOfThree = !n.isMultiple(of: 3) && ((word >> 16) &+ n).isMultiple(of: 3)
                        if ruleOfThree, (flags | word >> 8) & 1 != 0 { continue }
                        // A run that pairs at such lengths must stay unable to open.
                        if ruleOfThree { dirty = q }
                        low = t
                        depth = t
                        let remaining = delims[t].rem
                        if remaining > m {
                            // The opener outlasts the run. When one delimiter of a
                            // pair ends the content and closed nothing else, it may be
                            // the first half of the closer: the opener stays whole.
                            // Elsewhere tildes pair only at equal lengths.
                            let opener = t
                            if word >> 16 == 2 {
                                if q >= e, m == n {
                                    join = q
                                    m = 0
                                } else if c == UInt8(ascii: "~") {
                                    t &-= 1
                                }
                            }
                            delims[opener].rem = remaining &- m
                            depth = t &+ 1
                            m = 0
                            break
                        }
                        // A tilde run pairs once.
                        m = c == UInt8(ascii: "~") ? 0 : m &- remaining
                        if m == 0 { break }
                    }
                    // Emphasis opened before a bracket can close inside it.
                    for i in links.indices.reversed() {
                        let open = links[i].meta & 255
                        if open <= low { break }
                        links[i].meta = (links[i].meta & ~255) | Bit.lowered | min(depth, open)
                    }
                }
                if flags & 1 != 0, m != 0 {
                    // Past the limit the stack would no longer follow the parser.
                    guard depth < 64 else { return unchanged() }
                    // Not repaired: intraword runs (often arithmetic), runs over three,
                    // what a closer left, and a lone `~` (usually "about").
                    let noClosers = k == 0 || n > 3 || m != n || (c == UInt8(ascii: "~") && n == 1)
                    let word = Int(c) | (flags & 2) << 7 | (noClosers ? Bit.noClosers : 0) | (n % 3) << 16
                    delims.removeSubrange(depth...)
                    delims.append(Delimiter(word: word, rem: m, end: q))
                    depth &+= 1
                    // The closer of a `~~` below a tilde run that stays open would
                    // meet that run first and pair with nothing.
                    if noClosers, c == UInt8(ascii: "~") {
                        for i in 0..<(depth &- 1) where delims[i].word & 255 == Int(UInt8(ascii: "~")) {
                            delims[i].word |= Bit.noClosers
                        }
                    }
                }
                p = q
            }
        }

        // An unfinished image goes with what opened in its text. Below the open
        // images, the newest other bracket, if it can still be a link, keeps
        // its text and gets the placeholder in place of a partial destination.
        var open = 0
        var openDepth = 0
        for bracket in links.reversed() {
            openDepth = bracket.meta & 255
            if bracket.meta & Bit.image != 0 {
                cut = bracket.offset &- 2
                // The stack lost an opener to a closer in the image: nothing gets closers.
                if bracket.meta & Bit.lowered != 0 { depth = 0 }
                ticks = 0
                continue
            }
            if bracket.meta & (Bit.dead | Bit.footnote) == 0 {
                open = bracket.offset
                // A closer in this bracket's text took an opener before it.
                if bracket.meta & Bit.lowered != 0 { depth = openDepth }
                // After `][` the placeholder's `]` could end a reference's label.
                if open > 1, text[open &- 2] == UInt8(ascii: "]") { open = 0 }
            }
            break
        }
        // Closers that stay outside a pending link's text.
        var prev = open != 0 ? openDepth : 0

        // Closers go before trailing whitespace, so streamed spaces do not toggle
        // formatting. They cannot follow an unescaped `\`, which would escape
        // them: a `\` ending a word is replaced; one before or after whitespace
        // stays after the closers.
        var closeAt = cut
        var backslash = 0
        var at = 0
        var c: UInt8 = 0
        var glue = false
        placing: while true {
            closeAt = cut
            while true {
                while closeAt > 0 {
                    let scalar = MarkdownByteScanner.decodeUTF8Backward(text, before: closeAt, start: 0)
                    guard MarkdownByteScanner.isUnicodeWhitespace(scalar) else { break }
                    closeAt &-= UTF8.width(scalar)
                }
                // Inside an unfinished code span a `\` is code.
                guard ticks == 0 else { break }
                var q = closeAt
                while q > 0, text[q &- 1] == UInt8(ascii: "\\") { q &-= 1 }
                backslash = (closeAt &- q) & 1
                guard backslash != 0 else { break }
                // A `\` ending a bare URL is no escape, and closers before or after
                // it would change where the URL ends: wait for more bytes.
                if closeAt == inline.lastMarkEnd { return unchanged() }
                var before = closeAt < cut
                if !before {
                    if closeAt &- q == 1 {
                        before = q > 0 && MarkdownByteScanner.isUnicodeWhitespace(
                            MarkdownByteScanner.decodeUTF8Backward(text, before: q, start: 0))
                    }
                    // A placeholder right after it would be escaped, so it goes.
                    if before, open != 0 { cut = q }
                }
                guard before else { break }
                closeAt &-= 1
            }
            // The closers start at `at`. Openers at or after the cut went with it.
            at = closeAt &- backslash
            while depth > 0, delims[depth &- 1].end > cut { depth &-= 1 }
            prev = min(prev, depth)
            c = at > 0 ? text[at &- 1] : 0
            glue = false
            // `*`, `_` or `~`: closers join the run of delimiters typed before them.
            guard ticks == 0, at != 0, c == UInt8(ascii: "*") || c == UInt8(ascii: "_") || c == UInt8(ascii: "~") else {
                break
            }
            var q = at
            repeat { q &-= 1 } while q != 0 && text[q &- 1] == c
            let before = q == 0 ? " " : MarkdownByteScanner.decodeUTF8Backward(text, before: q, start: 0)
            // After punctuation the longer run may be able to open too.
            glue = MarkdownByteScanner.isUnicodePunct(before)
            // The run is an opener that is still open.
            let stillOpen = depth > 0 && at == delims[depth &- 1].end ? 1 : 0
            // A run after whitespace cannot close, and neither can an opener:
            // closers glued to it would turn the text literal. When openers below
            // it get closers, the run waits for the bytes that decide what it is.
            // A lone `~` (126 + 1) is text that closers can follow.
            if stillOpen == 1 || (MarkdownByteScanner.isUnicodeWhitespace(before) && Int(c) &+ (at &- q) != 127) {
                var live = depth &- stillOpen
                while live > prev, delims[live &- 1].word & Bit.noClosers != 0 { live &-= 1 }
                if live > prev {
                    cut = q
                    continue placing
                }
                if depth > prev { depth &-= stillOpen }
            }
            break
        }
        // A closing tick run would join a run that ends the content.
        if ticks != 0, c == UInt8(ascii: "`") {
            ticks = 0
            open = 0
            prev = 0
        }

        // Zero the closers of openers that cannot get them, last closer first.
        // `kind` is the byte of the current closer run, `length` its length,
        // `punctAfter` that punctuation follows it (another run, the
        // placeholder's `]`, or a kept `\`), so it may also open. The rule of
        // three rejects run length L for opener length n when L % 3 != 0 and
        // (L + n) % 3 == 0; `rejects` has a bit per n % 3 it applies to.
        // Delimiters typed just before the closers add an unknown length,
        // which the rule may reject too unless they are the first half of a
        // closer (`joined`). Two `~~` closers in a row are text.
        let joined = join != 0 && join == at
        let byteBefore = ticks != 0 ? UInt8(ascii: "`") : c
        var kind = 0
        var length = 0
        var punctAfter = false
        var rejects = 0
        for t in 0..<depth {
            if t == prev {
                // The placeholder separates the closers on its two sides.
                kind = 0
                punctAfter = open != 0 || (closeAt < cut && text[closeAt] == UInt8(ascii: "\\"))
            }
            let word = delims[t].word
            let byte = word & 255
            var drop = word & Bit.noClosers != 0
            if !drop {
                let same = byte == kind
                let from = punctAfter || (kind != 0 && !same)
                let to = delims[t].rem &+ (same ? length : 0)
                let remaining = (same ? rejects : 0) | ((from ? 1 : 0) | (word >> 8 & 1)) << (word >> 16)
                let glued = (word >> 8 & 1 != 0 || (from && glue)) && byte == Int(byteBefore) && !joined
                if (same && byte == Int(UInt8(ascii: "~"))) || glued || (remaining >> (3 &- to % 3)) & 1 != 0 {
                    drop = true
                } else {
                    punctAfter = from
                    length = to
                    rejects = remaining
                    kind = byte
                }
            }
            if drop { delims[t].rem = 0 }
        }
        // Leave an opener that gets closers on top of the pending link's text.
        while depth > prev, delims[depth &- 1].rem == 0 { depth &-= 1 }
        // Tildes typed right before a `~~` closer join its run: when they are its
        // first half one more tilde finishes it; else the closer would close
        // nothing, so it is not written.
        if depth > prev, delims[depth &- 1].word & 255 == Int(byteBefore),
            joined || byteBefore == UInt8(ascii: "~")
        {
            delims[depth &- 1].rem = joined ? 1 : 0
        }
        var closers: [UInt8] = []
        for d in delims[prev..<depth].reversed() {
            closers.append(contentsOf: repeatElement(UInt8(truncatingIfNeeded: d.word), count: d.rem))
        }
        // The delimiters typed before the closers paired at lengths the rule of
        // three allows only to a run that cannot open. After punctuation,
        // closers or a placeholder right after the run let it open: wait.
        if dirty == at, !joined, glue, !closers.isEmpty || ticks != 0 || open != 0 { return unchanged() }
        guard !closers.isEmpty || ticks != 0 || open != 0 || cut < text.count else { return unchanged() }
        // After `[label]:` a paragraph still waits for a destination, and
        // closers would be one.
        if c == UInt8(ascii: ":"), type == .paragraph, MarkdownLinkSyntax.scanLabel(text, from: 0, end: at) == at &- 1 {
            return unchanged()
        }
        var outer: [UInt8] = []
        if open != 0 {
            for d in delims[0..<prev].reversed() {
                outer.append(contentsOf: repeatElement(UInt8(truncatingIfNeeded: d.word), count: d.rem))
            }
        }
        return Plan(
            closeAt: closeAt, cut: cut, backslash: backslash, ticks: ticks, closers: closers, open: open != 0,
            outerClosers: outer, labelAtEnd: labelAtEnd)
    }

    // MARK: - Helpers

    /// `* . : < [ \ ] _ \` ~`: the bytes the repair scan stops at.
    @inline(__always)
    private static func isSyntax(_ c: UInt8) -> Bool {
        switch c {
        case UInt8(ascii: "*"), UInt8(ascii: "."), UInt8(ascii: ":"), UInt8(ascii: "<"), UInt8(ascii: "["),
            UInt8(ascii: "\\"), UInt8(ascii: "]"), UInt8(ascii: "_"), UInt8(ascii: "`"), UInt8(ascii: "~"):
            true
        default: false
        }
    }

    /// A paragraph or heading's lines, nil when they are one input range.
    private static func joinedContent(
        _ input: UnsafeBufferPointer<UInt8>, _ spans: ArraySlice<MarkdownBlockParser.LineSpan>
    ) -> [UInt8]? {
        var previousEnd = -1
        var contiguous = true
        for span in spans {
            if previousEnd >= 0, Int(span.start) != previousEnd &+ 1 || input[previousEnd] != 0x0A {
                contiguous = false
                break
            }
            previousEnd = Int(span.end)
        }
        guard !contiguous else { return nil }
        var out: [UInt8] = []
        for (i, span) in spans.enumerated() {
            if i > 0 { out.append(0x0A) }
            out.append(contentsOf: input[Int(span.start)..<Int(span.end)])
        }
        return out
    }

    private static func withContent<T>(
        _ input: UnsafeBufferPointer<UInt8>, from start: Int, length: Int, joined: [UInt8]?,
        _ body: (UnsafeBufferPointer<UInt8>) -> T
    ) -> T {
        if let joined { return joined.withUnsafeBufferPointer(body) }
        return body(UnsafeBufferPointer(rebasing: input[start..<(start &+ length)]))
    }

    /// The length of the list marker at `p` (a bullet, or up to nine digits and
    /// `.` or `)`) that ends at `lineEnd` or before a space, or 0.
    private static func listMarkerLength(_ input: UnsafeBufferPointer<UInt8>, at p: Int, lineEnd: Int) -> Int {
        guard p < lineEnd else { return 0 }
        var q = p &+ 1
        let c = input[p]
        if c != UInt8(ascii: "*"), c != UInt8(ascii: "+"), c != UInt8(ascii: "-") {
            q = p
            while q < lineEnd, MarkdownByteScanner.isDigit(input[q]), q &- p < 9 { q &+= 1 }
            guard q > p, q < lineEnd, input[q] == UInt8(ascii: ".") || input[q] == UInt8(ascii: ")") else { return 0 }
            q &+= 1
        }
        if q < lineEnd, !MarkdownByteScanner.isSpace(input[q]) { return 0 }
        return q &- p
    }
}
