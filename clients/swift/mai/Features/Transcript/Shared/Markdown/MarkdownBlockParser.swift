import Foundation

/// Pass 1: CommonMark + GFM block analysis over UTF-8 into flat records and
/// line spans, ported from `@pierre/words` `src/block.wat` and
/// `src/blockscan.wat` (Apache 2.0). No syntax tree: each leaf keeps the source
/// ranges of its lines, containers are an open and a close record around
/// their children, and the inline pass reads the ranges in place.
///
/// Root headings, fences and plain paragraph runs skip the general line
/// machine; a first-byte set stops a paragraph scan at possible block starts.
nonisolated struct MarkdownBlockParser {
    enum RecordKind: UInt8 {
        case none = 0
        case paragraph
        case heading
        case code
        case html
        case table
        case rule
        case quoteOpen
        case quoteClose
        case ulOpen
        case ulClose
        case olOpen
        case olClose
        case liOpen
        case liClose
    }

    enum Flags {
        /// The leaf's content holds no inline syntax.
        static let plainInline: UInt8 = 1 << 0
        static let fenced: UInt8 = 1 << 1
        /// A list item starting with a GFM task marker (`[ ]`, `[x]`, `[X]`).
        static let task: UInt8 = 1 << 2
        static let taskDone: UInt8 = 1 << 3
        /// CommonMark 5.3: a loose list (blank line between items or direct item blocks).
        static let looseList: UInt8 = 1 << 4
    }

    struct LineSpan {
        var start: Int32
        var end: Int32
        /// Virtual leading spaces from a partially consumed tab (CommonMark 2.2).
        var padSpaces: UInt8 = 0
    }

    struct Record {
        var kind: RecordKind
        var flags: UInt8 = 0
        /// Heading level, ordered-list start index, fence info start, table alignment start, or rule start.
        var data: Int32 = 0
        /// Fence info end, table column count, or rule end.
        var aux: Int32 = 0
        var lineStart: Int32 = 0
        var lineCount: Int32 = 0
    }

    struct Result {
        var records: [Record]
        var lines: [LineSpan]
        var tableAlignments: [MarkdownTable.Alignment]
        /// Normalized label to unescaped destination; the first definition wins.
        var linkDefinitions: [String: String]
        /// The labels of `linkDefinitions` in document order.
        var definitionOrder: [String]
        /// The last safe append boundary: a newline-terminated blank line at
        /// document depth with no leaf open, which later bytes cannot cross.
        var boundary: Boundary
        /// The newest leaf (completion repairs it), or -1.
        var lastLeaf: Int
        /// Whether the last leaf is the first block of a list item still open at the end.
        var lastLeafStartsItem: Bool
    }

    struct Boundary {
        /// Bytes before the boundary.
        var offset = 0
        /// Records before the boundary: whole top-level blocks.
        var records = 0
        /// Link definitions before the boundary.
        var definitions = 0
    }

    private struct Container {
        var kind: RecordKind // .quoteOpen, .ulOpen, .olOpen, .liOpen
        var markerChar: UInt8
        var indent: Int
        var children: Int
        var recordIndex: Int
        var sawBlankAfterChild = false
        var isLoose = false
    }

    private static let maxNesting = 250
    private static let maxTableAutoCells = 524_288

    private let bytes: UnsafeBufferPointer<UInt8>
    private let base: UnsafePointer<UInt8>
    private let eof: Int
    /// The input may still grow: a fence whose opening line has not ended yet
    /// shows nothing, since its info string can still change.
    private let incomplete: Bool

    private var records: [Record] = []
    private var lines: [LineSpan] = []
    private var tableAlignments: [MarkdownTable.Alignment] = []
    private var linkDefinitions: [String: String] = [:]
    private var definitionOrder: [String] = []
    private var boundary = Boundary()

    private var containers: [Container] = []
    private var leaf: RecordKind = .none
    private var leafRecordIndex: Int = -1
    private var codeFenceChar: UInt8 = 0
    private var codeFenceLength: Int = 0
    private var codeFenceIndent: Int = 0
    private var htmlKind: Int = 0
    private var tableAutoCells: Int = 0

    // Per-line cursor state (matching CommonMark spec / @pierre/words)
    private var pos: Int = 0
    private var col: Int = 0
    private var partialTab: Bool = false
    private var fns: Int = 0
    private var fnsCol: Int = 0
    private var indent: Int = 0
    private var isBlank: Bool = false
    private var lineEnd: Int = 0
    private var allMatched: Bool = true
    private var lastMatched: Int = 0
    private var closedUnmatched: Bool = false
    private var skipLine: Bool = false
    private var hrKill: Int = 0

    static func parse(_ bytes: UnsafeBufferPointer<UInt8>, incomplete: Bool = false) -> Result {
        guard let base = bytes.baseAddress, !bytes.isEmpty else {
            return Result(
                records: [], lines: [], tableAlignments: [], linkDefinitions: [:], definitionOrder: [],
                boundary: Boundary(), lastLeaf: -1, lastLeafStartsItem: false)
        }
        var parser = MarkdownBlockParser(bytes: bytes, base: base, eof: bytes.count, incomplete: incomplete)
        let lastLeafStartsItem = parser.run()
        return Result(
            records: parser.records, lines: parser.lines, tableAlignments: parser.tableAlignments,
            linkDefinitions: parser.linkDefinitions, definitionOrder: parser.definitionOrder,
            boundary: parser.boundary, lastLeaf: parser.leafRecordIndex, lastLeafStartsItem: lastLeafStartsItem)
    }

    private init(bytes: UnsafeBufferPointer<UInt8>, base: UnsafePointer<UInt8>, eof: Int, incomplete: Bool) {
        self.bytes = bytes
        self.base = base
        self.eof = eof
        self.incomplete = incomplete
        let estBlocks = max(8, eof / 96)
        records.reserveCapacity(estBlocks)
        lines.reserveCapacity(estBlocks * 2)
        containers.reserveCapacity(8)
    }

    // MARK: - Main line loop

    /// Returns whether the last leaf is the first block of a list item still open at the end.
    private mutating func run() -> Bool {
        // A UTF-8 byte order mark is not content.
        var blockStart = eof >= 3 && base[0] == 0xEF && base[1] == 0xBB && base[2] == 0xBF ? 3 : 0
        while blockStart < eof {
            if containers.isEmpty {
                let first = base[blockStart]
                // A document-level empty line closes ordinary leaves at once.
                if first == 0x0A, blankEndsLeaf() {
                    closeLeaf()
                    blockStart &+= 1
                    markBoundary(at: blockStart)
                    continue
                }
                if leaf == .none {
                    if first == UInt8(ascii: "#"), let next = tryRootHeading(from: blockStart) {
                        blockStart = next
                        continue
                    }
                    if first == UInt8(ascii: "`") || first == UInt8(ascii: "~"), let next = tryRootFence(from: blockStart) {
                        blockStart = next
                        continue
                    }
                    if !MarkdownByteScanner.mayStartBlock(first) {
                        blockStart = startPlainParagraphRun(from: blockStart)
                        continue
                    }
                }
            }
            if leaf == .code, containers.isEmpty, codeFenceChar != 0, codeFenceIndent == 0,
                let next = tryCodeRun(from: blockStart)
            {
                blockStart = next
                continue
            }

            let curLineEnd = MarkdownByteScanner.findLineEnd(bytes, from: blockStart, end: eof)
            lineEnd = curLineEnd
            pos = blockStart
            col = 0
            partialTab = false
            fns = -1
            fnsCol = 0
            allMatched = true
            lastMatched = 0
            closedUnmatched = false
            skipLine = false
            processLine()
            let next = MarkdownByteScanner.lineAfter(lineEnd, in: bytes, end: eof)
            // Only a newline-terminated blank line at document depth with no
            // leaf open is a boundary: EOF closures and open lists stay mutable.
            if containers.isEmpty, leaf == .none, curLineEnd < eof,
                MarkdownByteScanner.skipSpaces(in: bytes, from: blockStart, end: curLineEnd) >= curLineEnd
            {
                markBoundary(at: next)
            }
            blockStart = next
        }

        if incomplete, leaf == .code, codeFenceChar != 0, records[leafRecordIndex].lineCount == 0,
            base[eof &- 1] != 0x0A, base[eof &- 1] != 0x0D
        {
            records[leafRecordIndex].kind = .none
        }
        closeLeaf()
        let startsItem = containers.last.map { $0.kind == .liOpen && $0.children == 1 } ?? false
        while !containers.isEmpty { closeContainer() }
        return startsItem
    }

    private mutating func markBoundary(at offset: Int) {
        boundary = Boundary(offset: offset, records: records.count, definitions: definitionOrder.count)
    }

    /// The three CommonMark phases for one line: match open containers, open
    /// new blocks, add the rest to the deepest open block. At document depth an
    /// open paragraph or no leaf skips the container walk.
    private mutating func processLine() {
        if containers.isEmpty {
            findFirstNonspace()
            if isBlank {
                if blankEndsLeaf() {
                    closeLeaf()
                    return
                }
            } else if leaf == .paragraph {
                lastMatched = 1
                if !tryParagraphContinuation() {
                    openNewBlocks()
                    addTextToContainer()
                }
                return
            } else if leaf == .none {
                openNewBlocks()
                addTextToContainer()
                return
            }
        }
        if matchOpenBlocks() { return }
        if !containers.isEmpty, leaf == .paragraph, tryParagraphContinuation() { return }
        openNewBlocks()
        addTextToContainer()
    }

    // MARK: - Root fast paths

    private mutating func tryRootHeading(from start: Int) -> Int? {
        var p = start
        var level = 0
        while p < eof, base[p] == UInt8(ascii: "#") {
            level &+= 1
            p &+= 1
            if level > 6 { return nil }
        }
        if p < eof {
            let b = base[p]
            if b != 0x20, b != 0x09, b != 0x0A, b != 0x0D { return nil }
        }
        let end = MarkdownByteScanner.findLineEnd(bytes, from: p, end: eof)
        let contentStart = MarkdownByteScanner.skipSpaces(in: bytes, from: p, end: end)
        let contentEnd = atxContentEnd(from: contentStart, end: end)
        let lineIdx = Int32(lines.count)
        let hasContent = contentEnd > contentStart
        leafRecordIndex = records.count
        var flags: UInt8 = 0
        if hasContent {
            lines.append(LineSpan(start: Int32(contentStart), end: Int32(contentEnd)))
            if MarkdownByteScanner.findInlineSyntax(in: bytes, from: contentStart, end: contentEnd) >= contentEnd {
                flags |= Flags.plainInline
            }
        }
        records.append(
            Record(
                kind: .heading, flags: flags, data: Int32(level), aux: 0,
                lineStart: lineIdx, lineCount: hasContent ? 1 : 0))
        return MarkdownByteScanner.lineAfter(end, in: bytes, end: eof)
    }

    private mutating func tryRootFence(from start: Int) -> Int? {
        let end = MarkdownByteScanner.findLineEnd(bytes, from: start, end: eof)
        lineEnd = end
        guard let len = scanOpenFence(at: start) else { return nil }
        let infoStart = MarkdownByteScanner.skipSpaces(in: bytes, from: start &+ len, end: end)
        let infoEnd = MarkdownByteScanner.trimSpacesBack(in: bytes, from: end, limit: infoStart)
        leafRecordIndex = records.count
        records.append(
            Record(
                kind: .code, flags: Flags.fenced, data: Int32(infoStart), aux: Int32(infoEnd),
                lineStart: Int32(lines.count), lineCount: 0))
        leaf = .code
        codeFenceChar = base[start]
        codeFenceLength = len
        codeFenceIndent = 0
        return MarkdownByteScanner.lineAfter(end, in: bytes, end: eof)
    }

    /// Adds an unindented top-level fence body up to a line that may close it,
    /// and consumes a closing line. A tab before a fence byte stops the body so
    /// the general loop measures it; a line ending in `\r` gets its own span so
    /// the code text normalizes it. Returns the next line start, or nil when
    /// nothing was consumed.
    private mutating func tryCodeRun(from start: Int) -> Int? {
        var p = start
        var stop = start
        var line = start
        var closeLineEnd = eof
        var closed = false
        while true {
            stop = MarkdownByteScanner.findCodeRunEnd(in: bytes, from: stop, end: eof, fence: codeFenceChar)
            line = stop
            guard stop < eof else { break }
            if base[stop] == 0x0D {
                appendCodeRange(start: p, end: stop)
                p = MarkdownByteScanner.lineAfter(stop, in: bytes, end: eof)
                stop = p
                if p < eof { continue }
                return eof
            }
            line = MarkdownByteScanner.lineStartBefore(stop, limit: p, in: bytes)
            let end = MarkdownByteScanner.findLineEnd(bytes, from: stop, end: eof)
            let afterSpaces = MarkdownByteScanner.runEnd(of: 0x20, in: bytes, from: line, end: stop)
            if afterSpaces == stop {
                if stop &- line <= 3, closesFence(at: stop, end: end) {
                    closed = true
                    closeLineEnd = end
                    break
                }
            } else if base[afterSpaces] == 0x09 {
                break
            }
            stop = end
        }
        // The body is the lines before the stopping line, without its last line feed.
        if line > p { appendCodeRange(start: p, end: base[line &- 1] == 0x0A ? line &- 1 : line) }
        if closed {
            closeLeaf()
            return MarkdownByteScanner.lineAfter(closeLineEnd, in: bytes, end: eof)
        }
        if line >= eof { return eof }
        return line > p || p != start ? line : nil
    }

    private mutating func appendCodeRange(start: Int, end: Int) {
        let count = records[leafRecordIndex].lineCount
        if count > 0 {
            let lastIdx = Int(records[leafRecordIndex].lineStart &+ count &- 1)
            let prevEnd = Int(lines[lastIdx].end)
            if lines[lastIdx].padSpaces == 0, start == prevEnd &+ 1, prevEnd < eof, base[prevEnd] == 0x0A {
                lines[lastIdx].end = Int32(end)
                return
            }
        }
        lines.append(LineSpan(start: Int32(start), end: Int32(end)))
        records[leafRecordIndex].lineCount &+= 1
    }

    /// Scans a root-level paragraph run in one SIMD pass, keeping the last line separate
    /// so it can still convert into a GFM table header if the next line is a delimiter row.
    private mutating func startPlainParagraphRun(from start: Int) -> Int {
        let run = MarkdownByteScanner.findPlainParagraphRun(in: bytes, from: start, end: eof)
        let firstLineIdx = Int32(lines.count)
        let flags: UInt8 = run.isPlainInline ? Flags.plainInline : 0
        var spanCount: Int32 = 1
        if run.lastLineStart > start {
            lines.append(LineSpan(start: Int32(start), end: Int32(run.lastLineStart &- 1)))
            spanCount = 2
        }
        lines.append(LineSpan(start: Int32(run.lastLineStart), end: Int32(run.lastLineEnd)))
        leafRecordIndex = records.count
        records.append(Record(kind: .paragraph, flags: flags, lineStart: firstLineIdx, lineCount: spanCount))
        leaf = .paragraph
        return MarkdownByteScanner.lineAfter(run.lastLineEnd, in: bytes, end: eof)
    }

    private mutating func tryParagraphContinuation() -> Bool {
        guard leaf == .paragraph, !isBlank else { return false }
        guard fns < lineEnd, !MarkdownByteScanner.mayStartBlock(base[fns]) else { return false }
        advanceToFns(0)
        addLineToLeaf()
        if containers.isEmpty, lineEnd < eof {
            appendParagraphRun(from: MarkdownByteScanner.lineAfter(lineEnd, in: bytes, end: eof))
        }
        return true
    }

    private mutating func appendParagraphRun(from start: Int) {
        var p = start
        while p < eof, !MarkdownByteScanner.mayStartBlock(base[p]) {
            let end = MarkdownByteScanner.findLineEnd(bytes, from: p, end: eof)
            pos = p
            lineEnd = end
            partialTab = false
            addLineToLeaf()
            if end >= eof || base[end] != 0x0A { break }
            p = end &+ 1
        }
    }

    // MARK: - Cursor & Indentation

    private mutating func findFirstNonspace() {
        if fns < pos {
            var cur = pos
            var curCol = col
            while cur < lineEnd {
                let b = base[cur]
                if b == 0x20 {
                    curCol &+= 1
                } else if b == 0x09 {
                    curCol = (curCol | 3) &+ 1
                } else {
                    break
                }
                cur &+= 1
            }
            fns = cur
            fnsCol = curCol
        }
        indent = fnsCol &- col
        isBlank = fns >= lineEnd
    }

    private mutating func advance(_ count: Int) {
        var p = pos
        var curCol = col
        let target = curCol &+ count
        partialTab = false
        if fns &- p != indent {
            while curCol < target, p < lineEnd {
                let b = base[p]
                if b == 0x09 {
                    let nextCol = (curCol | 3) &+ 1
                    if nextCol > target {
                        partialTab = true
                        break
                    }
                    curCol = nextCol
                } else {
                    curCol &+= 1
                }
                p &+= 1
            }
            pos = p
            col = target
        } else {
            pos &+= count
            col = target
        }
    }

    private mutating func advanceToFns(_ extra: Int) {
        pos = fns &+ extra
        col = fnsCol &+ extra
        partialTab = false
    }

    private mutating func skipMarkerSpace() {
        guard pos < lineEnd else { return }
        let b = base[pos]
        if b == 0x20 {
            pos &+= 1
            col &+= 1
            partialTab = false
        } else if b == 0x09 {
            let isPartial = (col & 3) != 3
            if !isPartial { pos &+= 1 }
            col &+= 1
            partialTab = isPartial
        }
    }

    private mutating func matchIndent(_ cols: Int, noBlank: Bool) -> Bool {
        if isBlank, noBlank { return false }
        if indent >= cols {
            advance(cols)
            return true
        }
        if isBlank {
            advanceToFns(0)
            return true
        }
        return false
    }

    // MARK: - Phase 1: Match open blocks

    private mutating func matchOpenBlocks() -> Bool {
        var matched = 0
        for i in containers.indices {
            let c = containers[i]
            if c.kind == .ulOpen || c.kind == .olOpen {
                matched = i &+ 1
                continue
            }
            findFirstNonspace()
            if c.kind == .quoteOpen {
                guard indent <= 3, fns < lineEnd, base[fns] == UInt8(ascii: ">") else {
                    allMatched = false
                    break
                }
                advanceToFns(1)
                skipMarkerSpace()
                matched = i &+ 1
            } else {
                // List item requires its content indent (at most 1 leading blank line if empty).
                guard matchIndent(c.indent, noBlank: c.children == 0) else {
                    allMatched = false
                    break
                }
                matched = i &+ 1
            }
        }
        lastMatched = matched

        if allMatched, leaf != .none {
            findFirstNonspace()
            switch leaf {
            case .code:
                if codeFenceChar != 0 {
                    if indent <= 3, fns < lineEnd, base[fns] == codeFenceChar, closesFence(at: fns, end: lineEnd) {
                        closeLeaf()
                        return true
                    }
                    let strip = min(codeFenceIndent, indent)
                    if strip > 0 { advance(strip) }
                } else if !matchIndent(4, noBlank: false) {
                    allMatched = false
                    return false
                }
            case .html:
                if isBlank, htmlKind > 5 {
                    allMatched = false
                    return false
                }
            case .table:
                if isBlank || tableAutoCells > Self.maxTableAutoCells {
                    allMatched = false
                    return false
                }
                if indent < 4, fns < lineEnd, base[fns] == UInt8(ascii: "|") {
                    advanceToFns(0)
                    addLineToLeaf()
                    return true
                }
            case .paragraph:
                if isBlank {
                    allMatched = false
                    return false
                }
            default:
                break
            }
            lastMatched = containers.count &+ 1
        }
        return false
    }

    // MARK: - Phase 2: Open new blocks

    private mutating func openNewBlocks() {
        var maybeLazy = leaf == .paragraph
        var contKind: RecordKind =
            if lastMatched == 0 {
                .none
            } else if lastMatched > containers.count {
                leaf
            } else {
                containers[lastMatched &- 1].kind
            }

        while contKind != .code, contKind != .html {
            findFirstNonspace()

            // Indented code block (4+ columns, cannot interrupt a paragraph).
            if indent >= 4 {
                if maybeLazy || isBlank { break }
                closeUnmatchedBlocks(newBlock: true)
                advance(4)
                prepareLeafParent()
                openLeaf(.code)
                codeFenceChar = 0
                break
            }

            if isBlank { break }
            let ch = base[fns]

            // Block quote
            if ch == UInt8(ascii: ">"), spineDepth() < Self.maxNesting {
                closeUnmatchedBlocks(newBlock: true)
                advanceToFns(1)
                skipMarkerSpace()
                prepareLeafParent()
                pushContainer(.quoteOpen, marker: 0, indent: 0, startIndex: 0)
                contKind = .quoteOpen
                maybeLazy = false
                continue
            }

            // ATX heading
            if ch == UInt8(ascii: "#"), let (level, consumed) = scanAtxStart(at: fns) {
                closeUnmatchedBlocks(newBlock: true)
                advanceToFns(consumed)
                prepareLeafParent()
                let save = pos
                let headEnd = atxContentEnd(from: save, end: lineEnd)
                openLeaf(.heading)
                records[leafRecordIndex].data = Int32(level)
                let savedEnd = lineEnd
                lineEnd = headEnd
                if headEnd > save { addLineToLeaf() }
                closeLeaf()
                lineEnd = savedEnd
                pos = headEnd
                skipLine = true
                break
            }

            // Fenced code block
            if ch == UInt8(ascii: "`") || ch == UInt8(ascii: "~"), let fenceLen = scanOpenFence(at: fns) {
                closeUnmatchedBlocks(newBlock: true)
                let markerIndent = indent
                advanceToFns(fenceLen)
                prepareLeafParent()
                openLeaf(.code)
                records[leafRecordIndex].flags |= Flags.fenced
                codeFenceChar = ch
                codeFenceLength = fenceLen
                codeFenceIndent = markerIndent
                let infoStart = MarkdownByteScanner.skipSpaces(in: bytes, from: pos, end: lineEnd)
                let infoEnd = MarkdownByteScanner.trimSpacesBack(in: bytes, from: lineEnd, limit: infoStart)
                records[leafRecordIndex].data = Int32(infoStart)
                records[leafRecordIndex].aux = Int32(infoEnd)
                pos = lineEnd
                skipLine = true
                break
            }

            // HTML block
            if ch == UInt8(ascii: "<"),
                let kind = scanHtmlStart(at: fns, allowType7: contKind != .paragraph && !maybeLazy)
            {
                closeUnmatchedBlocks(newBlock: true)
                prepareLeafParent()
                openLeaf(.html)
                htmlKind = kind
                break
            }

            // Setext heading underline (only when matching an open paragraph)
            if contKind == .paragraph, ch == UInt8(ascii: "=") || ch == UInt8(ascii: "-") {
                let runEnd = MarkdownByteScanner.runEnd(of: ch, in: bytes, from: fns, end: lineEnd)
                if MarkdownByteScanner.skipSpaces(in: bytes, from: runEnd, end: lineEnd) >= lineEnd {
                    rtrimLeafLines(keepSpaces: false)
                    resolveLinkDefsOnLeaf()
                    if records[leafRecordIndex].lineCount > 0 {
                        records[leafRecordIndex].kind = .heading
                        records[leafRecordIndex].data = ch == UInt8(ascii: "=") ? 1 : 2
                        leaf = .none
                        pos = lineEnd
                        skipLine = true
                        break
                    } else {
                        // Paragraph was purely link definitions; close it and re-test line as thematic break / list.
                        closeLeaf()
                        contKind = containers.last?.kind ?? .none
                        maybeLazy = false
                    }
                }
            }

            // Thematic break
            if ch == UInt8(ascii: "-") || ch == UInt8(ascii: "*") || ch == UInt8(ascii: "_"),
                scanThematicBreak(at: fns)
            {
                closeUnmatchedBlocks(newBlock: true)
                prepareLeafParent()
                let spellEnd = MarkdownByteScanner.trimSpacesBack(in: bytes, from: lineEnd, limit: fns)
                records.append(Record(kind: .rule, data: Int32(fns), aux: Int32(spellEnd)))
                noteChildAdded()
                pos = lineEnd
                skipLine = true
                break
            }

            // List item
            if let marker = scanListMarker(at: fns, interruptsParagraph: contKind == .paragraph) {
                let depth = spineDepth()
                let expectedKind: RecordKind = marker.isOrdered ? .olOpen : .ulOpen
                let matchesEnclosingList: Bool
                if depth > 0 {
                    let top = containers[depth &- 1]
                    matchesEnclosingList = top.kind == expectedKind && top.markerChar == marker.markerChar
                } else {
                    matchesEnclosingList = false
                }
                let neededLevels = matchesEnclosingList ? 1 : 2
                if depth &+ neededLevels <= Self.maxNesting {
                    closeUnmatchedBlocks(newBlock: true)
                    let markerIndent = indent
                    advanceToFns(marker.length)
                    findFirstNonspace()
                    let padding: Int
                    if isBlank || indent < 1 || indent > 4 {
                        padding = marker.length &+ 1
                        skipMarkerSpace()
                    } else {
                        padding = marker.length &+ indent
                        advanceToFns(0)
                    }
                    if !matchesEnclosingList {
                        prepareLeafParent()
                        pushContainer(expectedKind, marker: marker.markerChar, indent: 0, startIndex: marker.startIndex)
                    }
                    pushContainer(.liOpen, marker: marker.markerChar, indent: markerIndent &+ padding, startIndex: 0)
                    contKind = .liOpen
                    maybeLazy = false
                    continue
                }
            }

            // GFM pipe table (tried after core starts so `- | -` is a list item)
            if contKind == .paragraph, leaf == .paragraph,
                ch == UInt8(ascii: "|") || ch == UInt8(ascii: "-") || ch == UInt8(ascii: ":"),
                let alignments = scanTableDelimiterRow(at: fns)
            {
                let count = Int(records[leafRecordIndex].lineCount)
                if count > 0 {
                    let headerSpan = lines[Int(records[leafRecordIndex].lineStart) &+ count &- 1]
                    let headerStart = Int(headerSpan.start)
                    let headerEnd = MarkdownByteScanner.trimSpacesBack(
                        in: bytes, from: Int(headerSpan.end), limit: headerStart)
                    if countRowCells(from: headerStart, end: headerEnd) == alignments.count {
                        // Detach the last line from the paragraph as the table header.
                        records[leafRecordIndex].lineCount &-= 1
                        closeLeaf()
                        let alignStart = Int32(tableAlignments.count)
                        tableAlignments.append(contentsOf: alignments)
                        openLeaf(.table)
                        tableAutoCells = 0
                        records[leafRecordIndex].data = alignStart
                        records[leafRecordIndex].aux = Int32(alignments.count)
                        lines.append(LineSpan(start: Int32(headerStart), end: Int32(headerEnd)))
                        records[leafRecordIndex].lineCount = 1
                        pos = lineEnd
                        skipLine = true
                        break
                    }
                }
            }

            break
        }
    }

    // MARK: - Phase 3: Attach text to deepest open block

    private mutating func addTextToContainer() {
        findFirstNonspace()
        if skipLine { return }

        // Lazy paragraph continuation.
        let isLazy = leaf == .paragraph && !allMatched && !isBlank && !closedUnmatched
        if !isLazy {
            closeUnmatchedBlocks(newBlock: false)
            if leaf == .code || leaf == .html {
                addLineToLeaf()
                if leaf == .html, scanHtmlBlockEnd(kind: htmlKind, from: fns) {
                    closeLeaf()
                }
                return
            }
            if isBlank {
                if !containers.isEmpty, containers[containers.count &- 1].children > 0 {
                    containers[containers.count &- 1].sawBlankAfterChild = true
                }
                return
            }
            if leaf == .none {
                prepareLeafParent()
                openLeaf(.paragraph)
            }
        }
        advanceToFns(0)
        addLineToLeaf()
    }

    // MARK: - Block lifecycle

    private func blankEndsLeaf() -> Bool {
        leaf != .code && (leaf != .html || htmlKind > 5)
    }

    private func spineDepth() -> Int {
        closedUnmatched ? containers.count : min(containers.count, lastMatched)
    }

    private mutating func noteChildAdded() {
        guard !containers.isEmpty else { return }
        let idx = containers.count &- 1
        if containers[idx].sawBlankAfterChild {
            containers[idx].sawBlankAfterChild = false
            if containers[idx].kind == .ulOpen || containers[idx].kind == .olOpen {
                containers[idx].isLoose = true
            } else if containers[idx].kind == .liOpen, idx > 0,
                containers[idx &- 1].kind == .ulOpen || containers[idx &- 1].kind == .olOpen
            {
                containers[idx &- 1].isLoose = true
            }
        }
        containers[idx].children &+= 1
    }

    private mutating func openLeaf(_ kind: RecordKind) {
        leafRecordIndex = records.count
        records.append(Record(kind: kind, lineStart: Int32(lines.count), lineCount: 0))
        leaf = kind
        noteChildAdded()
    }

    private mutating func addLineToLeaf() {
        records[leafRecordIndex].flags &= ~Flags.plainInline
        var beg = pos
        var pad: UInt8 = 0
        if partialTab {
            pad = UInt8(4 &- (col & 3))
            beg &+= 1
        }
        if leaf == .table {
            let cols = Int(records[leafRecordIndex].aux)
            let supplied = countRowCells(from: beg, end: lineEnd)
            if supplied < cols { tableAutoCells &+= cols &- supplied }
        }
        if leaf == .code, codeFenceChar != 0, pad == 0, records[leafRecordIndex].lineCount > 0 {
            let lastIdx = Int(records[leafRecordIndex].lineStart &+ records[leafRecordIndex].lineCount &- 1)
            let prevEnd = Int(lines[lastIdx].end)
            if lines[lastIdx].padSpaces == 0, beg == prevEnd &+ 1, prevEnd < eof, base[prevEnd] == 0x0A {
                lines[lastIdx].end = Int32(lineEnd)
                return
            }
        }
        lines.append(LineSpan(start: Int32(beg), end: Int32(lineEnd), padSpaces: pad))
        records[leafRecordIndex].lineCount &+= 1
    }

    private mutating func closeLeaf() {
        guard leaf != .none else { return }
        let kind = leaf
        leaf = .none
        // Paragraphs and table rows lose trailing spaces; indented code keeps
        // them but not its trailing blank lines. (Heading lines are trimmed
        // when they are read.)
        if kind == .paragraph || kind == .table || (kind == .code && codeFenceChar == 0) {
            let trimmedBlank = rtrimLeafLines(keepSpaces: kind == .code)
            // CommonMark §5.3: trailing blank lines stripped from an indented
            // code block inside a list item still separate it from what follows.
            if kind == .code, codeFenceChar == 0, trimmedBlank,
                !containers.isEmpty, containers[containers.count &- 1].children > 0
            {
                containers[containers.count &- 1].sawBlankAfterChild = true
            }
        }
        if kind == .paragraph {
            resolveLinkDefsOnLeaf()
            extractTaskMarkerIfPresent()
            if records[leafRecordIndex].lineCount == 0 {
                records[leafRecordIndex].kind = .none
            }
        }
    }

    /// GFM 5.3 task list marker (`[ ]`, `[x]`, `[X]`) at the start of a list
    /// item's first paragraph, matching `@pierre/words` `block.wat`.
    private mutating func extractTaskMarkerIfPresent() {
        let count = Int(records[leafRecordIndex].lineCount)
        guard count > 0, let top = containers.last, top.kind == .liOpen, top.children == 1 else { return }
        let lineIdx = Int(records[leafRecordIndex].lineStart)
        let beg = Int(lines[lineIdx].start)
        let end = Int(lines[lineIdx].end)
        guard beg &+ 3 <= end, base[beg] == UInt8(ascii: "["), base[beg &+ 2] == UInt8(ascii: "]") else { return }
        let mark = base[beg &+ 1]
        let isSpace = mark == 0x20
        let isDone = mark | 0x20 == UInt8(ascii: "x")
        guard isSpace || isDone else { return }
        // Marker must be followed by a space/tab, or end the first line only when more lines follow.
        let validAfter = beg &+ 3 == end ? count >= 2 : MarkdownByteScanner.isSpace(base[beg &+ 3])
        guard validAfter else { return }
        records[top.recordIndex].flags |= Flags.task | (isDone ? Flags.taskDone : 0)
        if beg &+ 3 < end {
            lines[lineIdx].start = Int32(MarkdownByteScanner.skipSpaces(in: bytes, from: beg &+ 3, end: end))
        } else {
            records[leafRecordIndex].lineStart &+= 1
            records[leafRecordIndex].lineCount &-= 1
        }
    }

    @discardableResult
    private mutating func rtrimLeafLines(keepSpaces: Bool) -> Bool {
        let baseIdx = Int(records[leafRecordIndex].lineStart)
        let originalCount = Int(records[leafRecordIndex].lineCount)
        var count = originalCount
        while count > 0 {
            let idx = baseIdx &+ count &- 1
            let beg = Int(lines[idx].start)
            let end = Int(lines[idx].end)
            let trimmed = MarkdownByteScanner.trimSpacesBack(in: bytes, from: end, limit: beg)
            if !keepSpaces {
                lines[idx].end = Int32(trimmed)
            }
            if trimmed > beg { break }
            count &-= 1
            records[leafRecordIndex].lineCount = Int32(count)
        }
        return count < originalCount
    }

    private mutating func prepareLeafParent() {
        while let top = containers.last, top.kind == .ulOpen || top.kind == .olOpen {
            closeContainer()
        }
    }

    private mutating func pushContainer(_ kind: RecordKind, marker: UInt8, indent: Int, startIndex: Int) {
        let recordIndex = records.count
        records.append(Record(kind: kind, data: Int32(startIndex)))
        noteChildAdded()
        containers.append(Container(kind: kind, markerChar: marker, indent: indent, children: 0, recordIndex: recordIndex))
    }

    private mutating func closeContainer() {
        guard let top = containers.popLast() else { return }
        if top.isLoose, top.kind == .ulOpen || top.kind == .olOpen {
            records[top.recordIndex].flags |= Flags.looseList
        }
        if top.sawBlankAfterChild, top.kind != .quoteOpen,
            !containers.isEmpty, containers[containers.count &- 1].children > 0
        {
            containers[containers.count &- 1].sawBlankAfterChild = true
        }
        let closer: RecordKind =
            switch top.kind {
            case .quoteOpen: .quoteClose
            case .ulOpen: .ulClose
            case .olOpen: .olClose
            case .liOpen: .liClose
            default: .none
            }
        records.append(Record(kind: closer))
    }

    private mutating func closeUnmatchedBlocks(newBlock: Bool) {
        guard !closedUnmatched else { return }
        closedUnmatched = true
        if newBlock || lastMatched <= containers.count {
            closeLeaf()
        }
        while containers.count > lastMatched {
            closeContainer()
        }
    }

    // MARK: - Block start scanners

    private func scanAtxStart(at p: Int) -> (level: Int, consumed: Int)? {
        var i = p
        while i < lineEnd, base[i] == UInt8(ascii: "#") { i &+= 1 }
        let level = i &- p
        guard level >= 1, level <= 6 else { return nil }
        if i < lineEnd {
            guard MarkdownByteScanner.isSpace(base[i]) else { return nil }
            i = MarkdownByteScanner.skipSpaces(in: bytes, from: i, end: lineEnd)
        }
        return (level, i &- p)
    }

    private func atxContentEnd(from beg: Int, end: Int) -> Int {
        var e = MarkdownByteScanner.trimSpacesBack(in: bytes, from: end, limit: beg)
        var hash = e
        while hash > beg, base[hash &- 1] == UInt8(ascii: "#") { hash &-= 1 }
        if hash != e, hash == beg || MarkdownByteScanner.isSpace(base[hash &- 1]) {
            e = MarkdownByteScanner.trimSpacesBack(in: bytes, from: hash, limit: beg)
        }
        return e
    }

    private func scanOpenFence(at p: Int) -> Int? {
        guard p < lineEnd else { return nil }
        let ch = base[p]
        guard ch == UInt8(ascii: "`") || ch == UInt8(ascii: "~") else { return nil }
        let runEnd = MarkdownByteScanner.runEnd(of: ch, in: bytes, from: p, end: lineEnd)
        let len = runEnd &- p
        guard len >= 3 else { return nil }
        if ch == UInt8(ascii: "`"),
            MarkdownByteScanner.findByte(ch, in: bytes, from: runEnd, end: lineEnd) < lineEnd
        {
            return nil
        }
        return len
    }

    private func closesFence(at p: Int, end: Int) -> Bool {
        let runEnd = MarkdownByteScanner.runEnd(of: codeFenceChar, in: bytes, from: p, end: end)
        guard runEnd &- p >= codeFenceLength else { return false }
        return MarkdownByteScanner.skipSpaces(in: bytes, from: runEnd, end: end) >= end
    }

    private mutating func scanThematicBreak(at p: Int) -> Bool {
        guard p < lineEnd, p >= hrKill else { return false }
        let ch = base[p]
        guard ch == UInt8(ascii: "-") || ch == UInt8(ascii: "*") || ch == UInt8(ascii: "_") else { return false }
        var count = 1
        var i = p &+ 1
        while i < lineEnd {
            let b = base[i]
            if b == ch {
                count &+= 1
            } else if !MarkdownByteScanner.isSpace(b) {
                hrKill = i
                return false
            }
            i &+= 1
        }
        if count < 3 {
            hrKill = i
            return false
        }
        return true
    }

    private struct ListMarker {
        let isOrdered: Bool
        let markerChar: UInt8
        let startIndex: Int
        let length: Int
    }

    private func scanListMarker(at p: Int, interruptsParagraph: Bool) -> ListMarker? {
        guard p < lineEnd else { return nil }
        let first = base[p]
        if first == UInt8(ascii: "-") || first == UInt8(ascii: "*") || first == UInt8(ascii: "+") {
            let after = p &+ 1
            if after < lineEnd, !MarkdownByteScanner.isSpace(base[after]) { return nil }
            if interruptsParagraph, MarkdownByteScanner.skipSpaces(in: bytes, from: after, end: lineEnd) >= lineEnd {
                return nil
            }
            return ListMarker(isOrdered: false, markerChar: first, startIndex: 0, length: 1)
        }
        guard MarkdownByteScanner.isDigit(first) else { return nil }
        var i = p
        var value = 0
        while i < lineEnd, MarkdownByteScanner.isDigit(base[i]), i &- p < 9 {
            value = value &* 10 &+ Int(base[i] &- 0x30)
            i &+= 1
        }
        guard i < lineEnd else { return nil }
        let punct = base[i]
        guard punct == UInt8(ascii: ".") || punct == UInt8(ascii: ")") else { return nil }
        let after = i &+ 1
        if after < lineEnd, !MarkdownByteScanner.isSpace(base[after]) { return nil }
        if interruptsParagraph {
            guard value == 1 else { return nil }
            if MarkdownByteScanner.skipSpaces(in: bytes, from: after, end: lineEnd) >= lineEnd { return nil }
        }
        return ListMarker(isOrdered: true, markerChar: punct, startIndex: value, length: after &- p)
    }

    // MARK: - GFM Table helpers

    /// A GFM delimiter row of at most 512 columns (pipes optional): its alignments.
    private func scanTableDelimiterRow(at start: Int) -> [MarkdownTable.Alignment]? {
        var p = MarkdownByteScanner.skipSpaces(in: bytes, from: start, end: lineEnd)
        guard p < lineEnd else { return nil }
        if base[p] == UInt8(ascii: "|") { p &+= 1 }
        var alignments: [MarkdownTable.Alignment] = []
        while true {
            p = MarkdownByteScanner.skipSpaces(in: bytes, from: p, end: lineEnd)
            let left = p < lineEnd && base[p] == UInt8(ascii: ":")
            if left { p &+= 1 }
            let dashes = p
            p = MarkdownByteScanner.runEnd(of: UInt8(ascii: "-"), in: bytes, from: p, end: lineEnd)
            guard p > dashes else { return nil }
            let right = p < lineEnd && base[p] == UInt8(ascii: ":")
            if right { p &+= 1 }
            p = MarkdownByteScanner.skipSpaces(in: bytes, from: p, end: lineEnd)
            guard alignments.count < 512 else { return nil }
            alignments.append(right ? (left ? .center : .trailing) : .leading)
            if p >= lineEnd { break }
            guard base[p] == UInt8(ascii: "|") else { return nil }
            p &+= 1
            if MarkdownByteScanner.skipSpaces(in: bytes, from: p, end: lineEnd) >= lineEnd { break }
        }
        return alignments
    }

    /// The number of cells the row `start..<end` parses into; 0 when it is not a row.
    private func countRowCells(from start: Int, end: Int) -> Int {
        var p = start
        if p < end, base[p] == UInt8(ascii: "|") { p = MarkdownByteScanner.skipSpaces(in: bytes, from: p &+ 1, end: end) }
        var cells = 0
        while p < end {
            let cellStart = p
            while true {
                p = MarkdownByteScanner.findCellBoundary(in: bytes, from: p, end: end)
                guard p < end else { break }
                if base[p] == UInt8(ascii: "\\") {
                    if p &+ 1 < end, MarkdownByteScanner.isASCIIPunct(base[p &+ 1]) {
                        p &+= 2
                        continue
                    }
                    p &+= 1
                    continue
                }
                break
            }
            // The scan stops only at the end or at an unescaped pipe.
            if p < end {
                cells &+= 1
                p = MarkdownByteScanner.skipSpaces(in: bytes, from: p &+ 1, end: end)
            } else if p > cellStart {
                cells &+= 1
            }
        }
        return cells
    }

    // MARK: - CommonMark HTML Blocks (types 1..7)

    /// The HTML block type (1-7) a line starting at `p` opens, or nil.
    private func scanHtmlStart(at p: Int, allowType7: Bool) -> Int? {
        guard p &+ 1 < lineEnd, base[p] == UInt8(ascii: "<") else { return nil }
        let line = UnsafeBufferPointer(rebasing: bytes[0..<lineEnd])
        if MarkdownHTMLScanner.matches(line, at: p, "<!--") { return 2 }
        if base[p &+ 1] == UInt8(ascii: "?") { return 3 }
        if MarkdownHTMLScanner.matches(line, at: p, "<![CDATA[") { return 5 }
        if base[p &+ 1] == UInt8(ascii: "!") {
            return p &+ 2 < lineEnd && MarkdownByteScanner.isAlpha(base[p &+ 2]) ? 4 : nil
        }
        var atEnd = false
        // Type 1: `<pre`, `<script`, `<style` or `<textarea` before whitespace, `>` or the line end.
        let rawLength = MarkdownHTMLScanner.tagNameLength(line, at: p &+ 1, end: lineEnd, atEnd: &atEnd)
        if rawLength > 0, MarkdownHTMLScanner.isRawTag(line, at: p &+ 1, length: rawLength) {
            let after = p &+ 1 &+ rawLength
            if after >= lineEnd || MarkdownByteScanner.isWhitespace(base[after]) || base[after] == UInt8(ascii: ">") {
                return 1
            }
        }
        // Type 6: an optional `/` then a block tag name before whitespace, `>`, `/>` or the line end.
        let nameStart = base[p &+ 1] == UInt8(ascii: "/") ? p &+ 2 : p &+ 1
        let length = MarkdownHTMLScanner.tagNameLength(line, at: nameStart, end: lineEnd, atEnd: &atEnd)
        if length > 0, MarkdownHTMLScanner.isBlockTag(line, at: nameStart, length: length) {
            let after = nameStart &+ length
            if after >= lineEnd || MarkdownByteScanner.isWhitespace(base[after]) || base[after] == UInt8(ascii: ">")
                || MarkdownHTMLScanner.matches(line, at: after, "/>")
            {
                return 6
            }
        }
        // Type 7: one complete tag alone on the line.
        guard allowType7 else { return nil }
        let close =
            base[p &+ 1] == UInt8(ascii: "/")
            ? MarkdownHTMLScanner.scanCloseTag(line, at: p &+ 2, end: lineEnd, atEnd: &atEnd)
            : MarkdownHTMLScanner.scanOpenTag(line, at: p &+ 1, end: lineEnd, atEnd: &atEnd)
        guard let close, MarkdownByteScanner.skipSpaces(in: bytes, from: close, end: lineEnd) >= lineEnd else {
            return nil
        }
        return 7
    }

    /// Whether the line from `p` meets the end condition of an HTML block of `kind`.
    private func scanHtmlBlockEnd(kind: Int, from p: Int) -> Bool {
        switch kind {
        case 1:
            // A closing raw tag, `</pre>` in any case, anywhere on the line.
            let line = UnsafeBufferPointer(rebasing: bytes[0..<lineEnd])
            var at = p
            while true {
                at = MarkdownByteScanner.findByte(UInt8(ascii: "<"), in: bytes, from: at, end: lineEnd)
                guard at &+ 2 < lineEnd else { return false }
                if base[at &+ 1] == UInt8(ascii: "/") {
                    var atEnd = false
                    let n = MarkdownHTMLScanner.tagNameLength(line, at: at &+ 2, end: lineEnd, atEnd: &atEnd)
                    if n > 0, at &+ 2 &+ n < lineEnd, base[at &+ 2 &+ n] == UInt8(ascii: ">"),
                        MarkdownHTMLScanner.isRawTag(line, at: at &+ 2, length: n)
                    {
                        return true
                    }
                }
                at &+= 1
            }
        case 2: return containsASCII(from: p, end: lineEnd, needle: "-->")
        case 3: return containsASCII(from: p, end: lineEnd, needle: "?>")
        case 4: return MarkdownByteScanner.findByte(UInt8(ascii: ">"), in: bytes, from: p, end: lineEnd) < lineEnd
        case 5: return containsASCII(from: p, end: lineEnd, needle: "]]>")
        default: return false
        }
    }

    private func containsASCII(from start: Int, end: Int, needle: StaticString) -> Bool {
        let len = needle.utf8CodeUnitCount
        guard len > 0, end &- start >= len else { return false }
        let ptr = needle.utf8Start
        let first = ptr[0]
        var cur = start
        let limit = end &- len
        while cur <= limit {
            cur = MarkdownByteScanner.findByte(first, in: bytes, from: cur, end: limit &+ 1)
            if cur > limit { return false }
            var match = true
            for i in 1..<len where base[cur &+ i] != ptr[i] {
                match = false
                break
            }
            if match { return true }
            cur &+= 1
        }
        return false
    }

    // MARK: - Link reference definitions (CommonMark §4.7)

    /// Parses zero or more link reference definitions off the front of the current
    /// paragraph leaf record and removes their consumed prefix from its line spans.
    private mutating func resolveLinkDefsOnLeaf() {
        let baseIdx = Int(records[leafRecordIndex].lineStart)
        let lineCount = Int(records[leafRecordIndex].lineCount)
        guard lineCount > 0 else { return }
        let firstSpan = lines[baseIdx]
        let firstStart = Int(firstSpan.start)
        let firstEnd = Int(firstSpan.end)
        // Quick rejection: paragraph must begin with `[`.
        guard firstStart < firstEnd, base[firstStart] == UInt8(ascii: "[") else { return }
        // Quick rejection for `[text](url)` on the first line before joining lines.
        if let labelEnd = MarkdownLinkSyntax.scanLabel(bytes, from: firstStart, end: firstEnd),
            labelEnd >= firstEnd || base[labelEnd] != UInt8(ascii: ":")
        {
            return
        }

        // Assemble paragraph bytes (or use direct slice if 1 line).
        var joined: [UInt8] = []
        let useDirect = lineCount == 1
        if !useDirect {
            var total = lineCount &- 1
            for i in 0..<lineCount {
                let s = lines[baseIdx &+ i]
                total &+= Int(s.end &- s.start)
            }
            joined.reserveCapacity(total)
            for i in 0..<lineCount {
                if i > 0 { joined.append(0x0A) }
                let s = lines[baseIdx &+ i]
                let len = Int(s.end &- s.start)
                if len > 0 {
                    joined.append(contentsOf: UnsafeBufferPointer(start: base.advanced(by: Int(s.start)), count: len))
                }
            }
        }

        let consumed: Int
        if useDirect {
            consumed = parseLinkDefs(
                in: UnsafeBufferPointer(start: base.advanced(by: firstStart), count: firstEnd &- firstStart))
        } else {
            consumed = joined.withUnsafeBufferPointer { buf in
                parseLinkDefs(in: buf)
            }
        }
        guard consumed > 0 else { return }

        // Trim consumed bytes off the front of the paragraph's line spans.
        var remaining = consumed
        var trimmedCount = 0
        for i in 0..<lineCount {
            let idx = baseIdx &+ i
            let len = Int(lines[idx].end &- lines[idx].start)
            if remaining <= len {
                lines[idx].start &+= Int32(remaining)
                // Trim leading spaces of the new first line.
                let newStart = MarkdownByteScanner.skipSpaces(
                    in: bytes, from: Int(lines[idx].start), end: Int(lines[idx].end))
                lines[idx].start = Int32(newStart)
                break
            }
            remaining &-= (len &+ 1)
            trimmedCount &+= 1
        }
        let left = lineCount &- trimmedCount
        if left <= 0 {
            records[leafRecordIndex].lineCount = 0
        } else {
            if trimmedCount > 0 {
                for i in 0..<left {
                    lines[baseIdx &+ i] = lines[baseIdx &+ trimmedCount &+ i]
                }
            }
            // Drop any leading blank lines left behind.
            var drop = 0
            while drop < left {
                let s = lines[baseIdx &+ drop]
                let ns = MarkdownByteScanner.skipSpaces(in: bytes, from: Int(s.start), end: Int(s.end))
                if ns < Int(s.end) {
                    lines[baseIdx &+ drop].start = Int32(ns)
                    break
                }
                drop &+= 1
            }
            let finalLeft = left &- drop
            if drop > 0, finalLeft > 0 {
                for i in 0..<finalLeft {
                    lines[baseIdx &+ i] = lines[baseIdx &+ drop &+ i]
                }
            }
            records[leafRecordIndex].lineCount = Int32(max(0, finalLeft))
        }
    }

    private mutating func parseLinkDefs(in buf: UnsafeBufferPointer<UInt8>) -> Int {
        guard let ptr = buf.baseAddress else { return 0 }
        let end = buf.count
        var off = 0
        while off < end {
            let p = MarkdownByteScanner.skipSpaces(in: buf, from: off, end: end)
            guard let afterLabel = MarkdownLinkSyntax.scanLabel(buf, from: p, end: end) else { break }
            let labelStart = p &+ 1
            let labelEnd = afterLabel &- 1
            guard MarkdownByteScanner.skipWhitespace(in: buf, from: labelStart, end: labelEnd) < labelEnd else {
                break
            }
            guard afterLabel < end, ptr[afterLabel] == UInt8(ascii: ":") else { break }
            let destPos = MarkdownLinkSyntax.skipLineSpace(buf, from: afterLabel &+ 1, end: end)
            var atEnd = false
            guard let dest = MarkdownLinkSyntax.scanDestination(buf, from: destPos, end: end, atEnd: &atEnd),
                dest.after > destPos
            else { break }
            let (destStart, destEnd, afterDest) = (dest.start, dest.end, dest.after)

            // Optional title on the same or following line.
            var afterTitle = afterDest
            let beforeTitle = MarkdownLinkSyntax.skipLineSpace(buf, from: afterDest, end: end)
            if beforeTitle > afterDest, let titleEnd = MarkdownLinkSyntax.scanTitle(buf, from: beforeTitle, end: end) {
                let eol = MarkdownByteScanner.skipSpaces(in: buf, from: titleEnd, end: end)
                if eol >= end || ptr[eol] == 0x0A {
                    afterTitle = titleEnd
                }
            }
            let eol = MarkdownByteScanner.skipSpaces(in: buf, from: afterTitle, end: end)
            guard eol >= end || ptr[eol] == 0x0A else { break }

            let key = MarkdownLinkSyntax.normalizeLabel(buf, start: labelStart, end: labelEnd)
            if !key.isEmpty, linkDefinitions[key] == nil {
                linkDefinitions[key] = MarkdownByteScanner.unescape(buf, start: destStart, end: destEnd)
                definitionOrder.append(key)
            }
            off = eol < end ? eol &+ 1 : end
        }
        return off
    }
}
