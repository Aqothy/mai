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

        convenience init(source: String, width: CGFloat) {
            self.init(
                attributedString: ChatProseMarkdownRenderer.attributedString(from: source),
                width: width
            )
        }

        convenience init(
            resolvedProse prose: ChatMarkdownProseRun,
            width: CGFloat
        ) {
            self.init(
                attributedString: Self.attributedString(from: prose),
                width: width
            )
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

        /// Converts an already-resolved whole-document prose run into the
        /// AppKit attributes used by the normal selectable Markdown path.
        /// Links come from the resolved value, so definitions outside this
        /// run never need to be reparsed or duplicated.
        private static func attributedString(
            from prose: ChatMarkdownProseRun
        ) -> NSAttributedString {
            let output = NSMutableAttributedString()
            for piece in prose.pieces {
                if output.length > 0 {
                    appendBlockSpacer(to: output)
                }

                switch piece {
                case .text(let text):
                    append(text, quoteBarOffset: nil, to: output)
                case .quote(let quote):
                    append(quote, quoteBarOffset: 0, to: output)
                case .thematicBreak:
                    let start = output.length
                    output.append(
                        NSAttributedString(
                            string: "---\n",
                            attributes: [
                                .font: NSFont.preferredFont(
                                    forTextStyle: .body
                                ),
                                .foregroundColor: NSColor.clear,
                            ]
                        )
                    )
                    output.addAttribute(
                        .chatThematicBreakIndent,
                        value: CGFloat.zero,
                        range: NSRange(
                            location: start,
                            length: output.length - start
                        )
                    )
                }
            }
            while output.string.hasSuffix("\n") {
                output.deleteCharacters(
                    in: NSRange(location: output.length - 1, length: 1)
                )
            }
            return output
        }

        private static func append(
            _ value: AttributedString,
            quoteBarOffset: CGFloat?,
            to output: NSMutableAttributedString
        ) {
            let inline = inlineAttributedString(from: value)
            guard inline.length > 0 else { return }
            let start = output.length
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = ChatMarkdownProseStyle.lineSpacing
            if quoteBarOffset != nil {
                paragraph.firstLineHeadIndent =
                    ChatMarkdownProseStyle.quoteBarWidth
                    + ChatMarkdownProseStyle.quoteIndent
                paragraph.headIndent = paragraph.firstLineHeadIndent
            }
            inline.addAttribute(
                .paragraphStyle,
                value: paragraph,
                range: NSRange(location: 0, length: inline.length)
            )
            output.append(inline)

            output.append(NSAttributedString(string: "\n"))
            if let quoteBarOffset {
                output.addAttribute(
                    .chatQuoteBarOffsets,
                    value: [quoteBarOffset],
                    range: NSRange(
                        location: start,
                        length: output.length - start
                    )
                )
            }
        }

        /// Converts inline Markdown intents (code, emphasis, headings,
        /// strikethrough, links) from the parser's `AttributedString` into
        /// AppKit attributes. Shared by resolved prose runs and table cells.
        static func inlineAttributedString(
            from value: AttributedString
        ) -> NSMutableAttributedString {
            let string = String(value.characters)
            let output = NSMutableAttributedString(
                string: string,
                attributes: [
                    .font: NSFont.preferredFont(forTextStyle: .body),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            guard !string.isEmpty else { return output }

            for run in value.runs {
                let prefix = String(
                    value[value.startIndex..<run.range.lowerBound].characters
                )
                let runText = String(value[run.range].characters)
                let range = NSRange(
                    location: prefix.utf16.count,
                    length: runText.utf16.count
                )
                guard range.length > 0 else { continue }

                let intents = run.inlinePresentationIntent ?? []
                let headingLevel = run.accessibilityHeadingLevel?.rawValue
                var font: NSFont
                if intents.contains(.code) {
                    font = NSFont.monospacedSystemFont(
                        ofSize: NSFont.preferredFont(
                            forTextStyle: .body
                        ).pointSize,
                        weight: .regular
                    )
                } else if let headingLevel {
                    font = NSFont.preferredFont(
                        forTextStyle: ChatMarkdownProseStyle.headingTextStyle(
                            level: headingLevel
                        )
                    )
                } else {
                    font = NSFont.preferredFont(forTextStyle: .body)
                }
                if intents.contains(.stronglyEmphasized) {
                    font = NSFontManager.shared.convert(
                        font,
                        toHaveTrait: .boldFontMask
                    )
                }
                if intents.contains(.emphasized) {
                    font = NSFontManager.shared.convert(
                        font,
                        toHaveTrait: .italicFontMask
                    )
                }
                output.addAttribute(.font, value: font, range: range)
                if intents.contains(.strikethrough) {
                    output.addAttribute(
                        .strikethroughStyle,
                        value: NSUnderlineStyle.single.rawValue,
                        range: range
                    )
                }
                if let link = run.link {
                    output.addAttribute(.link, value: link, range: range)
                    output.addAttribute(
                        .underlineStyle,
                        value: NSUnderlineStyle.single.rawValue,
                        range: range
                    )
                }
            }
            return output
        }

        private static func appendBlockSpacer(
            to output: NSMutableAttributedString
        ) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = ChatMarkdownProseStyle.blockSpacing
            paragraph.maximumLineHeight = ChatMarkdownProseStyle.blockSpacing
            output.append(
                NSAttributedString(
                    string: "\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 1),
                        .paragraphStyle: paragraph,
                    ]
                )
            )
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
            let source: String
            let layout: ChatTextLayout
        }

        private struct ResolvedEntry {
            let prose: ChatMarkdownProseRun
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
        private var resolvedEntries: [Key: ResolvedEntry] = [:]
        private var resolvedInFlightKeys: Set<Key> = []
        private var codeEntries: [String: CodeEntry] = [:]
        private var codeInFlightIDs: Set<String> = []
        private var tableEntries: [String: TableEntry] = [:]
        private var tableInFlightIDs: Set<String> = []

        #if DEBUG
        var cachedLayoutCount: Int {
            entries.count + resolvedEntries.count + codeEntries.count + tableEntries.count
        }
        #endif

        /// UIKit's pooled-text-view lifecycle does not exist on macOS; the
        /// timeline calls these symmetrically on both platforms.
        func activateTextViewReuse() {}
        func deactivateTextViewReuse() {}

        func layout(
            id: String,
            source: String,
            width: CGFloat
        ) -> ChatTextLayout {
            let key = Key(id: id, width: width)
            if let entry = entries[key], entry.source == source {
                return entry.layout
            }

            // A visible row can beat background preparation. Build
            // synchronously so the transcript never flashes a placeholder or
            // temporarily reports the wrong height.
            #if DEBUG
                ChatBenchmarkAutoRun.trace(
                    "layout miss id=\(id) width=\(width) cached=\(entries[key] != nil) bytes=\(source.utf8.count)"
                )
            #endif
            let layout = ChatTextLayout(source: source, width: width)
            entries[key] = Entry(source: source, layout: layout)
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
                    return entries[key]?.source != request.source
                }
                if remaining.isEmpty || Task.isCancelled { break }
                if pending.isEmpty {
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
        }

        func resolvedLayout(
            id: String,
            prose: ChatMarkdownProseRun,
            width: CGFloat
        ) -> ChatTextLayout {
            let key = Key(id: id, width: width)
            if let entry = resolvedEntries[key], entry.prose == prose {
                return entry.layout
            }
            #if DEBUG
                ChatBenchmarkAutoRun.trace(
                    "resolved layout miss id=\(id) width=\(width) bytes=\(prose.source.utf8.count)"
                )
            #endif
            let layout = ChatTextLayout(
                resolvedProse: prose,
                width: width
            )
            resolvedEntries[key] = ResolvedEntry(
                prose: prose,
                layout: layout
            )
            return layout
        }

        func prepareResolvedProse(
            requests: [ChatResolvedProseLayoutRequest]
        ) async {
            var remaining = requests.filter { $0.width > 0 }
            while !remaining.isEmpty, !Task.isCancelled {
                var pending: [(ChatResolvedProseLayoutRequest, Key)] = []
                var seen: Set<Key> = []
                for request in remaining.reversed() {
                    let key = Key(id: request.id, width: request.width)
                    guard seen.insert(key).inserted,
                        resolvedEntries[key]?.prose != request.prose,
                        !resolvedInFlightKeys.contains(key)
                    else { continue }
                    resolvedInFlightKeys.insert(key)
                    pending.append((request, key))
                }
                if !pending.isEmpty {
                    let claimed = pending
                    let worker = Task.detached(priority: .userInitiated) {
                        claimed.map { request, _ in
                            ChatTextLayout(
                                resolvedProse: request.prose,
                                width: request.width
                            )
                        }
                    }
                    let layouts = await withTaskCancellationHandler {
                        await worker.value
                    } onCancel: {
                        worker.cancel()
                    }
                    for ((request, key), layout) in zip(claimed, layouts) {
                        resolvedInFlightKeys.remove(key)
                        if resolvedEntries[key]?.prose != request.prose {
                            resolvedEntries[key] = ResolvedEntry(
                                prose: request.prose,
                                layout: layout
                            )
                        }
                    }
                }
                remaining = remaining.filter { request in
                    let key = Key(id: request.id, width: request.width)
                    return resolvedEntries[key]?.prose != request.prose
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
                        ChatTextLayout(source: item.request.source, width: item.request.width)
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
                if entries[item.key]?.source != item.request.source {
                    entries[item.key] = Entry(source: item.request.source, layout: layout)
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
                    entries[key]?.source != request.source,
                    !inFlightKeys.contains(key)
                else { continue }
                inFlightKeys.insert(key)
                pending.append((request, key))
            }
            return pending
        }

    }

    /// Native macOS range selection for settled prose.
    struct ChatSelectableText: NSViewRepresentable {
        @Environment(\.chatAnnotationContext) private var annotationContext
        let layoutID: String
        let source: String
        let layoutStore: ChatTextLayoutStore

        func makeNSView(context: Context) -> ChatSelectableTextHostView {
            ChatSelectableTextHostView()
        }

        func updateNSView(
            _ nsView: ChatSelectableTextHostView,
            context: Context
        ) {
            nsView.annotationContext = annotationContext
            nsView.update(layoutID: layoutID, source: source, layoutStore: layoutStore)
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
            let layout = layoutStore.layout(id: layoutID, source: source, width: width)
            return CGSize(width: width, height: layout.height)
        }
    }

    struct ChatSelectableResolvedProse: NSViewRepresentable {
        @Environment(\.chatAnnotationContext) private var annotationContext
        let layoutID: String
        let prose: ChatMarkdownProseRun
        let layoutStore: ChatTextLayoutStore

        func makeNSView(context: Context) -> ChatSelectableTextHostView {
            ChatSelectableTextHostView()
        }

        func updateNSView(
            _ nsView: ChatSelectableTextHostView,
            context: Context
        ) {
            nsView.annotationContext = annotationContext
            nsView.update(
                layoutID: layoutID,
                resolvedProse: prose,
                layoutStore: layoutStore
            )
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
            let layout = layoutStore.resolvedLayout(
                id: layoutID,
                prose: prose,
                width: width
            )
            return CGSize(width: width, height: layout.height)
        }
    }

    final class ChatSelectableTextHostView: NSView {
        // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
        nonisolated deinit {}

        private enum Content: Equatable {
            case source(String)
            case resolvedProse(ChatMarkdownProseRun)
        }

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
        private var content: Content?
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
            source: String,
            layoutStore: ChatTextLayoutStore
        ) {
            update(
                layoutID: layoutID,
                content: .source(source),
                layoutStore: layoutStore
            )
        }

        func update(
            layoutID: String,
            resolvedProse: ChatMarkdownProseRun,
            layoutStore: ChatTextLayoutStore
        ) {
            update(
                layoutID: layoutID,
                content: .resolvedProse(resolvedProse),
                layoutStore: layoutStore
            )
        }

        private func update(
            layoutID: String,
            content: Content,
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

            let layout = switch content {
            case .source(let source):
                layoutStore.layout(id: layoutID, source: source, width: bounds.width)
            case .resolvedProse(let prose):
                layoutStore.resolvedLayout(
                    id: layoutID,
                    prose: prose,
                    width: bounds.width
                )
            }
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
