import SwiftUI

nonisolated enum ChatTextLayoutStyle: Hashable, Sendable {
    case markdownProse
    case plain
}

nonisolated struct ChatTextLayoutRequest: Sendable {
    let id: String
    let source: String
    let style: ChatTextLayoutStyle
    let width: CGFloat
}

nonisolated struct ChatResolvedProseLayoutRequest: Sendable {
    let id: String
    let prose: ChatMarkdownProseRun
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

struct ChatTextSelection: Equatable, Sendable {
    let layoutID: String
    let range: NSRange
    let text: String
}

// The macOS implementation of these same types lives in ChatMacTextLayout.swift.
#if os(iOS)

import UIKit

#if DEBUG
    import OSLog
#endif

#if DEBUG
    /// DEBUG-only breadcrumbs for correlating a visible hitch with the
    /// row that appeared, missed preparation, or expensive native attachment.
    nonisolated enum ChatTextLayoutDiagnostics {
        private static let logger = Logger(
            subsystem: "com.aqothy.mai",
            category: "ChatTextPerformance"
        )

        static func synchronousLayoutMiss(
            id: String,
            style: ChatTextLayoutStyle,
            byteCount: Int,
            durationMilliseconds: Double
        ) {
            let styleName = String(describing: style)
            logger.notice(
                "cache miss id=\(id, privacy: .public) style=\(styleName, privacy: .public) bytes=\(byteCount) ms=\(durationMilliseconds)"
            )
        }

        static func slowAttachment(
            id: String,
            style: ChatTextLayoutStyle,
            byteCount: Int,
            durationMilliseconds: Double,
            reusedTextView: Bool
        ) {
            guard durationMilliseconds >= 8 else { return }
            let styleName = String(describing: style)
            logger.notice(
                "slow attach id=\(id, privacy: .public) style=\(styleName, privacy: .public) bytes=\(byteCount) ms=\(durationMilliseconds) reused=\(reusedTextView)"
            )
        }

        static func rowAppeared(
            id: String,
            role: String,
            path: String,
            byteCount: Int
        ) {
            logger.info(
                "row appeared id=\(id, privacy: .public) role=\(role, privacy: .public) path=\(path, privacy: .public) bytes=\(byteCount)"
            )
        }
    }
#endif

/// Attributed content and measured height for one text segment at one width.
///
/// Measurement uses a short-lived TextKit 1 stack off the main actor. The
/// display view owns a separate stack: attaching this measured stack to a
/// `UITextView` made UIKit invalidate it and lay the whole string out again.
nonisolated final class ChatTextLayout: @unchecked Sendable {
    let width: CGFloat
    let height: CGFloat
    let attributedString: NSAttributedString
    let hasMarkdownDecorations: Bool

    init(
        source: String,
        style: ChatTextLayoutStyle,
        width: CGFloat
    ) {
        let attributedString =
            switch style {
            case .markdownProse:
                ChatProseMarkdownRenderer.attributedString(from: source)
            case .plain:
                Self.plainAttributedString(from: source)
            }
        let storage = NSTextStorage(attributedString: attributedString)
        let manager = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        var hasMarkdownDecorations = false
        attributedString.enumerateAttribute(
            .chatQuoteBarOffsets,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, _, stop in
            guard value != nil else { return }
            hasMarkdownDecorations = true
            stop.pointee = true
        }
        if !hasMarkdownDecorations {
            attributedString.enumerateAttribute(
                .chatThematicBreakIndent,
                in: NSRange(
                    location: 0,
                    length: attributedString.length
                )
            ) { value, _, stop in
                guard value != nil else { return }
                hasMarkdownDecorations = true
                stop.pointee = true
            }
        }

        self.width = width
        self.height = ceil(manager.usedRect(for: container).height)
        self.attributedString = attributedString
        self.hasMarkdownDecorations = hasMarkdownDecorations
    }

    private static func plainAttributedString(
        from source: String
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        return NSAttributedString(
            string: source,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraph,
            ]
        )
    }
}

/// Thread-owned cache for completed and in-flight layouts, plus a
/// reuse pool of native views List has already displayed.
@MainActor final class ChatTextLayoutStore {
    private struct Key: Hashable, Sendable {
        let id: String
        let width: CGFloat
    }

    private struct Entry {
        let source: String
        let style: ChatTextLayoutStyle
        let layout: ChatTextLayout
    }

    private struct IdleTextView {
        let layout: ChatTextLayout
        let view: UITextView
    }

    /// Idle views a fast sweep can accumulate without bound; beyond the cap
    /// the oldest content-bearing views demote to blank spares. The cap must
    /// exceed UIKit's fastest prefetch window plus a viewport of returned
    /// views, or rows pre-attached ahead of a fling are evicted before they
    /// are realized and their text is typeset twice.
    private static let maximumIdleTextViews = 160
    private static let maximumSpareTextViews = 8

    private var entries: [Key: Entry] = [:]
    private var inFlightKeys: Set<Key> = []
    private var idleTextViews: [Key: IdleTextView] = [:]
    private var idleKeyOrder: [Key] = []
    private var spareTextViews: [UITextView] = []
    private var acceptsReturnedTextViews = true

    /// Layouts can outlive a navigation destination, but UIKit views
    /// should not. Deactivation also rejects views dismantled after the
    /// destination's `onDisappear` callback.
    func activateTextViewReuse() {
        acceptsReturnedTextViews = true
    }

    func deactivateTextViewReuse() {
        acceptsReturnedTextViews = false
        idleTextViews.removeAll()
        idleKeyOrder.removeAll()
        spareTextViews.removeAll()
    }

    func layout(
        id: String,
        source: String,
        style: ChatTextLayoutStyle,
        width: CGFloat
    ) -> ChatTextLayout {
        let key = Key(id: id, width: width)
        if let entry = entries[key],
            entry.source == source,
            entry.style == style
        {
            return entry.layout
        }

        // A visible row can beat background preparation, especially during the first
        // bounded mount. Build synchronously so the transcript never
        // flashes a placeholder or temporarily reports the wrong height.
        ChatBenchmarkAutoRun.trace(
            "layout miss id=\(id) width=\(width) cached=\(entries[key] != nil) bytes=\(source.utf8.count)"
        )
        #if DEBUG
            let layoutStart = CACurrentMediaTime()
        #endif
        let layout = ChatTextLayout(
            source: source,
            style: style,
            width: width
        )
        #if DEBUG
            ChatTextLayoutDiagnostics.synchronousLayoutMiss(
                id: id,
                style: style,
                byteCount: source.utf8.count,
                durationMilliseconds: (CACurrentMediaTime() - layoutStart) * 1_000
            )
        #endif
        entries[key] = Entry(source: source, style: style, layout: layout)
        return layout
    }

    /// Prepares rows before they enter the timeline whenever possible.
    /// Cancellation retains layouts that already finished.
    ///
    /// Returns only once every request is cached (or the task is cancelled).
    /// Requests claimed by a concurrent — possibly cancelled — preparation
    /// are not this call's to build, but they still must land before this
    /// call finishes, or a caller signals readiness while layouts are
    /// missing and those rows lay out synchronously on the main thread
    /// mid-scroll.
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
                    || entries[key]?.style != request.style
            }
            if remaining.isEmpty || Task.isCancelled { break }
            if pending.isEmpty {
                // Another preparation holds the claims; it releases them
                // when its worker settles, cancelled or not.
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
                    ChatTextLayout(
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
            inFlightKeys.remove(item.key)
            if entries[item.key]?.source != item.request.source
                || entries[item.key]?.style != item.request.style
            {
                entries[item.key] = Entry(
                    source: item.request.source,
                    style: item.request.style,
                    layout: layout
                )
            }
        }
        // Unbuilt claims must not block future preparation for these rows.
        for item in pending.dropFirst(layouts.count) {
            inFlightKeys.remove(item.key)
        }
    }

    /// Chats open and normally scroll from the bottom. Prepare the
    /// newest rows first so a large visible response does not wait
    /// behind older offscreen history. Sequential layout avoids a
    /// burst of competing TextKit work during interaction.
    private func claimPending(
        from requests: [ChatTextLayoutRequest]
    ) -> [(request: ChatTextLayoutRequest, key: Key)] {
        var pending: [(request: ChatTextLayoutRequest, key: Key)] = []
        var seen: Set<Key> = []
        for request in requests.reversed() {
            let key = Key(id: request.id, width: request.width)
            guard seen.insert(key).inserted,
                entries[key]?.source != request.source
                    || entries[key]?.style != request.style,
                !inFlightKeys.contains(key)
            else { continue }
            inFlightKeys.insert(key)
            pending.append((request, key))
        }
        return pending
    }

    // iOS renders these blocks in SwiftUI and does not prepare native layouts.
    func prepareResolvedProse(requests: [ChatResolvedProseLayoutRequest]) async {}
    func prepareCodeBlocks(requests: [ChatCodeLayoutRequest]) async {}
    func prepareTables(requests: [ChatTableLayoutRequest]) async {}

    /// Prefers the native view that already contains this exact layout.
    /// Otherwise recycles another idle view so fast traversal does not
    /// repeatedly allocate and configure selectable UITextViews.
    func takeTextView(
        for layout: ChatTextLayout,
        id: String
    ) -> (view: UITextView, hasExactContent: Bool)? {
        let key = Key(id: id, width: layout.width)
        if let idle = idleTextViews.removeValue(forKey: key) {
            idleKeyOrder.removeAll { $0 == key }
            return (idle.view, idle.layout === layout)
        }
        if let spare = spareTextViews.popLast() {
            return (spare, false)
        }
        guard let oldestKey = idleKeyOrder.first,
            let oldest = idleTextViews.removeValue(forKey: oldestKey)
        else { return nil }
        idleKeyOrder.removeFirst()
        return (oldest.view, false)
    }

    func returnTextView(
        _ textView: UITextView,
        for layout: ChatTextLayout,
        id: String
    ) {
        guard acceptsReturnedTextViews else { return }
        let key = Key(id: id, width: layout.width)
        if idleTextViews[key]?.view === textView
            || spareTextViews.contains(where: { $0 === textView })
        {
            return
        }
        let idle = IdleTextView(layout: layout, view: textView)
        if let replaced = idleTextViews.updateValue(idle, forKey: key) {
            stashSpare(replaced.view)
        } else {
            idleKeyOrder.append(key)
            if idleKeyOrder.count > Self.maximumIdleTextViews {
                let evictedKey = idleKeyOrder.removeFirst()
                if let evicted = idleTextViews.removeValue(forKey: evictedKey) {
                    stashSpare(evicted.view)
                }
            }
        }
    }

    /// Keeps a few recycled views ready for rows whose own content was never
    /// pooled; anything beyond that is released entirely.
    private func stashSpare(_ textView: UITextView) {
        guard spareTextViews.count < Self.maximumSpareTextViews else { return }
        textView.attributedText = nil
        spareTextViews.append(textView)
    }
}

/// Selectable prose whose attributed content and measured height can be
/// prepared before its `List` row becomes visible and whose native view
/// can be reused if List later realizes that row again.
///
/// The optional callback is the narrow extension point for selection-based
/// actions and annotations; normal rows pay no delegate-callback cost.
struct ChatSelectableText: UIViewRepresentable {
    @Environment(\.chatAnnotationContext) private var annotationContext

    let layoutID: String
    let source: String
    let style: ChatTextLayoutStyle
    let layoutStore: ChatTextLayoutStore
    var onSelectionChange: ((ChatTextSelection?) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ChatSelectableTextHostView {
        ChatSelectableTextHostView()
    }

    func updateUIView(_ uiView: ChatSelectableTextHostView, context: Context) {
        context.coordinator.layoutID = layoutID
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.annotationContext = annotationContext
        uiView.selectionDelegate =
            onSelectionChange == nil && annotationContext == nil
            ? nil
            : context.coordinator
        uiView.update(
            layoutID: layoutID,
            source: source,
            style: style,
            layoutStore: layoutStore
        )
    }

    static func dismantleUIView(
        _ uiView: ChatSelectableTextHostView,
        coordinator: Coordinator
    ) {
        uiView.dismantle()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var layoutID = ""
        var onSelectionChange: ((ChatTextSelection?) -> Void)?
        var annotationContext: ChatAnnotationContext?

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard let onSelectionChange else { return }
            let range = textView.selectedRange
            guard range.length > 0,
                NSMaxRange(range) <= textView.attributedText.length
            else {
                onSelectionChange(nil)
                return
            }
            onSelectionChange(
                ChatTextSelection(
                    layoutID: layoutID,
                    range: range,
                    text: textView.attributedText.attributedSubstring(
                        from: range
                    ).string
                )
            )
        }

        func textView(
            _ textView: UITextView,
            editMenuForTextInRanges ranges: [NSValue],
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard let annotationContext,
                let range = ranges.first?.rangeValue,
                let selection = selection(in: textView, range: range)
            else {
                return UIMenu(children: suggestedActions)
            }

            let comment = UIAction(
                title: "Comment…",
                image: UIImage(systemName: "text.bubble")
            ) { _ in
                annotationContext.model.beginComment(
                    quote: selection.text,
                    messageID: annotationContext.messageID,
                    role: annotationContext.role
                )
            }
            return UIMenu(children: suggestedActions + [comment])
        }

        private func selection(
            in textView: UITextView,
            range: NSRange
        ) -> ChatTextSelection? {
            guard range.length > 0,
                NSMaxRange(range) <= textView.attributedText.length
            else { return nil }
            return ChatTextSelection(
                layoutID: layoutID,
                range: range,
                text: textView.attributedText.attributedSubstring(
                    from: range
                ).string
            )
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: ChatSelectableTextHostView,
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
}

final class ChatSelectableTextHostView: UIView {
    private final class MarkdownDecorationView: UIView {
        var attributedText = NSAttributedString()
        weak var layoutManager: NSLayoutManager?
        weak var textContainer: NSTextContainer?

        override func draw(_ rect: CGRect) {
            guard let layoutManager, let textContainer,
                let context = UIGraphicsGetCurrentContext()
            else { return }
            var rangesByOffset: [CGFloat: [NSRange]] = [:]
            var index = 0
            while index < attributedText.length {
                var range = NSRange()
                let offsets =
                    attributedText.attribute(
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

            UIColor.secondaryLabel.withAlphaComponent(0.35).setFill()
            for (offset, ranges) in rangesByOffset {
                for range in ranges {
                    let glyphRange = layoutManager.glyphRange(
                        forCharacterRange: range,
                        actualCharacterRange: nil
                    )
                    let bounds = layoutManager.boundingRect(
                        forGlyphRange: glyphRange,
                        in: textContainer
                    )
                    guard bounds.intersects(rect) else { continue }

                    let bar = CGRect(
                        x: offset,
                        y: bounds.minY,
                        width: ChatMarkdownProseStyle.quoteBarWidth,
                        height: bounds.height
                    )
                    UIBezierPath(
                        roundedRect: bar,
                        cornerRadius: ChatMarkdownProseStyle.quoteBarWidth / 2
                    ).fill()
                }
            }

            context.setFillColor(UIColor.separator.cgColor)
            attributedText.enumerateAttribute(
                .chatThematicBreakIndent,
                in: NSRange(location: 0, length: attributedText.length)
            ) { value, range, _ in
                guard let indent = value as? CGFloat else { return }
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: range,
                    actualCharacterRange: nil
                )
                guard glyphRange.length > 0 else { return }
                let line = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphRange.location,
                    effectiveRange: nil
                )
                let rule = CGRect(
                    x: indent,
                    y: line.midY,
                    width: max(0, textContainer.size.width - indent),
                    height: 1
                )
                guard rule.intersects(rect) else { return }
                context.fill(rule)
            }
        }
    }

    weak var selectionDelegate: UITextViewDelegate? {
        didSet { textView?.delegate = selectionDelegate }
    }

    private var layoutID: String?
    private var source: String?
    private var style: ChatTextLayoutStyle?
    private weak var layoutStore: ChatTextLayoutStore?
    private var decorationView: MarkdownDecorationView?
    private var textView: UITextView?
    private var presentedLayout: ChatTextLayout?
    private var presentedLayoutID: String?

    func update(
        layoutID: String,
        source: String,
        style: ChatTextLayoutStyle,
        layoutStore: ChatTextLayoutStore
    ) {
        guard
            self.layoutID != layoutID || self.source != source
                || self.style != style || self.layoutStore !== layoutStore
        else { return }
        self.layoutID = layoutID
        self.source = source
        self.style = style
        self.layoutStore = layoutStore
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layoutID, let source, let style, let layoutStore,
            bounds.width > 0
        else { return }

        let layout = layoutStore.layout(
            id: layoutID,
            source: source,
            style: style,
            width: bounds.width
        )
        if presentedLayout !== layout {
            present(layout, source: source, style: style)
        }
        decorationView?.frame = bounds
        textView?.frame = bounds
    }

    func dismantle() {
        releasePresentedTextView()
        layoutID = nil
        source = nil
        style = nil
        layoutStore = nil
    }

    private func present(
        _ layout: ChatTextLayout,
        source: String,
        style: ChatTextLayoutStyle
    ) {
        #if DEBUG
            let attachmentStart = CACurrentMediaTime()
        #endif
        let preservedSelection =
            presentedLayoutID == layoutID
            ? textView?.selectedRange : nil
        releasePresentedTextView()

        let reuse = layoutStore?.takeTextView(
            for: layout,
            id: layoutID ?? "unknown"
        )

        let view = reuse?.view ?? Self.makeTextView(frame: bounds)
        if reuse?.hasExactContent == true {
            if view.frame != bounds {
                view.frame = bounds
            }
        } else {
            // A recycled view still contains another row's TextKit
            // storage. Clear it before resizing so UIKit does not lay out
            // the old, potentially large string at the new geometry.
            view.attributedText = nil
            if view.frame != bounds {
                view.frame = bounds
            }
            view.attributedText = layout.attributedString
        }
        let selection = preservedSelection
            ?? (reuse?.hasExactContent == true ? view.selectedRange : nil)
        view.selectedRange = selection.flatMap { selection in
            NSMaxRange(selection) <= layout.attributedString.length
                ? selection : nil
        } ?? NSRange(location: 0, length: 0)

        view.delegate = selectionDelegate
        if layout.hasMarkdownDecorations {
            let decorations = MarkdownDecorationView(frame: bounds)
            decorations.backgroundColor = .clear
            decorations.isUserInteractionEnabled = false
            decorations.attributedText = layout.attributedString
            decorations.layoutManager = view.layoutManager
            decorations.textContainer = view.textContainer
            addSubview(decorations)
            decorationView = decorations
        }
        addSubview(view)
        textView = view
        presentedLayout = layout
        presentedLayoutID = layoutID
        #if DEBUG
            ChatTextLayoutDiagnostics.slowAttachment(
                id: layoutID ?? "unknown",
                style: style,
                byteCount: source.utf8.count,
                durationMilliseconds: (CACurrentMediaTime() - attachmentStart) * 1_000,
                reusedTextView: reuse != nil
            )
        #endif
    }

    private func releasePresentedTextView() {
        guard let textView, let presentedLayout else { return }
        decorationView?.removeFromSuperview()
        decorationView = nil
        textView.delegate = nil
        textView.removeFromSuperview()
        if let layoutStore, let presentedLayoutID {
            layoutStore.returnTextView(
                textView,
                for: presentedLayout,
                id: presentedLayoutID
            )
        }
        self.textView = nil
        self.presentedLayout = nil
        self.presentedLayoutID = nil
    }

    private static func makeTextView(frame: CGRect) -> UITextView {
        let view = ChatSelectableTextViewConfiguration.makeTextView()
        view.frame = frame
        return view
    }
}

#endif
