import SwiftUI

/// Thread-owned cache for completed and in-flight layouts. Native view
/// recycling stays with each host view: every host owns one text view for
/// its lifetime, so there is one reuse lifecycle to reason about.
@MainActor final class ChatTextLayoutStore {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    private struct Key: Hashable, Sendable {
        let id: String
        let width: CGFloat
    }

    private struct Entry {
        let content: ChatTextContent
        let layout: ChatTextLayout
    }

    private struct CodeEntry {
        let block: ChatMarkdownCodeBlock
        let theme: ChatCodeHighlightTheme
        let layout: ChatTextLayout
        /// A synchronous miss stores plain text; preparation replaces it
        /// with the highlighted form at the same metrics.
        let isHighlighted: Bool
    }

    private struct TableEntry {
        let table: ChatMarkdownTable
        let layout: ChatTableLayout
    }

    private var entries: [Key: Entry] = [:]
    private var inFlightKeys: Set<Key> = []
    private var codeEntries: [String: CodeEntry] = [:]
    private var codeInFlightIDs: Set<String> = []
    private var tableEntries: [String: TableEntry] = [:]
    private var tableInFlightIDs: Set<String> = []

    #if DEBUG
    var cachedLayoutCount: Int {
        entries.count + codeEntries.count + tableEntries.count
    }
    #endif

    func layout(
        id: String,
        content: ChatTextContent,
        width: CGFloat
    ) -> ChatTextLayout {
        let key = Key(id: id, width: width)
        if let entry = entries[key], entry.content == content {
            return entry.layout
        }

        // A visible row can beat background preparation. Build
        // synchronously so the transcript never flashes a placeholder or
        // temporarily reports the wrong height.
        #if DEBUG
            ChatBenchmarkAutoRun.trace(
                "layout miss id=\(id) width=\(width) cached=\(entries[key] != nil) bytes=\(content.utf8Count)"
            )
        #endif
        let layout = ChatTextLayout(content: content, width: width)
        entries[key] = Entry(content: content, layout: layout)
        return layout
    }

    /// Prepares rows before they enter the timeline whenever possible.
    /// Cancellation retains layouts that already finished.
    func prepare(requests: [ChatTextLayoutRequest]) async {
        var remaining = requests.filter { $0.width > 0 }
        while !remaining.isEmpty, !Task.isCancelled {
            let pending = claimPending(from: remaining)
            if !pending.isEmpty {
                await buildAndStore(pending)
            }
            remaining = remaining.filter { request in
                let key = Key(id: request.id, width: request.width)
                return entries[key]?.content != request.content
            }
            if remaining.isEmpty || Task.isCancelled { break }
            if pending.isEmpty {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    // MARK: Rich blocks

    /// The code block's prepared layout, or a synchronous plain-text
    /// layout on a miss so the row never flashes a placeholder.
    func codeLayout(
        id: String,
        block: ChatMarkdownCodeBlock,
        theme: ChatCodeHighlightTheme
    ) -> (layout: ChatTextLayout, isHighlighted: Bool) {
        if let entry = codeEntries[id], entry.block == block,
            entry.theme == theme
        {
            return (entry.layout, entry.isHighlighted)
        }
        #if DEBUG
            ChatBenchmarkAutoRun.trace(
                "code layout miss id=\(id) bytes=\(block.code.utf8.count)"
            )
        #endif
        let layout = ChatTextLayout(
            code: ChatCodeBlockStyle.attributedString(code: block.code)
        )
        codeEntries[id] = CodeEntry(
            block: block,
            theme: theme,
            layout: layout,
            isHighlighted: false
        )
        return (layout, false)
    }

    /// Highlights and measures code blocks off the main actor. Runs
    /// after prose preparation: syntax highlighting is JavaScript-backed
    /// and must not delay the text the page is mostly made of.
    func prepareCodeBlocks(requests: [ChatCodeLayoutRequest]) async {
        var remaining = requests
        while !remaining.isEmpty, !Task.isCancelled {
            var pending: [ChatCodeLayoutRequest] = []
            var seen: Set<String> = []
            for request in remaining {
                guard seen.insert(request.id).inserted,
                    !isCodePrepared(request),
                    !codeInFlightIDs.contains(request.id)
                else { continue }
                codeInFlightIDs.insert(request.id)
                pending.append(request)
            }
            if !pending.isEmpty {
                let claimed = pending
                let worker = Task.detached(priority: .userInitiated) {
                    var layouts: [ChatTextLayout] = []
                    layouts.reserveCapacity(claimed.count)
                    for request in claimed {
                        guard !Task.isCancelled else { break }
                        let text = await ChatCodeBlockStyle.highlightedAttributedString(
                            block: request.block,
                            theme: request.theme
                        )
                        layouts.append(ChatTextLayout(code: text))
                    }
                    return layouts
                }
                let layouts = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                for (request, layout) in zip(claimed, layouts) {
                    codeEntries[request.id] = CodeEntry(
                        block: request.block,
                        theme: request.theme,
                        layout: layout,
                        isHighlighted: true
                    )
                }
                for request in claimed {
                    codeInFlightIDs.remove(request.id)
                }
            }
            remaining = remaining.filter { !isCodePrepared($0) }
            if remaining.isEmpty || Task.isCancelled { break }
            if pending.isEmpty {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    private func isCodePrepared(_ request: ChatCodeLayoutRequest) -> Bool {
        guard let entry = codeEntries[request.id] else { return false }
        return entry.block == request.block && entry.theme == request.theme
            && entry.isHighlighted
    }

    /// The table's prepared layout, measured synchronously on a miss.
    func tableLayout(
        id: String,
        table: ChatMarkdownTable
    ) -> ChatTableLayout {
        if let entry = tableEntries[id], entry.table == table {
            return entry.layout
        }
        #if DEBUG
            ChatBenchmarkAutoRun.trace(
                "table layout miss id=\(id) rows=\(table.rows.count)"
            )
        #endif
        let layout = ChatTableLayout(table: table)
        tableEntries[id] = TableEntry(table: table, layout: layout)
        return layout
    }

    func prepareTables(requests: [ChatTableLayoutRequest]) async {
        var remaining = requests
        while !remaining.isEmpty, !Task.isCancelled {
            var pending: [ChatTableLayoutRequest] = []
            var seen: Set<String> = []
            for request in remaining {
                guard seen.insert(request.id).inserted,
                    tableEntries[request.id]?.table != request.table,
                    !tableInFlightIDs.contains(request.id)
                else { continue }
                tableInFlightIDs.insert(request.id)
                pending.append(request)
            }
            if !pending.isEmpty {
                let claimed = pending
                let worker = Task.detached(priority: .userInitiated) {
                    claimed.map { ChatTableLayout(table: $0.table) }
                }
                let layouts = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                for (request, layout) in zip(claimed, layouts) {
                    tableInFlightIDs.remove(request.id)
                    if tableEntries[request.id]?.table != request.table {
                        tableEntries[request.id] = TableEntry(
                            table: request.table,
                            layout: layout
                        )
                    }
                }
            }
            remaining = remaining.filter {
                tableEntries[$0.id]?.table != $0.table
            }
            if remaining.isEmpty || Task.isCancelled { break }
            if pending.isEmpty {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    private func buildAndStore(
        _ pending: [(request: ChatTextLayoutRequest, key: Key)]
    ) async {
        let worker = Task.detached(priority: .userInitiated) {
            var layouts: [ChatTextLayout] = []
            layouts.reserveCapacity(pending.count)
            for item in pending {
                guard !Task.isCancelled else { break }
                layouts.append(
                    ChatTextLayout(content: item.request.content, width: item.request.width)
                )
            }
            return layouts
        }
        let layouts = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        for (item, layout) in zip(pending, layouts) {
            inFlightKeys.remove(item.key)
            if entries[item.key]?.content != item.request.content {
                entries[item.key] = Entry(content: item.request.content, layout: layout)
            }
        }
        // Unbuilt claims must not block future preparation for these rows.
        for item in pending.dropFirst(layouts.count) {
            inFlightKeys.remove(item.key)
        }
    }

    /// Chats open and normally scroll from the bottom, so the newest rows
    /// are prepared first. Sequential layout avoids a burst of competing
    /// TextKit work during interaction.
    private func claimPending(
        from requests: [ChatTextLayoutRequest]
    ) -> [(request: ChatTextLayoutRequest, key: Key)] {
        var pending: [(request: ChatTextLayoutRequest, key: Key)] = []
        var seen: Set<Key> = []
        for request in requests.reversed() {
            let key = Key(id: request.id, width: request.width)
            guard seen.insert(key).inserted,
                entries[key]?.content != request.content,
                !inFlightKeys.contains(key)
            else { continue }
            inFlightKeys.insert(key)
            pending.append((request, key))
        }
        return pending
    }

}
