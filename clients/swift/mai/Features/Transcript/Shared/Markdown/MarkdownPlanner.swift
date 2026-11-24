import CoreGraphics
import Foundation

/// Turns Markdown source into `MarkdownBlock` values, one per top-level
/// block: block analysis, then (for a stream) completion of the last block,
/// then each leaf's inline runs. Runs on any thread.
nonisolated enum MarkdownPlanner {
    struct ParsedDocument {
        var blocks: [MarkdownBlock]
        /// Blocks before the last safe append boundary; later bytes cannot change them.
        var committedBlockCount: Int
        /// Source bytes before that boundary.
        var committedLength: Int
        /// The document's own link definitions (first wins).
        var linkDefinitions: [String: String]
        /// Those of `linkDefinitions` defined before the boundary.
        var committedDefinitions: [String: String]
        /// Completion changed what the last block shows.
        var repaired: Bool
    }

    /// The blocks of a whole message. Source with no blocks (whitespace
    /// aside) shows as written.
    static func blocks(from source: String) -> [MarkdownBlock] {
        let parsed = parseBlocks(from: source)
        if parsed.isEmpty, source.contains(where: { !$0.isWhitespace }) {
            return [.paragraph([MarkdownInline(text: source)])]
        }
        return parsed
    }

    /// Top-level blocks of `source` without the whole-message fallback.
    static func parseBlocks(from source: String) -> [MarkdownBlock] {
        var copy = source
        return copy.withUTF8 { parse(bytes: $0).blocks }
    }

    /// Parses UTF-8 Markdown. `externalLinkDefinitions` come earlier in the
    /// document and win over its own. `incomplete` is a stream still growing:
    /// the last block shows with its unfinished syntax repaired.
    static func parse(
        bytes: UnsafeBufferPointer<UInt8>, externalLinkDefinitions: [String: String]? = nil, incomplete: Bool = false
    ) -> ParsedDocument {
        var analysis = MarkdownBlockParser.parse(bytes, incomplete: incomplete)
        var inlineScratch = MarkdownInlineParser.Scratch()
        let definitions = MarkdownInlineParser.Definitions(
            local: analysis.linkDefinitions, external: externalLinkDefinitions)
        let repair =
            incomplete
            ? MarkdownCompletion.repair(bytes, analysis, definitions: definitions, scratch: &inlineScratch) : nil
        let build = { (text: UnsafeBufferPointer<UInt8>, analysis: MarkdownBlockParser.Result) -> ParsedDocument in
            var builder = BlockBuilder(
                bytes: text, result: analysis, externalLinkDefinitions: externalLinkDefinitions,
                labelAtEnd: repair?.labelAtEnd ?? false, inlineScratch: inlineScratch)
            let blocks = builder.buildAll()
            var committedDefinitions: [String: String] = [:]
            for label in analysis.definitionOrder.prefix(analysis.boundary.definitions) {
                committedDefinitions[label] = analysis.linkDefinitions[label]
            }
            return ParsedDocument(
                blocks: blocks, committedBlockCount: builder.committedBlockCount,
                committedLength: analysis.boundary.offset, linkDefinitions: analysis.linkDefinitions,
                committedDefinitions: committedDefinitions, repaired: repair?.bytes != nil)
        }
        guard let repaired = repair?.bytes else { return build(bytes, analysis) }
        // Completion read the finished structure and definitions; they are
        // stale for the repaired copy, so it is analyzed again.
        return repaired.withUnsafeBufferPointer { text in
            analysis = MarkdownBlockParser.parse(text, incomplete: true)
            return build(text, analysis)
        }
    }
}

// MARK: - Record-to-Block builder

extension MarkdownPlanner {
    private nonisolated struct BlockBuilder {
        let bytes: UnsafeBufferPointer<UInt8>
        let result: MarkdownBlockParser.Result
        /// Completion left a trailing `[label]` for the last leaf to show as a link.
        let labelAtEnd: Bool
        private(set) var committedBlockCount = 0
        let definitions: MarkdownInlineParser.Definitions
        var index: Int = 0
        /// Reusable scratch buffer for multi-line leaves that cannot read source directly.
        var scratch: [UInt8] = []
        /// Reusable inline-parser work buffers across all blocks in this document.
        var inlineScratch: MarkdownInlineParser.Scratch

        init(
            bytes: UnsafeBufferPointer<UInt8>, result: MarkdownBlockParser.Result,
            externalLinkDefinitions: [String: String]?, labelAtEnd: Bool, inlineScratch: MarkdownInlineParser.Scratch
        ) {
            self.bytes = bytes
            self.result = result
            self.labelAtEnd = labelAtEnd
            self.inlineScratch = inlineScratch
            definitions = .init(local: result.linkDefinitions, external: externalLinkDefinitions)
        }

        mutating func buildAll() -> [MarkdownBlock] {
            var blocks: [MarkdownBlock] = []
            blocks.reserveCapacity(result.records.count)
            while index < result.records.count {
                if let block = readNextBlock() {
                    blocks.append(block)
                }
                if index <= result.boundary.records { committedBlockCount = blocks.count }
            }
            return blocks
        }

        private mutating func readNextBlock() -> MarkdownBlock? {
            let rec = result.records[index]
            let pendingLabel = labelAtEnd && index == result.lastLeaf
            index &+= 1
            switch rec.kind {
            case .none, .quoteClose, .ulClose, .olClose, .liClose, .liOpen:
                return nil
            case .paragraph:
                guard rec.lineCount > 0 else { return nil }
                return .paragraph(parseRecordInlines(rec, pendingLabel: pendingLabel))
            case .heading:
                let level = max(1, min(6, Int(rec.data)))
                return .heading(level: level, parseRecordInlines(rec, pendingLabel: pendingLabel))
            case .code:
                // The info string's escapes resolve before its first word is the language.
                var language: String?
                if rec.flags & MarkdownBlockParser.Flags.fenced != 0, rec.aux > rec.data {
                    let info = MarkdownByteScanner.unescape(bytes, start: Int(rec.data), end: Int(rec.aux))
                    let word = info.utf8.prefix { !MarkdownByteScanner.isWhitespace($0) }
                    language = word.isEmpty ? nil : String(decoding: word, as: UTF8.self)
                }
                return .code(language: language, code: buildCodeString(rec))
            case .html:
                return .code(language: "html", code: buildCodeString(rec))
            case .rule:
                let s = Int(rec.data)
                let e = Int(rec.aux)
                let spelling = String(decoding: bytes[s..<max(s, e)], as: UTF8.self)
                return .rule(spelling: spelling)
            case .table:
                return .table(buildTable(rec, pendingLabel: pendingLabel))
            case .quoteOpen:
                var children: [MarkdownBlock] = []
                while index < result.records.count {
                    if result.records[index].kind == .quoteClose {
                        index &+= 1
                        break
                    }
                    if let child = readNextBlock() { children.append(child) }
                }
                return .quote(children)
            case .ulOpen, .olOpen:
                let closeKind: MarkdownBlockParser.RecordKind = rec.kind == .ulOpen ? .ulClose : .olClose
                let startIndex: Int? = rec.kind == .olOpen ? Int(rec.data) : nil
                var items: [MarkdownList.Item] = []
                while index < result.records.count {
                    let nextRec = result.records[index]
                    index &+= 1
                    if nextRec.kind == closeKind { break }
                    let taskChecked = Self.taskState(from: nextRec.flags)
                    var itemBlocks: [MarkdownBlock] = []
                    while index < result.records.count {
                        if result.records[index].kind == .liClose {
                            index &+= 1
                            break
                        }
                        if let child = readNextBlock() { itemBlocks.append(child) }
                    }
                    items.append(MarkdownList.Item(taskChecked: taskChecked, blocks: itemBlocks))
                }
                return .list(MarkdownList(startIndex: startIndex, items: items))
            }
        }

        private static func taskState(from flags: UInt8) -> Bool? {
            guard flags & MarkdownBlockParser.Flags.task != 0 else { return nil }
            return flags & MarkdownBlockParser.Flags.taskDone != 0
        }

        /// A paragraph or heading's inline runs. Lines joined by single line
        /// feeds are read in place; others are rebuilt with `\n` between them.
        private mutating func parseRecordInlines(_ rec: MarkdownBlockParser.Record, pendingLabel: Bool) -> [MarkdownInline] {
            let count = Int(rec.lineCount)
            guard count > 0 else { return [] }
            let first = Int(rec.lineStart)
            var contiguous = true
            for i in 1..<max(1, count) {
                let previousEnd = Int(result.lines[first &+ i &- 1].end)
                if Int(result.lines[first &+ i].start) != previousEnd &+ 1 || bytes[previousEnd] != 0x0A {
                    contiguous = false
                    break
                }
            }
            if contiguous {
                let content = UnsafeBufferPointer(
                    rebasing: bytes[Int(result.lines[first].start)..<Int(result.lines[first &+ count &- 1].end)])
                return inlines(content, plain: rec.flags & MarkdownBlockParser.Flags.plainInline != 0, pendingLabel: pendingLabel)
            }
            scratch.removeAll(keepingCapacity: true)
            for i in 0..<count {
                if i > 0 { scratch.append(0x0A) }
                let line = result.lines[first &+ i]
                scratch.append(contentsOf: bytes[Int(line.start)..<Int(line.end)])
            }
            let joined = scratch
            return joined.withUnsafeBufferPointer {
                inlines($0, plain: rec.flags & MarkdownBlockParser.Flags.plainInline != 0, pendingLabel: pendingLabel)
            }
        }

        private mutating func inlines(
            _ content: UnsafeBufferPointer<UInt8>, plain: Bool, pendingLabel: Bool
        ) -> [MarkdownInline] {
            guard !content.isEmpty else { return [] }
            if plain { return [MarkdownInline(text: String(decoding: content, as: UTF8.self))] }
            return MarkdownInlineParser.parse(
                content, definitions: definitions, pendingLabelAtEnd: pendingLabel, scratch: &inlineScratch)
        }

        private mutating func buildCodeString(_ rec: MarkdownBlockParser.Record) -> String {
            let count = Int(rec.lineCount)
            guard count > 0 else { return "" }
            let firstIdx = Int(rec.lineStart)
            if count == 1, result.lines[firstIdx].padSpaces == 0 {
                let span = result.lines[firstIdx]
                let len = Int(span.end &- span.start)
                guard len > 0 else { return "" }
                return String(decoding: bytes[Int(span.start)..<Int(span.end)], as: UTF8.self)
            }
            scratch.removeAll(keepingCapacity: true)
            var total = count &- 1
            for i in 0..<count {
                let s = result.lines[firstIdx &+ i]
                total &+= Int(s.end &- s.start) &+ Int(s.padSpaces)
            }
            scratch.reserveCapacity(total)
            for i in 0..<count {
                if i > 0 { scratch.append(0x0A) }
                let s = result.lines[firstIdx &+ i]
                if s.padSpaces > 0 {
                    scratch.append(contentsOf: repeatElement(UInt8(0x20), count: Int(s.padSpaces)))
                }
                let len = Int(s.end &- s.start)
                if len > 0 {
                    scratch.append(contentsOf: bytes[Int(s.start)..<Int(s.end)])
                }
            }
            return String(decoding: scratch, as: UTF8.self)
        }

        private mutating func buildTable(_ rec: MarkdownBlockParser.Record, pendingLabel: Bool) -> MarkdownTable {
            let alignStart = Int(rec.data)
            let columns = Int(rec.aux)
            let alignments = Array(result.tableAlignments[alignStart..<(alignStart &+ columns)])
            let first = Int(rec.lineStart)
            let count = Int(rec.lineCount)
            let header = row(result.lines[first], columns: columns, pendingLabel: pendingLabel && count == 1)
            var rows: [[[MarkdownInline]]] = []
            rows.reserveCapacity(count &- 1)
            for i in 1..<max(1, count) {
                rows.append(row(result.lines[first &+ i], columns: columns, pendingLabel: pendingLabel && i == count &- 1))
            }
            return MarkdownTable(alignments: alignments, header: header, rows: rows)
        }

        /// A row's `columns` cells: split at unescaped pipes (an optional pipe
        /// on each edge), missing cells empty and extra ones dropped. `\|` is a
        /// pipe in the cell's text (GFM 4.10).
        private mutating func row(
            _ line: MarkdownBlockParser.LineSpan, columns: Int, pendingLabel: Bool
        ) -> [[MarkdownInline]] {
            var s = MarkdownByteScanner.skipSpaces(in: bytes, from: Int(line.start), end: Int(line.end))
            var e = MarkdownByteScanner.trimSpacesBack(in: bytes, from: Int(line.end), limit: s)
            if s < e, bytes[s] == UInt8(ascii: "|") { s &+= 1 }
            if e > s, bytes[e &- 1] == UInt8(ascii: "|") {
                var k = e &- 2
                while k >= s, bytes[k] == UInt8(ascii: "\\") { k &-= 1 }
                if (e &- 2 &- k).isMultiple(of: 2) { e &-= 1 }
            }
            var cells: [[MarkdownInline]] = []
            cells.reserveCapacity(columns)
            var cellStart = s
            var cur = s
            while cur < e, cells.count < columns {
                cur = MarkdownByteScanner.findCellBoundary(in: bytes, from: cur, end: e)
                guard cur < e else { break }
                if bytes[cur] == UInt8(ascii: "\\") {
                    cur &+= cur &+ 1 < e ? 2 : 1
                } else {
                    cells.append(cell(cellStart, cur, pendingLabel: false))
                    cur &+= 1
                    cellStart = cur
                }
            }
            if cells.count < columns, cellStart <= e { cells.append(cell(cellStart, e, pendingLabel: pendingLabel)) }
            while cells.count < columns { cells.append([]) }
            return cells
        }

        private mutating func cell(_ rawStart: Int, _ rawEnd: Int, pendingLabel: Bool) -> [MarkdownInline] {
            let start = MarkdownByteScanner.skipSpaces(in: bytes, from: rawStart, end: rawEnd)
            let end = MarkdownByteScanner.trimSpacesBack(in: bytes, from: rawEnd, limit: start)
            guard start < end else { return [] }
            var escapedPipe = false
            for i in start..<(end &- 1) where bytes[i] == UInt8(ascii: "\\") && bytes[i &+ 1] == UInt8(ascii: "|") {
                escapedPipe = true
                break
            }
            guard escapedPipe else {
                return inlines(UnsafeBufferPointer(rebasing: bytes[start..<end]), plain: false, pendingLabel: pendingLabel)
            }
            scratch.removeAll(keepingCapacity: true)
            var q = start
            while q < end {
                if bytes[q] == UInt8(ascii: "\\"), q &+ 1 < end, bytes[q &+ 1] == UInt8(ascii: "|") { q &+= 1 }
                scratch.append(bytes[q])
                q &+= 1
            }
            let unescaped = scratch
            return unescaped.withUnsafeBufferPointer { inlines($0, plain: false, pendingLabel: pendingLabel) }
        }
    }
}
