#if os(iOS)
    import SwiftUI
    import UIKit
    #if DEBUG
        import OSLog
    #endif

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

    #if DEBUG
        /// DEBUG-only breadcrumbs for correlating a visible hitch with the
        /// row that appeared, a missed warmup, or expensive native attachment.
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

            self.width = width
            self.height = ceil(manager.usedRect(for: container).height)
            self.attributedString = attributedString
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

    /// Cache for completed layouts, in-flight warmups, and a small reuse pool
    /// of the native views List has already displayed.
    final class ChatTextLayoutStore {
        /// Bounds both retained layouts and eager warmup work. Callers use the
        /// same limit so they do not prepare requests the cache cannot retain.
        static let capacity = 256
        private static let maximumIdleTextViewCount = 16

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
            let key: Key
            let layout: ChatTextLayout
            let view: UITextView
        }

        private var entries: [Key: Entry] = [:]
        private var entryOrder: [Key] = []
        private var warming: Set<Key> = []
        private var idleTextViews: [IdleTextView] = []
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

            // A visible row can beat its warmup, especially during the first
            // bounded mount. Build synchronously so the transcript never
            // flashes a placeholder or temporarily reports the wrong height.
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
            insert(layout, source: source, style: style, for: key)
            return layout
        }

        func warm(requests: [ChatTextLayoutRequest]) {
            let pending = claimPending(from: requests)
            guard !pending.isEmpty else { return }

            Task.detached(priority: .userInitiated) { [self] in
                for item in pending {
                    let layout = ChatTextLayout(
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

        /// Awaitable warmup for the rows needed before a cold-open reveal.
        /// Cancellation retains layouts that already finished.
        func prepare(requests: [ChatTextLayoutRequest]) async {
            let pending = claimPending(from: requests)
            guard !pending.isEmpty else { return }

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
                finishWarmup(
                    layout,
                    source: item.request.source,
                    style: item.request.style,
                    key: item.key
                )
            }
            // Unbuilt claims must not block future warmups for these rows.
            for item in pending.dropFirst(layouts.count) {
                warming.remove(item.key)
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
            for request in requests.suffix(Self.capacity).reversed()
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
            _ layout: ChatTextLayout,
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
            _ layout: ChatTextLayout,
            source: String,
            style: ChatTextLayoutStyle,
            for key: Key
        ) {
            let isNewEntry = entries[key] == nil
            if entries.count >= Self.capacity, isNewEntry,
                let oldestKey = entryOrder.first
            {
                entryOrder.removeFirst()
                entries.removeValue(forKey: oldestKey)
            }
            entries[key] = Entry(
                source: source,
                style: style,
                layout: layout
            )
            if isNewEntry {
                entryOrder.append(key)
            }
        }

        /// Prefers the native view that already contains this exact layout.
        /// Otherwise recycles another idle view so fast traversal does not
        /// repeatedly allocate and configure selectable UITextViews.
        func takeTextView(
            for layout: ChatTextLayout,
            id: String
        ) -> (view: UITextView, hasExactContent: Bool)? {
            let key = Key(id: id, width: layout.width)
            if let exactIndex = idleTextViews.lastIndex(where: {
                $0.key == key && $0.layout === layout
            }) {
                return (idleTextViews.remove(at: exactIndex).view, true)
            }
            guard let reusable = idleTextViews.popLast() else { return nil }
            return (reusable.view, false)
        }

        func returnTextView(
            _ textView: UITextView,
            for layout: ChatTextLayout,
            id: String
        ) {
            guard acceptsReturnedTextViews,
                !idleTextViews.contains(where: { $0.view === textView })
            else { return }
            if idleTextViews.count >= Self.maximumIdleTextViewCount {
                idleTextViews.removeFirst()
            }
            idleTextViews.append(
                IdleTextView(
                    key: Key(id: id, width: layout.width),
                    layout: layout,
                    view: textView
                )
            )
        }
    }

    /// Selectable prose whose attributed content and measured height can be
    /// prepared before its `List` row becomes visible and whose native view
    /// can be reused if List later realizes that row again.
    struct ChatSelectableText: UIViewRepresentable {
        let layoutID: String
        let source: String
        let style: ChatTextLayoutStyle
        let layoutStore: ChatTextLayoutStore

        func makeUIView(context: Context) -> ChatSelectableTextHostView {
            ChatSelectableTextHostView()
        }

        func updateUIView(_ uiView: ChatSelectableTextHostView, context: Context) {
            uiView.update(
                layoutID: layoutID,
                source: source,
                style: style,
                layoutStore: layoutStore
            )
        }

        static func dismantleUIView(
            _ uiView: ChatSelectableTextHostView,
            coordinator: Void
        ) {
            uiView.dismantle()
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
        private var layoutID: String?
        private var source: String?
        private var style: ChatTextLayoutStyle?
        private weak var layoutStore: ChatTextLayoutStore?
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
                view.selectedRange = NSRange(location: 0, length: 0)
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
            let view = UITextView(usingTextLayoutManager: false)
            view.isScrollEnabled = false
            view.isEditable = false
            view.isSelectable = true
            view.backgroundColor = .clear
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
            view.contentInset = .zero
            view.adjustsFontForContentSizeCategory = false
            view.frame = frame
            return view
        }
    }
#endif
