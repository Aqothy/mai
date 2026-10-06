#if os(macOS)
    import AppKit
    import SwiftUI

    /// Attributed content and exact measurement for one prose segment.
    /// The background TextKit graph is used only for measurement: every
    /// visible NSTextView owns its display graph, as required by AppKit's
    /// one-view-per-text-container ownership model. Decoration geometry is
    /// captured here so drawing never re-walks the attributed string.
    nonisolated final class ChatTextLayout: @unchecked Sendable {
        let width: CGFloat
        let height: CGFloat
        /// Width the laid-out lines actually occupy. Equals `width` for
        /// wrapped prose; meaningful for unwrapped code laid out unbounded.
        let contentWidth: CGFloat
        let attributedString: NSAttributedString
        let quoteBarRects: [NSRect]
        let thematicBreakRects: [NSRect]
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
                containerSize: NSSize(
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

            var quoteBarRects: [NSRect] = []
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
                        NSRect(
                            x: offset,
                            y: bounds.minY,
                            width: ChatMarkdownProseStyle.quoteBarWidth,
                            height: bounds.height
                        )
                    )
                }
            }

            var thematicBreakRects: [NSRect] = []
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
                    NSRect(
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
    /// recycling stays with each host view on macOS: every host owns one
    /// NSTextView for its lifetime, so there is one reuse lifecycle to
    /// reason about.
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

        /// UIKit's pooled-text-view lifecycle does not exist on macOS; the
        /// timeline calls these symmetrically on both platforms.
        func activateTextViewReuse() {}
        func deactivateTextViewReuse() {}

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
                code: ChatMacCodeStyle.attributedString(code: block.code)
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
                            let text = await ChatMacCodeStyle.highlightedAttributedString(
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

    /// Native macOS range selection for chat prose.
    struct ChatSelectableText: NSViewRepresentable {
        @Environment(\.chatAnnotationContext) private var annotationContext
        let layoutID: String
        let content: ChatTextContent
        let layoutStore: ChatTextLayoutStore

        func makeNSView(context: Context) -> ChatSelectableTextHostView {
            ChatSelectableTextHostView()
        }

        func updateNSView(
            _ nsView: ChatSelectableTextHostView,
            context: Context
        ) {
            nsView.annotationContext = annotationContext
            nsView.update(layoutID: layoutID, content: content, layoutStore: layoutStore)
        }

        static func dismantleNSView(
            _ nsView: ChatSelectableTextHostView,
            coordinator: Void
        ) {
            nsView.dismantle()
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            nsView: ChatSelectableTextHostView,
            context: Context
        ) -> CGSize? {
            guard let width = proposal.width, width > 0 else { return nil }
            let layout = layoutStore.layout(id: layoutID, content: content, width: width)
            return CGSize(width: width, height: layout.height)
        }
    }

    final class ChatSelectableTextHostView: NSView {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        private final class MarkdownDecorationView: NSView {
            // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
            nonisolated deinit {}

            var quoteBarRects: [NSRect] = []
            var thematicBreakRects: [NSRect] = []

            override var isFlipped: Bool { true }

            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func draw(_ dirtyRect: NSRect) {
                NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
                for rect in quoteBarRects where rect.intersects(dirtyRect) {
                    NSBezierPath(
                        roundedRect: rect,
                        xRadius: ChatMarkdownProseStyle.quoteBarWidth / 2,
                        yRadius: ChatMarkdownProseStyle.quoteBarWidth / 2
                    ).fill()
                }

                NSColor.separatorColor.setFill()
                for rect in thematicBreakRects where rect.intersects(dirtyRect) {
                    NSBezierPath(rect: rect).fill()
                }
            }
        }

        var annotationContext: ChatAnnotationContext? {
            didSet { (textView as? ChatAnnotationTextView)?.annotationContext = annotationContext }
        }

        private var decorationView: MarkdownDecorationView?
        private let textView: NSTextView
        private var layoutID: String?
        private var content: ChatTextContent?
        private weak var layoutStore: ChatTextLayoutStore?
        private var presentedLayout: ChatTextLayout?
        private var presentedLayoutID: String?

        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            textView = ChatSelectableTextViewConfiguration.makeTextView()
            super.init(frame: frameRect)
            addSubview(textView)
        }

        convenience init() {
            self.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(
            layoutID: String,
            content: ChatTextContent,
            layoutStore: ChatTextLayoutStore
        ) {
            guard self.layoutID != layoutID || self.content != content
                || self.layoutStore !== layoutStore
            else { return }
            self.layoutID = layoutID
            self.content = content
            self.layoutStore = layoutStore
            needsLayout = true
        }

        override func layout() {
            super.layout()
            guard let layoutID, let content, let layoutStore,
                bounds.width > 0, bounds.height >= 0
            else { return }

            let layout = layoutStore.layout(id: layoutID, content: content, width: bounds.width)
            if presentedLayout !== layout {
                present(layout)
            }
            Self.resize(textView, to: bounds)
            decorationView?.frame = bounds
        }

        func dismantle() {
            annotationContext = nil
            decorationView?.removeFromSuperview()
            decorationView = nil
            presentedLayout = nil
            presentedLayoutID = nil
            layoutID = nil
            content = nil
            layoutStore = nil
        }

        private func present(_ layout: ChatTextLayout) {
            let selection: NSRange? =
                presentedLayoutID == layoutID
                ? textView.selectedRange()
                : nil
            Self.resize(textView, to: bounds)
            textView.textStorage?.setAttributedString(layout.attributedString)
            if let selection,
                NSMaxRange(selection) <= layout.attributedString.length
            {
                textView.setSelectedRange(selection)
            } else {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            }

            decorationView?.removeFromSuperview()
            decorationView = nil
            if layout.hasMarkdownDecorations {
                let decorations = MarkdownDecorationView(frame: bounds)
                decorations.setAccessibilityElement(false)
                decorations.quoteBarRects = layout.quoteBarRects
                decorations.thematicBreakRects = layout.thematicBreakRects
                addSubview(
                    decorations,
                    positioned: .below,
                    relativeTo: textView
                )
                decorationView = decorations
            }
            presentedLayout = layout
            presentedLayoutID = layoutID
        }

        private static func resize(_ view: NSTextView, to bounds: NSRect) {
            if view.frame != bounds {
                view.frame = bounds
            }
            let containerSize = NSSize(
                width: max(1, bounds.width),
                height: .greatestFiniteMagnitude
            )
            if view.textContainer?.containerSize != containerSize {
                view.textContainer?.containerSize = containerSize
            }
        }
    }
#endif
