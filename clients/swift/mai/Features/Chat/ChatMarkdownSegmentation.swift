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
/// Code blocks, tables, HTML, and images become standalone rich rows. Long
/// prose is also divided at top-level Markdown block boundaries so `List` can
/// virtualize an essay instead of laying out one enormous text view at once.
nonisolated enum ChatMarkdownSegmenter {
    /// Fresh layout of a representative 2 KB Markdown message costs about a
    /// frame in the existing renderer; smaller messages keep its simpler path.
    static let optimizationThreshold = 2_048
    /// Keeps each ordinary prose row near one frame of native attachment work.
    /// A single indivisible Markdown block may exceed this target.
    static let maximumProseSegmentByteCount = 4_096

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
            let shouldSplitLongProse =
                !runIsRich && !block.isRich
                && block.offset - runStart >= maximumProseSegmentByteCount
            // Every rich block stands alone. Prose coalesces only until the
            // next semantic block would make one native row too expensive.
            guard runIsRich || block.isRich || shouldSplitLongProse,
                block.offset > runStart
            else { continue }
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

/// One settled message whose segmentation is computed before first render.
nonisolated struct ChatMarkdownPrimeRequest: Equatable, Sendable {
    let messageID: String
    let source: String
}

/// Avoids reparsing unchanged settled messages when the timeline updates.
final class ChatMarkdownSegmentCache {
    /// A per-session ceiling. One entry represents one eligible assistant
    /// message and can contain several Markdown segments. This does not
    /// preallocate or precompute 512 messages.
    private static let capacity = 512

    /// Retained message entries; a test seam for retention behavior.
    var entryCount: Int { entries.count }

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
        let result = ChatMarkdownSegmenter.segments(of: source)
        store(result, messageID: messageID, source: source)
        return result
    }

    /// Whether preparation has stored a result, including a nil result for a
    /// message that must keep the existing renderer.
    func contains(messageID: String, source: String) -> Bool {
        entries[messageID]?.source == source
    }

    /// Uses fold-aware rows so hidden intermediate messages are not primed.
    static func primeRequests(
        rows: [ChatTimelineRowModel],
        streamingTurnID: String?
    ) -> [ChatMarkdownPrimeRequest] {
        rows.compactMap { row in
            guard case .message(let message) = row,
                ChatTextOptimizationPolicy.shouldOptimize(
                    role: message.role,
                    messageTurnID: message.turnID,
                    streamingTurnID: streamingTurnID,
                    source: message.text
                )
            else { return nil }
            return ChatMarkdownPrimeRequest(
                messageID: message.id,
                source: message.text
            )
        }
    }

    /// Batch-parses uncached requests off the main actor. Cancellation keeps
    /// completed results; missing entries remain eligible for a later retry.
    func prime(requests: [ChatMarkdownPrimeRequest]) async {
        let pending = requests.filter {
            entries[$0.messageID]?.source != $0.source
        }
        if !pending.isEmpty {
            let worker = Task.detached(priority: .userInitiated) {
                var computed: [(ChatMarkdownPrimeRequest, [ChatMarkdownSegment]?)] = []
                computed.reserveCapacity(pending.count)
                for request in pending {
                    guard !Task.isCancelled else { break }
                    computed.append(
                        (request, ChatMarkdownSegmenter.segments(of: request.source))
                    )
                }
                return computed
            }
            let computed = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            for (request, segments) in computed {
                store(segments, messageID: request.messageID, source: request.source)
            }
        }
    }

    private func store(
        _ segments: [ChatMarkdownSegment]?,
        messageID: String,
        source: String
    ) {
        let isNewEntry = entries[messageID] == nil
        if entries.count >= Self.capacity, isNewEntry,
            let oldestMessageID = entryOrder.first
        {
            entryOrder.removeFirst()
            entries.removeValue(forKey: oldestMessageID)
        }
        entries[messageID] = Entry(source: source, segments: segments)
        if isNewEntry {
            entryOrder.append(messageID)
        }
    }
}
