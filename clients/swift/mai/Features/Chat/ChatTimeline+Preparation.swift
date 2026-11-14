import SwiftUI

extension ChatTimeline {
    /// Prepares a bounded page off the main actor before it enters the
    /// timeline. Upward scrolling finds parsing and native text work cached.
    static func prepare(
        timelineRows: [ChatTimelineRowModel],
        streamingTurnID: String?,
        segmentCache: ChatMarkdownSegmentCache,
        textLayoutStore: ChatTextLayoutStore,
        rowWidth: CGFloat,
        codeTheme: ChatCodeHighlightTheme
    ) async {
        let renderedRows = await primeMarkdownCaches(
            timelineRows: timelineRows,
            streamingTurnID: streamingTurnID,
            segmentCache: segmentCache
        )
        guard !Task.isCancelled else { return }

        let layoutRequests = Self.textLayoutRequests(
            in: renderedRows,
            streamingTurnID: streamingTurnID,
            rowWidth: rowWidth
        )
        let richBlocks = Self.richBlockLayoutRequests(
            in: renderedRows,
            streamingTurnID: streamingTurnID,
            codeTheme: codeTheme
        )
        #if DEBUG
            ChatBenchmarkAutoRun.trace(
                "prepare rows=\(renderedRows.count) requests=\(layoutRequests.count) code=\(richBlocks.code.count) tables=\(richBlocks.tables.count)"
            )
        #endif
        await textLayoutStore.prepare(requests: layoutRequests)
        // Prose first: it is most of every page. Code highlighting is
        // JavaScript-backed and tables are rarer, so they follow.
        await textLayoutStore.prepareTables(requests: richBlocks.tables)
        await textLayoutStore.prepareCodeBlocks(requests: richBlocks.code)
    }

    /// Settled code blocks and tables the rows will host natively,
    /// keyed exactly as `ChatMarkdownRichContentView` and
    /// `ChatResolvedMarkdownBlockRow` key them. Streaming messages are
    /// excluded: their tail changes per chunk.
    static func richBlockLayoutRequests(
        in rows: [ChatTimelineRenderRow],
        streamingTurnID: String?,
        codeTheme: ChatCodeHighlightTheme
    ) -> (code: [ChatCodeLayoutRequest], tables: [ChatTableLayoutRequest]) {
        var code: [ChatCodeLayoutRequest] = []
        var tables: [ChatTableLayoutRequest] = []

        func appendBlocks(messageID: String, source: String) {
            guard let plan = ChatMarkdownRenderCache.shared.cachedPlan(
                messageID: messageID,
                source: source
            ) else { return }
            for (index, block) in plan.blocks.enumerated() {
                let id = "\(messageID)-block-\(index)"
                switch block {
                case .code(let codeBlock):
                    code.append(
                        ChatCodeLayoutRequest(id: id, block: codeBlock, theme: codeTheme)
                    )
                case .table(let table):
                    tables.append(ChatTableLayoutRequest(id: id, table: table))
                case .prose:
                    break
                }
            }
        }

        for row in rows {
            switch row {
            case .richMarkdown(let segment):
                appendBlocks(messageID: segment.rowID, source: segment.source)
            case .standard(.message(let message)):
                guard
                    message.role != ChatRole.assistant.rawValue
                        || streamingTurnID == nil
                        || message.turnID != streamingTurnID
                else { continue }
                appendBlocks(messageID: message.id, source: message.text)
            case .resolvedMarkdown(let block):
                switch block.content {
                case .code(let codeBlock):
                    code.append(
                        ChatCodeLayoutRequest(
                            id: block.rowID,
                            block: codeBlock,
                            theme: codeTheme
                        )
                    )
                case .table(let table):
                    tables.append(
                        ChatTableLayoutRequest(id: block.rowID, table: table)
                    )
                case .proseRun:
                    break
                }
            case .standard, .prose:
                break
            }
        }
        return (code, tables)
    }

    /// Parses every Markdown representation the rows will request — source
    /// segmentation, whole-document plans, and per-segment plans — off the
    /// main actor. Called before the timeline's first body so a cold open
    /// never parses synchronously inside view construction. Returns the
    /// rendered rows so callers can derive layout requests without building
    /// them twice.
    static func primeMarkdownCaches(
        timelineRows: [ChatTimelineRowModel],
        streamingTurnID: String?,
        segmentCache: ChatMarkdownSegmentCache
    ) async -> [ChatTimelineRenderRow] {
        await segmentCache.prime(
            requests: ChatMarkdownSegmentCache.primeRequests(
                rows: timelineRows,
                streamingTurnID: streamingTurnID
            )
        )
        guard !Task.isCancelled else { return [] }

        // Reference definitions and other document-wide Markdown cannot be
        // source-segmented safely. Resolve those documents once before
        // splitting their already-parsed blocks into lazy transcript rows.
        await ChatMarkdownRenderCache.shared.prime(
            requests: Self.wholeDocumentMarkdownRenderRequests(
                in: timelineRows,
                streamingTurnID: streamingTurnID,
                segmentCache: segmentCache
            )
        )
        guard !Task.isCancelled else { return [] }

        let renderedRows = Self.renderRows(
            timelineRows,
            streamingTurnID: streamingTurnID,
            segmentCache: segmentCache
        )
        await ChatMarkdownRenderCache.shared.prime(
            requests: Self.markdownRenderRequests(
                in: renderedRows,
                streamingTurnID: streamingTurnID
            )
        )
        return renderedRows
    }

    /// Expands oversized user messages and every settled assistant message.
    /// Streaming keeps one stable live row. Documents that cannot be
    /// source-segmented are parsed as whole documents before splitting into
    /// resolved rows, retaining reference links and message annotation context.
    static func renderRows(
        _ rows: [ChatTimelineRowModel],
        streamingTurnID: String?,
        segmentCache: ChatMarkdownSegmentCache
    ) -> [ChatTimelineRenderRow] {
        return rows.flatMap { row -> [ChatTimelineRenderRow] in
            guard case .message(let message) = row else {
                return [.standard(row)]
            }
            guard
                ChatTextOptimizationPolicy.shouldOptimize(
                    role: message.role,
                    messageTurnID: message.turnID,
                    streamingTurnID: streamingTurnID,
                    source: message.text
                )
            else {
                return [.standard(row)]
            }
            let plan = ChatMessageTextPlanner.plan(
                messageID: message.id,
                role: message.role,
                messageTurnID: message.turnID,
                streamingTurnID: streamingTurnID,
                source: message.text,
                segmentCache: segmentCache
            )
            switch plan {
            case .existingRenderer:
                // A restored message can carry no turn ID; `nil != nil` must
                // not classify it as the streaming message when nothing is
                // streaming.
                guard message.annotations?.isEmpty != false,
                    message.role == ChatRole.assistant.rawValue,
                    streamingTurnID == nil || message.turnID != streamingTurnID
                else { return [.standard(row)] }

                let renderPlan = ChatMarkdownRenderCache.shared.plan(
                    messageID: message.id,
                    source: message.text
                )
                let contents = ChatResolvedMarkdownRowPlanner.contents(
                    in: renderPlan
                )
                guard !contents.isEmpty else { return [.standard(row)] }
                return contents.indices.map { index in
                    .resolvedMarkdown(
                        ChatResolvedMarkdownBlockRowModel(
                            messageID: message.id,
                            index: index,
                            content: contents[index],
                            attachments: index == contents.count - 1
                                ? message.attachments
                                : nil,
                            isFirst: index == 0,
                            isLast: index == contents.count - 1
                        )
                    )
                }

            case .segmented(let segments):
                return segments.indices.map { index in
                    let segment = segments[index]
                    let model = ChatMessageSegmentRowModel(
                        messageID: message.id,
                        index: index,
                        source: segment.source,
                        role: message.role,
                        annotations: index == segments.count - 1
                            ? message.annotations
                            : nil,
                        attachments: index == segments.count - 1
                            ? message.attachments
                            : nil,
                        isFirst: index == 0,
                        isLast: index == segments.count - 1
                    )
                    return segment.kind == .prose
                        ? .prose(model)
                        : .richMarkdown(model)
                }
            }
        }
    }

    static func wholeDocumentMarkdownRenderRequests(
        in rows: [ChatTimelineRowModel],
        streamingTurnID: String?,
        segmentCache: ChatMarkdownSegmentCache
    ) -> [ChatMarkdownRenderRequest] {
        rows.compactMap { row in
            guard case .message(let message) = row,
                message.role == ChatRole.assistant.rawValue,
                streamingTurnID == nil || message.turnID != streamingTurnID,
                case .existingRenderer = ChatMessageTextPlanner.plan(
                    messageID: message.id,
                    role: message.role,
                    messageTurnID: message.turnID,
                    streamingTurnID: streamingTurnID,
                    source: message.text,
                    segmentCache: segmentCache
                )
            else { return nil }
            return ChatMarkdownRenderRequest(
                messageID: message.id,
                source: message.text
            )
        }
    }

    static func markdownRenderRequests(
        in rows: [ChatTimelineRenderRow],
        streamingTurnID: String?
    ) -> [ChatMarkdownRenderRequest] {
        rows.compactMap { row in
            switch row {
            case .standard(.message(let message)):
                guard
                    message.role != ChatRole.assistant.rawValue
                        || streamingTurnID == nil
                        || message.turnID != streamingTurnID
                else { return nil }
                return ChatMarkdownRenderRequest(
                    messageID: message.id,
                    source: message.text
                )

            case .richMarkdown(let segment):
                return ChatMarkdownRenderRequest(
                    messageID: segment.rowID,
                    source: segment.source
                )

            case .standard, .prose, .resolvedMarkdown:
                return nil
            }
        }
    }

    /// All native-text layouts needed by one bounded set of timeline rows.
    /// Complete preparation prevents rapid scrolling from outrunning a
    /// newest-only preparation and falling back to synchronous main-thread layout.
    static func textLayoutRequests(
        in rows: [ChatTimelineRenderRow],
        streamingTurnID: String?,
        rowWidth: CGFloat
    ) -> [ChatTextLayoutRequest] {
        var requests: [ChatTextLayoutRequest] = []

        func appendRichRequests(
            messageID: String,
            source: String,
            role: String
        ) {
            guard let plan = ChatMarkdownRenderCache.shared.cachedPlan(
                messageID: messageID,
                source: source
            ) else { return }

            for (index, block) in plan.blocks.enumerated() {
                let id = "\(messageID)-block-\(index)"
                switch block {
                case .prose(let prose):
                    requests.append(
                        ChatTextLayoutRequest(
                            id: id,
                            content: .rendered(prose.text),
                            width: ChatTimelineMetrics.proseTextWidth(
                                role: role,
                                in: rowWidth
                            )
                        )
                    )
                case .code, .table:
                    break
                }
            }
        }

        for row in rows {
            switch row {
            case .prose(let segment):
                requests.append(
                    ChatTextLayoutRequest(
                        id: segment.rowID,
                        content: .source(segment.source),
                        width: ChatTimelineMetrics.proseTextWidth(
                            role: segment.role,
                            in: rowWidth
                        )
                    )
                )
            case .richMarkdown(let segment):
                appendRichRequests(
                    messageID: segment.rowID,
                    source: segment.source,
                    role: segment.role
                )
            case .standard(.message(let message)):
                guard
                    message.role != ChatRole.assistant.rawValue
                        || streamingTurnID == nil
                        || message.turnID != streamingTurnID
                else { continue }
                appendRichRequests(
                    messageID: message.id,
                    source: message.text,
                    role: message.role
                )
            case .resolvedMarkdown(let block):
                guard case .proseRun(let prose) = block.content else { continue }
                requests.append(
                    ChatTextLayoutRequest(
                        id: block.rowID,
                        content: .rendered(prose.text),
                        width: ChatTimelineMetrics.proseTextWidth(
                            role: ChatRole.assistant.rawValue,
                            in: rowWidth
                        )
                    )
                )
            case .standard:
                break
            }
        }
        return requests
    }
}
