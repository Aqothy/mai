import Markdown

/// One renderable slice of a settled message. Prose segments are unbounded
/// and feed the pre-laid-out selectable text pipeline; rich segments hold a
/// single block that MarkdownView renders (code, tables, HTML, images).
nonisolated struct ChatMarkdownSegment: Equatable, Sendable {
    enum Kind: Sendable {
        case prose
        case rich
    }

    let kind: Kind
    let source: String
}

/// Splits an oversized Markdown message into standalone sources at top-level
/// block boundaries so the chat list can realize each slice as its own row.
///
/// List virtualizes per row, and MarkdownView lays a message out as one
/// selectable text view — so a single essay-sized message must be laid out in
/// full the moment its row enters the viewport. Chunking restores bounded
/// per-row layout cost. Splitting only between top-level blocks keeps every
/// fence, table, and list intact, and concatenating the chunks always
/// reproduces the source byte-for-byte.
///
/// Cuts prefer selection barriers — code fences, tables, raw HTML — because
/// chat UIs (including the native text views comparable apps ship) already
/// interrupt drag selection there, so a seam costs nothing. Contiguous prose
/// (paragraphs, headings, lists, quotes) stays one selectable text view and
/// splits only past `maximumChunkLength` as a layout-cost bound.
nonisolated enum ChatMarkdownChunker {
    /// Messages at or below this many UTF-8 bytes stay one row; typical
    /// messages never reach the parse below.
    static let chunkingThreshold = 4_096
    /// Cut at a selection barrier once a chunk has at least this much
    /// content, so small prose-plus-snippet stretches don't fragment.
    static let barrierCutLength = 1_024
    /// The one seam selection users can feel: contiguous prose splits only
    /// past this length. Raising it widens drag selection; lowering it
    /// bounds worst-case row layout cost tighter.
    static let maximumChunkLength = 8_192

    static func isOversized(_ source: String) -> Bool {
        source.utf8.count > chunkingThreshold
    }

    static func chunks(of source: String) -> [String] {
        guard isOversized(source), !containsReferenceDefinition(source) else {
            return [source]
        }

        // Byte-based offsets, mirroring ChatMarkdownSourceSanitizer:
        // swift-markdown reports 1-based line numbers and UTF-8 byte columns.
        let sourceBytes = Array(source.utf8)
        var lineStartOffsets = [0]
        for (offset, byte) in sourceBytes.enumerated() where byte == 0x0A {
            lineStartOffsets.append(offset + 1)
        }

        let document = Markdown.Document(parsing: source)
        var chunkStarts: [Int] = []
        var currentStart = 0
        var previousWasBarrier = false
        for block in document.children {
            defer { previousWasBarrier = isSelectionBarrier(block) }
            guard let location = block.range?.lowerBound,
                lineStartOffsets.indices.contains(location.line - 1)
            else { continue }
            let offset = lineStartOffsets[location.line - 1] + location.column - 1
            guard offset > currentStart, offset < sourceBytes.count else { continue }
            let length = offset - currentStart
            let atBarrier = previousWasBarrier || isSelectionBarrier(block)
            if length >= maximumChunkLength
                || (atBarrier && length >= barrierCutLength)
            {
                chunkStarts.append(offset)
                currentStart = offset
            }
        }
        guard !chunkStarts.isEmpty else { return [source] }

        var chunks: [String] = []
        var start = 0
        for chunkStart in chunkStarts {
            chunks.append(String(decoding: sourceBytes[start..<chunkStart], as: UTF8.self))
            start = chunkStart
        }
        chunks.append(String(decoding: sourceBytes[start...], as: UTF8.self))
        return chunks
    }

    /// Splits a settled oversized message into typed segments for the
    /// pre-laid-out prose pipeline: contiguous prose accumulates into one
    /// unbounded `.prose` segment (drag selection spans all of it), while any
    /// top-level block containing code, tables, HTML, or images becomes its
    /// own `.rich` segment for MarkdownView to render with its full styling
    /// and the sanitizer's safety fallbacks.
    ///
    /// Returns nil when the source needs MarkdownView whole-message features
    /// the prose renderer cannot honor — math, reference definitions — so the
    /// caller falls back to `chunks(of:)`.
    static func segments(of source: String) -> [ChatMarkdownSegment]? {
        guard isOversized(source),
            !containsReferenceDefinition(source),
            !containsPotentialMath(source)
        else { return nil }

        let sourceBytes = Array(source.utf8)
        var lineStartOffsets = [0]
        for (offset, byte) in sourceBytes.enumerated() where byte == 0x0A {
            lineStartOffsets.append(offset + 1)
        }

        let document = Markdown.Document(parsing: source)
        // (byte offset, is rich) per top-level block; blocks without usable
        // ranges merge into the preceding run.
        var blockStarts: [(offset: Int, isRich: Bool)] = []
        for block in document.children {
            guard let location = block.range?.lowerBound,
                lineStartOffsets.indices.contains(location.line - 1)
            else { continue }
            let offset = lineStartOffsets[location.line - 1] + location.column - 1
            guard offset < sourceBytes.count else { continue }
            blockStarts.append((offset, containsRichContent(block)))
        }
        guard !blockStarts.isEmpty else { return nil }

        // A segment break happens entering or leaving a rich block; each rich
        // block stands alone.
        var segments: [ChatMarkdownSegment] = []
        var runStart = 0
        var runIsRich = blockStarts[0].isRich
        for block in blockStarts.dropFirst() {
            guard block.isRich || runIsRich else { continue }
            let sliceStart = block.offset
            guard sliceStart > runStart else { continue }
            segments.append(
                ChatMarkdownSegment(
                    kind: runIsRich ? .rich : .prose,
                    source: String(
                        decoding: sourceBytes[runStart..<sliceStart],
                        as: UTF8.self
                    )
                )
            )
            runStart = sliceStart
            runIsRich = block.isRich
        }
        segments.append(
            ChatMarkdownSegment(
                kind: runIsRich ? .rich : .prose,
                source: String(decoding: sourceBytes[runStart...], as: UTF8.self)
            )
        )
        return segments
    }

    /// Blocks whose native rendering already interrupts drag selection
    /// (embedded horizontal-scroll code views, table grids, sanitized HTML),
    /// making a chunk seam beside them imperceptible. Prose kinds — headings,
    /// lists, quotes, paragraphs — are deliberately absent so selection spans
    /// them.
    private static func isSelectionBarrier(_ block: Markup) -> Bool {
        block is CodeBlock || block is Markdown.Table || block is HTMLBlock
    }

    /// Whether any node in the block's subtree needs MarkdownView rendering:
    /// code and tables for their dedicated styles, HTML and images for the
    /// sanitizer's plain-text fallback. A list or quote wrapping a fence is
    /// rich as a whole, mirroring how comparable chat apps promote such
    /// blocks to standalone native views.
    private static func containsRichContent(_ block: Markup) -> Bool {
        var walker = RichContentWalker()
        walker.visit(block)
        return walker.foundRichContent
    }

    /// Math renders through MarkdownView's attributed pipeline, which the
    /// prose renderer does not reimplement. Detection is heuristic and
    /// over-broad (dollar amounts can match); a false positive only routes
    /// the message to the chunked MarkdownView path.
    private static func containsPotentialMath(_ source: String) -> Bool {
        if source.contains("$$") || source.contains("\\(") || source.contains("\\[") {
            return true
        }
        // A `$…$` pair on one line whose interior hugs both delimiters.
        var pendingOpener: String.Index?
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if character == "\n" {
                pendingOpener = nil
            } else if character == "$" {
                if let opener = pendingOpener,
                    source.index(after: opener) < index
                {
                    return true
                }
                let next = source.index(after: index)
                pendingOpener =
                    next < source.endIndex && !source[next].isWhitespace
                    ? index
                    : nil
            }
            index = source.index(after: index)
        }
        return false
    }

    /// Reference definitions resolve across the whole document, so any source
    /// declaring one renders as a single piece rather than risking links or
    /// footnotes that dangle in a later chunk. The line scan is deliberately
    /// over-broad (it also matches inside code fences); a false positive only
    /// skips chunking.
    private static func containsReferenceDefinition(_ source: String) -> Bool {
        var lineStart = source.startIndex
        while lineStart < source.endIndex {
            let lineEnd = source[lineStart...].firstIndex(of: "\n") ?? source.endIndex
            if isReferenceDefinitionLine(source[lineStart..<lineEnd]) {
                return true
            }
            lineStart = lineEnd < source.endIndex
                ? source.index(after: lineEnd)
                : source.endIndex
        }
        return false
    }

    private static func isReferenceDefinitionLine(_ line: Substring) -> Bool {
        var rest = line
        var indent = 0
        while rest.first == " ", indent < 3 {
            rest.removeFirst()
            indent += 1
        }
        return rest.first == "[" && rest.contains("]:")
    }
}

private nonisolated struct RichContentWalker: MarkupWalker {
    var foundRichContent = false

    mutating func defaultVisit(_ markup: Markup) {
        guard !foundRichContent else { return }
        if markup is CodeBlock
            || markup is Markdown.Table
            || markup is HTMLBlock
            || markup is InlineHTML
            || markup is Markdown.Image
        {
            foundRichContent = true
            return
        }
        descendInto(markup)
    }
}

/// Memoizes chunking per message so the timeline can rebuild its row list on
/// every store update without re-parsing settled messages.
@MainActor
final class ChatMarkdownChunkCache {
    /// One instance for every timeline. Navigation rebuilds the timeline view
    /// from scratch, so a per-view cache would re-parse a thread's oversized
    /// messages on each visit; message IDs are unique across threads.
    static let shared = ChatMarkdownChunkCache()

    /// Far more oversized messages than the app shows in practice, even
    /// across threads; exceeding it means stale entries dominate, so the
    /// cache starts over.
    private static let maximumEntryCount = 512

    private var entries: [String: (source: String, chunks: [String])] = [:]
    /// nil segment results memoize too: unsegmentable sources (math,
    /// reference definitions) would otherwise re-parse on every update.
    private var segmentEntries: [String: (source: String, segments: [ChatMarkdownSegment]?)] = [:]

    func chunks(messageID: String, source: String) -> [String] {
        if let entry = entries[messageID], entry.source == source {
            return entry.chunks
        }
        if entries.count >= Self.maximumEntryCount {
            entries.removeAll(keepingCapacity: true)
        }
        let chunks = ChatMarkdownChunker.chunks(of: source)
        entries[messageID] = (source, chunks)
        return chunks
    }

    func segments(messageID: String, source: String) -> [ChatMarkdownSegment]? {
        if let entry = segmentEntries[messageID], entry.source == source {
            return entry.segments
        }
        if segmentEntries.count >= Self.maximumEntryCount {
            segmentEntries.removeAll(keepingCapacity: true)
        }
        let segments = ChatMarkdownChunker.segments(of: source)
        segmentEntries[messageID] = (source, segments)
        return segments
    }
}
