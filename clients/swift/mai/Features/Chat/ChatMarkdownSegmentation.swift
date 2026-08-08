import Markdown

/// One independently renderable part of a settled Markdown message.
nonisolated struct ChatMarkdownSegment: Equatable, Sendable {
    enum Kind: Sendable {
        case prose
        case rich
    }

    let kind: Kind
    let source: String
}

/// Centralized policy for the timeline's expensive text path.
nonisolated enum ChatTextOptimizationPolicy {
    static func shouldOptimize(
        role: String,
        messageTurnID: String?,
        streamingTurnID: String?,
        source: String
    ) -> Bool {
        guard ChatMarkdownSegmenter.shouldOptimize(source) else { return false }
        if role == MaidMessageRole.user.rawValue { return true }
        guard role == MaidMessageRole.assistant.rawValue else { return false }
        return streamingTurnID == nil || messageTurnID != streamingTurnID
    }
}

nonisolated enum ChatMessageTextPlan: Equatable, Sendable {
    case existingRenderer
    case plainText
    case segmented([ChatMarkdownSegment])
}

/// Chooses one rendering path for a message. Keeping the decision here makes
/// production, previews, and performance fixtures exercise the same policy.
enum ChatMessageTextPlanner {
    static func plan(
        messageID: String,
        role: String,
        messageTurnID: String?,
        streamingTurnID: String?,
        source: String,
        segmentCache: ChatMarkdownSegmentCache
    ) -> ChatMessageTextPlan {
        guard
            ChatTextOptimizationPolicy.shouldOptimize(
                role: role,
                messageTurnID: messageTurnID,
                streamingTurnID: streamingTurnID,
                source: source
            )
        else { return .existingRenderer }

        if role == MaidMessageRole.user.rawValue {
            return .plainText
        }

        guard
            let segments = segmentCache.segments(
                messageID: messageID,
                source: source
            ),
            segments.contains(where: { $0.kind == .prose })
                || segments.count > 1
        else { return .existingRenderer }
        return .segmented(segments)
    }
}

/// Separates native-text prose from blocks that still need MarkdownView.
///
/// The split is semantic rather than size based: adjacent paragraphs,
/// headings, lists, and quotes remain one selectable text view. Code blocks,
/// tables, HTML, and images become standalone rich rows. This gives `List`
/// useful virtualization boundaries without chopping ordinary prose or code.
nonisolated enum ChatMarkdownSegmenter {
    /// Fresh layout of a representative 2 KB Markdown message costs about a
    /// frame in the existing renderer; smaller messages keep its simpler path.
    static let optimizationThreshold = 2_048

    static func shouldOptimize(_ source: String) -> Bool {
        source.utf8.count > optimizationThreshold
    }

    /// Returns nil when splitting could change document-wide Markdown
    /// behavior. Those uncommon messages stay on the existing renderer.
    static func segments(of source: String) -> [ChatMarkdownSegment]? {
        guard shouldOptimize(source),
            !containsReferenceDefinition(source),
            !containsPotentialMath(source)
        else { return nil }

        // swift-markdown locations use one-based UTF-8 line and column
        // offsets, so slice the original bytes to preserve the source exactly.
        let bytes = Array(source.utf8)
        var lineStarts = [0]
        for (offset, byte) in bytes.enumerated() where byte == 0x0A {
            lineStarts.append(offset + 1)
        }

        let document = Markdown.Document(parsing: source)
        var blocks: [(offset: Int, isRich: Bool)] = []
        for block in document.children {
            guard let location = block.range?.lowerBound,
                lineStarts.indices.contains(location.line - 1)
            else { continue }
            let offset = lineStarts[location.line - 1] + location.column - 1
            guard offset < bytes.count else { continue }
            blocks.append((offset, containsRichContent(block)))
        }
        guard let first = blocks.first else { return nil }

        var segments: [ChatMarkdownSegment] = []
        var runStart = 0
        var runIsRich = first.isRich

        for block in blocks.dropFirst() {
            // Prose coalesces. Every rich block stands alone.
            guard runIsRich || block.isRich, block.offset > runStart else {
                continue
            }
            segments.append(
                ChatMarkdownSegment(
                    kind: runIsRich ? .rich : .prose,
                    source: String(
                        decoding: bytes[runStart..<block.offset],
                        as: UTF8.self
                    )
                )
            )
            runStart = block.offset
            runIsRich = block.isRich
        }

        segments.append(
            ChatMarkdownSegment(
                kind: runIsRich ? .rich : .prose,
                source: String(decoding: bytes[runStart...], as: UTF8.self)
            )
        )
        return segments
    }

    private static func containsRichContent(_ block: Markup) -> Bool {
        var walker = ChatRichContentWalker()
        walker.visit(block)
        return walker.foundRichContent
    }

    /// Math stays with MarkdownView because the prose renderer intentionally
    /// does not duplicate MarkdownView's math implementation.
    private static func containsPotentialMath(_ source: String) -> Bool {
        if source.contains("$$") || source.contains("\\(")
            || source.contains("\\[")
        {
            return true
        }
        guard source.contains("$") else { return false }

        var opener: String.Index?
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if character == "\n" {
                opener = nil
            } else if character == "$" {
                if let opener, source.index(after: opener) < index {
                    return true
                }
                let next = source.index(after: index)
                opener =
                    next < source.endIndex && !source[next].isWhitespace
                    ? index
                    : nil
            }
            index = source.index(after: index)
        }
        return false
    }

    /// Reference definitions can affect links in later blocks, so splitting
    /// such a document into independently parsed pieces would be incorrect.
    private static func containsReferenceDefinition(_ source: String) -> Bool {
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            var remainder = line
            var indentation = 0
            while remainder.first == " ", indentation < 3 {
                remainder.removeFirst()
                indentation += 1
            }
            if remainder.first == "[", remainder.contains("]:") {
                return true
            }
        }
        return false
    }
}

private nonisolated struct ChatRichContentWalker: MarkupWalker {
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
        } else {
            descendInto(markup)
        }
    }
}

/// Avoids reparsing unchanged settled messages when the timeline updates.
final class ChatMarkdownSegmentCache {
    private static let maximumEntryCount = 256

    private struct Entry {
        let source: String
        let segments: [ChatMarkdownSegment]?
    }

    private var entries: [String: Entry] = [:]
    private var entryOrder: [String] = []

    func segments(messageID: String, source: String) -> [ChatMarkdownSegment]? {
        if let entry = entries[messageID], entry.source == source {
            return entry.segments
        }
        if entries.count >= Self.maximumEntryCount, entries[messageID] == nil,
            let oldestMessageID = entryOrder.first
        {
            entryOrder.removeFirst()
            entries.removeValue(forKey: oldestMessageID)
        }
        let isNewEntry = entries[messageID] == nil
        let result = ChatMarkdownSegmenter.segments(of: source)
        entries[messageID] = Entry(source: source, segments: result)
        if isNewEntry {
            entryOrder.append(messageID)
        }
        return result
    }
}
