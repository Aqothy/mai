#if os(macOS)
    import AppKit
    import SwiftUI

    /// Immutable attributed content and exact measurement for one prose segment.
    /// The background TextKit graph is used only for measurement: every visible
    /// NSTextView owns its display graph, as required by AppKit's one-view-per-
    /// text-container ownership model.
    nonisolated final class ChatMacTextLayout: @unchecked Sendable {
        let width: CGFloat
        let height: CGFloat
        let attributedString: NSAttributedString
        let quoteBarRects: [NSRect]
        let thematicBreakRects: [NSRect]
        let hasMarkdownDecorations: Bool

        init(
            source: String,
            style: ChatTextLayoutStyle,
            width: CGFloat
        ) {
            let safeWidth = max(1, width)
            let attributedString = switch style {
            case .markdownProse:
                ChatProseMarkdownRenderer.attributedString(from: source)
            case .plain:
                Self.plainAttributedString(from: source)
            }
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
                let offsets = attributedString.attribute(
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

            self.width = safeWidth
            self.height = ceil(max(1, manager.usedRect(for: container).height))
            self.attributedString = attributedString
            self.quoteBarRects = quoteBarRects
            self.thematicBreakRects = thematicBreakRects
            self.hasMarkdownDecorations =
                !quoteBarRects.isEmpty || !thematicBreakRects.isEmpty
        }

        private static func plainAttributedString(
            from source: String
        ) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2
            return NSAttributedString(
                string: source,
                attributes: [
                    .font: NSFont.preferredFont(forTextStyle: .body),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph,
                ]
            )
        }
    }

    /// Thread-local cache for exact measurements. Native view recycling stays
    /// with List so there is only one reuse lifecycle to reason about.
    final class ChatMacTextLayoutStore: ChatNativeTextLayoutStore {
        private struct Key: Hashable, Sendable {
            let id: String
            let width: CGFloat
        }

        private struct Entry {
            let source: String
            let style: ChatTextLayoutStyle
            let layout: ChatMacTextLayout
        }

        private var entries: [Key: Entry] = [:]
        private var warming: Set<Key> = []

        func layout(
            id: String,
            source: String,
            style: ChatTextLayoutStyle,
            width: CGFloat
        ) -> ChatMacTextLayout {
            let key = Key(id: id, width: width)
            if let entry = entries[key],
                entry.source == source,
                entry.style == style
            {
                return entry.layout
            }

            let layout = ChatMacTextLayout(
                source: source,
                style: style,
                width: width
            )
            insert(layout, source: source, style: style, for: key)
            return layout
        }

        func warm(requests: [ChatTextLayoutRequest]) {
            let pending = claimPending(from: requests)
            guard !pending.isEmpty else { return }

            Task.detached(priority: .userInitiated) { [self] in
                for item in pending {
                    let layout = ChatMacTextLayout(
                        source: item.request.source,
                        style: item.request.style,
                        width: item.request.width
                    )
                    await finishWarmup(
                        layout,
                        source: item.request.source,
                        style: item.request.style,
                        key: item.key
                    )
                }
            }
        }

        func prepare(requests: [ChatTextLayoutRequest]) async {
            let pending = claimPending(from: requests)
            guard !pending.isEmpty else { return }

            let worker = Task.detached(priority: .userInitiated) {
                var layouts: [ChatMacTextLayout] = []
                layouts.reserveCapacity(pending.count)
                for item in pending {
                    guard !Task.isCancelled else { break }
                    layouts.append(
                        ChatMacTextLayout(
                            source: item.request.source,
                            style: item.request.style,
                            width: item.request.width
                        )
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
                finishWarmup(
                    layout,
                    source: item.request.source,
                    style: item.request.style,
                    key: item.key
                )
            }
            for item in pending.dropFirst(layouts.count) {
                warming.remove(item.key)
            }
        }

        private func claimPending(
            from requests: [ChatTextLayoutRequest]
        ) -> [(request: ChatTextLayoutRequest, key: Key)] {
            var pending: [(request: ChatTextLayoutRequest, key: Key)] = []
            var seen: Set<Key> = []
            for request in requests.suffix(ChatTextLayoutWarmup.maximumRequestCount)
                .reversed()
            where request.width > 0 {
                let key = Key(id: request.id, width: request.width)
                guard seen.insert(key).inserted,
                    entries[key]?.source != request.source
                        || entries[key]?.style != request.style,
                    !warming.contains(key)
                else { continue }
                warming.insert(key)
                pending.append((request, key))
            }
            return pending
        }

        private func finishWarmup(
            _ layout: ChatMacTextLayout,
            source: String,
            style: ChatTextLayoutStyle,
            key: Key
        ) {
            warming.remove(key)
            guard entries[key]?.source != source || entries[key]?.style != style
            else { return }
            insert(layout, source: source, style: style, for: key)
        }

        private func insert(
            _ layout: ChatMacTextLayout,
            source: String,
            style: ChatTextLayoutStyle,
            for key: Key
        ) {
            entries[key] = Entry(
                source: source,
                style: style,
                layout: layout
            )
        }

    }

    /// Native macOS range selection for settled prose. The optional callback
    /// is the extension point for selection-driven annotations and menus.
    struct ChatMacSelectableText: NSViewRepresentable {
        let layoutID: String
        let source: String
        let style: ChatTextLayoutStyle
        let layoutStore: ChatMacTextLayoutStore
        var onSelectionChange: ((ChatTextSelection?) -> Void)? = nil

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeNSView(context: Context) -> ChatMacSelectableTextHostView {
            ChatMacSelectableTextHostView()
        }

        func updateNSView(
            _ nsView: ChatMacSelectableTextHostView,
            context: Context
        ) {
            context.coordinator.layoutID = layoutID
            context.coordinator.onSelectionChange = onSelectionChange
            nsView.selectionDelegate = onSelectionChange == nil
                ? nil
                : context.coordinator
            nsView.update(
                layoutID: layoutID,
                source: source,
                style: style,
                layoutStore: layoutStore
            )
        }

        static func dismantleNSView(
            _ nsView: ChatMacSelectableTextHostView,
            coordinator: Coordinator
        ) {
            nsView.dismantle()
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            nsView: ChatMacSelectableTextHostView,
            context: Context
        ) -> CGSize? {
            guard let width = proposal.width, width > 0 else { return nil }
            let layout = layoutStore.layout(
                id: layoutID,
                source: source,
                style: style,
                width: width
            )
            return CGSize(width: width, height: layout.height)
        }

        final class Coordinator: NSObject, NSTextViewDelegate {
            var layoutID = ""
            var onSelectionChange: ((ChatTextSelection?) -> Void)?

            func textViewDidChangeSelection(_ notification: Notification) {
                guard let textView = notification.object as? NSTextView,
                    let onSelectionChange
                else { return }
                let range = textView.selectedRange()
                guard range.length > 0,
                    let textStorage = textView.textStorage,
                    NSMaxRange(range) <= textStorage.length
                else {
                    onSelectionChange(nil)
                    return
                }
                onSelectionChange(
                    ChatTextSelection(
                        layoutID: layoutID,
                        range: range,
                        text: textStorage.attributedSubstring(from: range).string
                    )
                )
            }
        }
    }

    final class ChatMacSelectableTextHostView: NSView {
        private final class MarkdownDecorationView: NSView {
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

        weak var selectionDelegate: NSTextViewDelegate? {
            didSet { textView.delegate = selectionDelegate }
        }

        private var decorationView: MarkdownDecorationView?
        private let textView: NSTextView
        private var layoutID: String?
        private var source: String?
        private var style: ChatTextLayoutStyle?
        private weak var layoutStore: ChatMacTextLayoutStore?
        private var presentedLayout: ChatMacTextLayout?
        private var presentedLayoutID: String?

        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            textView = ChatMacSelectableTextViewConfiguration.makeTextView()
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
            style: ChatTextLayoutStyle,
            layoutStore: ChatMacTextLayoutStore
        ) {
            guard self.layoutID != layoutID || self.source != source
                || self.style != style || self.layoutStore !== layoutStore
            else { return }
            self.layoutID = layoutID
            self.source = source
            self.style = style
            self.layoutStore = layoutStore
            needsLayout = true
        }

        override func layout() {
            super.layout()
            guard let layoutID, let source, let style, let layoutStore,
                bounds.width > 0, bounds.height >= 0
            else { return }

            let layout = layoutStore.layout(
                id: layoutID,
                source: source,
                style: style,
                width: bounds.width
            )
            if presentedLayout !== layout {
                present(layout)
            }
            Self.resize(textView, to: bounds)
            decorationView?.frame = bounds
        }

        func dismantle() {
            textView.delegate = nil
            decorationView?.removeFromSuperview()
            decorationView = nil
            presentedLayout = nil
            presentedLayoutID = nil
            layoutID = nil
            source = nil
            style = nil
            layoutStore = nil
        }

        private func present(_ layout: ChatMacTextLayout) {
            let selection: NSRange? = presentedLayoutID == layoutID
                ? textView.selectedRange()
                : nil
            Self.resize(textView, to: bounds)
            textView.textStorage?.setAttributedString(layout.attributedString)
            if let manager = textView.layoutManager,
                let container = textView.textContainer
            {
                manager.ensureLayout(for: container)
            }
            if let selection,
                NSMaxRange(selection) <= layout.attributedString.length
            {
                textView.setSelectedRange(selection)
            } else {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            }
            textView.delegate = selectionDelegate

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
