import SwiftUI

/// What a selectable text view shows: Markdown source rendered on demand, or
/// text a render plan already rendered from its parsed document.
nonisolated enum ChatTextContent: Equatable, Sendable {
    case source(String)
    case rendered(ChatMarkdownText)

    var attributedString: NSAttributedString {
        switch self {
        case .source(let source):
            ChatMarkdownTextRenderer.attributedString(from: source)
        case .rendered(let text):
            text.value
        }
    }

    var utf8Count: Int {
        switch self {
        case .source(let source): source.utf8.count
        case .rendered(let text): text.string.utf8.count
        }
    }
}

nonisolated struct ChatTextLayoutRequest: Sendable {
    let id: String
    let content: ChatTextContent
    let width: CGFloat
}

/// A settled fenced code block whose highlighted, measured text can be
/// prepared before its row is realized.
nonisolated struct ChatCodeLayoutRequest: Sendable {
    let id: String
    let block: ChatMarkdownCodeBlock
    let theme: ChatCodeHighlightTheme
}

/// A settled table whose cell measurement can be prepared before its row is
/// realized.
nonisolated struct ChatTableLayoutRequest: Sendable {
    let id: String
    let table: ChatMarkdownTable
}

/// Attributed content and exact measurement for one prose segment.
/// The background TextKit graph is used only for measurement: every visible
/// text view owns its display graph. AppKit requires one view per text
/// container, and a UITextView handed a measured stack invalidates it and
/// lays the whole string out again. Decoration geometry is captured here so
/// drawing never re-walks the attributed string.
nonisolated final class ChatTextLayout: @unchecked Sendable {
    let width: CGFloat
    let height: CGFloat
    /// Width the laid-out lines actually occupy. Equals `width` for
    /// wrapped prose; meaningful for unwrapped code laid out unbounded.
    let contentWidth: CGFloat
    let attributedString: NSAttributedString
    let quoteBarRects: [CGRect]
    let thematicBreakRects: [CGRect]
    let hasMarkdownDecorations: Bool

    convenience init(content: ChatTextContent, width: CGFloat) {
        self.init(attributedString: content.attributedString, width: width)
    }

    /// Unwrapped code: lines run to their natural width and the host
    /// scrolls horizontally.
    convenience init(code: NSAttributedString) {
        self.init(
            attributedString: code,
            width: .greatestFiniteMagnitude
        )
    }

    private init(
        attributedString: NSAttributedString,
        width: CGFloat
    ) {
        let safeWidth = max(1, width)
        let storage = NSTextStorage(attributedString: attributedString)
        let manager = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(
                width: safeWidth,
                height: .greatestFiniteMagnitude
            )
        )
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        var rangesByOffset: [CGFloat: [NSRange]] = [:]
        var index = 0
        while index < attributedString.length {
            var range = NSRange()
            let offsets =
                attributedString.attribute(
                    .chatQuoteBarOffsets,
                    at: index,
                    effectiveRange: &range
                ) as? [CGFloat] ?? []
            index = NSMaxRange(range)

            for offset in offsets {
                var ranges = rangesByOffset[offset, default: []]
                if let previous = ranges.last,
                    NSMaxRange(previous) == range.location
                {
                    ranges[ranges.count - 1] = NSUnionRange(previous, range)
                } else {
                    ranges.append(range)
                }
                rangesByOffset[offset] = ranges
            }
        }

        var quoteBarRects: [CGRect] = []
        for (offset, ranges) in rangesByOffset {
            for range in ranges {
                let glyphRange = manager.glyphRange(
                    forCharacterRange: range,
                    actualCharacterRange: nil
                )
                let bounds = manager.boundingRect(
                    forGlyphRange: glyphRange,
                    in: container
                )
                quoteBarRects.append(
                    CGRect(
                        x: offset,
                        y: bounds.minY,
                        width: ChatMarkdownProseStyle.quoteBarWidth,
                        height: bounds.height
                    )
                )
            }
        }

        var thematicBreakRects: [CGRect] = []
        attributedString.enumerateAttribute(
            .chatThematicBreakIndent,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, range, _ in
            guard let indent = value as? CGFloat else { return }
            let glyphRange = manager.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else { return }
            let line = manager.lineFragmentRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil
            )
            thematicBreakRects.append(
                CGRect(
                    x: indent,
                    y: line.midY,
                    width: max(0, container.size.width - indent),
                    height: 1
                )
            )
        }

        let usedRect = manager.usedRect(for: container)
        self.width = safeWidth
        self.height = ceil(max(1, usedRect.height))
        self.contentWidth = ceil(usedRect.width)
        self.attributedString = attributedString
        self.quoteBarRects = quoteBarRects
        self.thematicBreakRects = thematicBreakRects
        self.hasMarkdownDecorations =
            !quoteBarRects.isEmpty || !thematicBreakRects.isEmpty
    }
}

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
