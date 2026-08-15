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
        if role == MaidMessageRole.user.rawValue {
            return ChatMarkdownSegmenter.shouldOptimize(source)
        }
        guard role == MaidMessageRole.assistant.rawValue else { return false }
        // Every settled assistant message uses one selectable native text host
        // per consecutive prose run. Streaming stays in one stable live row.
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

        if let segments = segmentCache.segments(
            messageID: messageID,
            source: source
        ) {
            if segments.contains(where: { $0.kind == .prose })
                || segments.count > 1
            {
                return .segmented(segments)
            }
            // A single rich block has no neighboring prose selection to join.
            return .existingRenderer
        }

        // A document-wide prose feature can make independent block parsing
        // unsafe. It still belongs in one selectable TextKit surface rather
        // than the iOS 26 SwiftUI Text path, which only supports whole-copy.
        return .segmented([ChatMarkdownSegment(kind: .prose, source: source)])
    }
}

/// Separates native-text prose from blocks that need dedicated rich views.
///
/// Code blocks, tables, and block HTML become standalone rich rows. All
/// consecutive prose—including inert inline HTML, literal images, headings,
/// lists, quotes, and thematic breaks—coalesces into one selectable run.
nonisolated enum ChatMarkdownSegmenter {
    /// Long user-authored text uses the same prelaid-out native host without
    /// paying Markdown parsing costs. Settled assistant prose is always native.
    static let optimizationThreshold = 2_048
    static func shouldOptimize(_ source: String) -> Bool {
        source.utf8.count > optimizationThreshold
    }

    /// Returns nil when splitting could change document-wide Markdown
    /// behavior. Those uncommon messages stay in one attributed text row.
    static func segments(of source: String) -> [ChatMarkdownSegment]? {
        guard canSegment(source) else { return nil }

        // This is only a conservative prefilter, not Markdown detection. A
        // possible rich-block introducer always falls through to swift-markdown,
        // which remains the source of truth for the actual block types.
        guard mayContainRichBlock(source) else {
            return [ChatMarkdownSegment(kind: .prose, source: source)]
        }
        return parsedSegments(of: source)
    }

    /// Full-parser equivalent retained as a benchmark seam. Keeping the
    /// semantic result directly comparable prevents the prefilter from
    /// becoming an unverified collection of syntax assumptions.
    static func segmentsUsingFullParser(
        of source: String
    ) -> [ChatMarkdownSegment]? {
        guard canSegment(source) else { return nil }
        return parsedSegments(of: source)
    }

    private static func canSegment(_ source: String) -> Bool {
        !containsReferenceDefinition(source)
            && source.contains(where: { !$0.isWhitespace })
    }

    private static func parsedSegments(
        of source: String
    ) -> [ChatMarkdownSegment]? {
        // swift-markdown locations use one-based UTF-8 line and column
        // offsets, so slice the original bytes to preserve the source exactly.
        let bytes = Array(source.utf8)
        var lineStarts = [0]
        for (offset, byte) in bytes.enumerated() where byte == 0x0A {
            lineStarts.append(offset + 1)
        }

        let document = Markdown.Document(parsing: source)
        var blocks: [(offset: Int, kind: ChatMarkdownSegment.Kind)] = []
        for block in document.children {
            guard let location = block.range?.lowerBound,
                lineStarts.indices.contains(location.line - 1)
            else { continue }
            let offset = lineStarts[location.line - 1] + location.column - 1
            guard offset < bytes.count else { continue }
            let kind: ChatMarkdownSegment.Kind = containsRichContent(block)
                ? .rich
                : .prose
            blocks.append((offset, kind))
        }
        guard let first = blocks.first else { return nil }

        var segments: [ChatMarkdownSegment] = []
        var runStart = 0
        var runKind = first.kind

        for block in blocks.dropFirst() {
            // Every rich block stands alone. Adjacent prose deliberately stays
            // in one segment to preserve continuous range selection.
            guard runKind != .prose || block.kind != .prose,
                block.offset > runStart
            else { continue }
            segments.append(
                ChatMarkdownSegment(
                    kind: runKind,
                    source: String(
                        decoding: bytes[runStart..<block.offset],
                        as: UTF8.self
                    )
                )
            )
            runStart = block.offset
            runKind = block.kind
        }

        segments.append(
            ChatMarkdownSegment(
                kind: runKind,
                source: String(decoding: bytes[runStart...], as: UTF8.self)
            )
        )
        return segments
    }

    private static func mayContainRichBlock(_ source: String) -> Bool {
        let mayContainFencedCode = source.contains("```")
            || source.contains("~~~")
        let mayContainTable = source.contains("|")
        let mayContainBlockHTML = source.contains("<")
        // Indented code may also be nested after a quote or list marker.
        // Searching anywhere is intentionally broader than Markdown's exact
        // line-prefix rule; false positives simply use the semantic parser.
        let mayContainIndentedCode = source.contains("    ")
            || source.contains("\t")
        return mayContainFencedCode || mayContainTable
            || mayContainBlockHTML || mayContainIndentedCode
    }

    private static func containsRichContent(_ block: Markup) -> Bool {
        var walker = ChatRichContentWalker()
        walker.visit(block)
        return walker.foundRichContent
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
    /// Retained message entries; a test seam for retention behavior.
    var entryCount: Int { entries.count }

    private struct Entry {
        let source: String
        let segments: [ChatMarkdownSegment]?
    }

    private var entries: [String: Entry] = [:]

    func segments(messageID: String, source: String) -> [ChatMarkdownSegment]? {
        if let entry = entries[messageID], entry.source == source {
            return entry.segments
        }
        let result = ChatMarkdownSegmenter.segments(of: source)
        store(result, messageID: messageID, source: source)
        return result
    }

    /// Whether preparation has stored a result, including a nil result for a
    /// message that must stay in one attributed row.
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
        entries[messageID] = Entry(source: source, segments: segments)
    }
}
