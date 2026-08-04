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
                duplicatedLayout: Bool,
                reusedTextView: Bool
            ) {
                guard durationMilliseconds >= 8 || duplicatedLayout else { return }
                let styleName = String(describing: style)
                logger.notice(
                    "slow attach id=\(id, privacy: .public) style=\(styleName, privacy: .public) bytes=\(byteCount) ms=\(durationMilliseconds) duplicate=\(duplicatedLayout) reused=\(reusedTextView)"
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

    /// A complete TextKit 1 stack for one prose segment at one width.
    ///
    /// It is created and fully laid out on a detached task. Once created, a
    /// `UITextView` adopts its text container and uses the already calculated
    /// line wrapping, glyph positions, selection geometry, and height.
    /// TextKit 1 is intentional here: UIKit can attach this prepared stack to
    /// a selectable text view directly. TextKit 2's viewport layout is most
    /// useful when that text view owns scrolling; the outer chat `List` does.
    nonisolated final class ChatTextLayout: @unchecked Sendable {
        let width: CGFloat
        let height: CGFloat
        let textContainer: NSTextContainer

        @MainActor var isAttached = false

        private let textStorage: NSTextStorage
        private let layoutManager: NSLayoutManager

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
            self.textStorage = storage
            self.layoutManager = manager
            self.textContainer = container
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

    /// Per-timeline cache for completed layouts, in-flight warmups, and a
    /// small reuse pool of the native views List has already displayed.
    @MainActor
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
            var idleTextView: UITextView?
        }

        private var entries: [Key: Entry] = [:]
        private var entryOrder: [Key] = []
        private var warming: Set<Key> = []
        private var idleTextViewKeys: [Key] = []

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

            // A newly visible row can beat its warmup. Build synchronously in
            // that uncommon case so the transcript never flashes a placeholder.
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
            var pending: [(request: ChatTextLayoutRequest, key: Key)] = []
            var seen: Set<Key> = []
            // Chats open and normally scroll from the bottom. Prepare the
            // newest rows first so a large visible response does not wait
            // behind older offscreen history. Sequential layout avoids a
            // burst of competing TextKit work during interaction.
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
                idleTextViewKeys.removeAll { $0 == oldestKey }
            }
            if entries[key]?.layout !== layout {
                idleTextViewKeys.removeAll { $0 == key }
            }
            entries[key] = Entry(
                source: source,
                style: style,
                layout: layout,
                idleTextView: nil
            )
            if isNewEntry {
                entryOrder.append(key)
            }
        }

        /// Returns the native view previously used to display this exact
        /// layout. Keeping a small per-timeline reuse pool avoids repeating
        /// UITextView's TextKit geometry setup as List rows are recycled.
        func takeTextView(
            for layout: ChatTextLayout,
            id: String
        ) -> UITextView? {
            let key = Key(id: id, width: layout.width)
            guard var entry = entries[key], entry.layout === layout,
                let textView = entry.idleTextView
            else { return nil }

            entry.idleTextView = nil
            entries[key] = entry
            idleTextViewKeys.removeAll { $0 == key }
            return textView
        }

        func returnTextView(
            _ textView: UITextView,
            for layout: ChatTextLayout,
            id: String
        ) {
            let key = Key(id: id, width: layout.width)
            guard var entry = entries[key], entry.layout === layout,
                entry.idleTextView == nil
            else { return }

            if idleTextViewKeys.count >= Self.maximumIdleTextViewCount,
                let oldestKey = idleTextViewKeys.first
            {
                idleTextViewKeys.removeFirst()
                if var oldestEntry = entries[oldestKey] {
                    oldestEntry.idleTextView = nil
                    entries[oldestKey] = oldestEntry
                }
            }
            entry.idleTextView = textView
            entries[key] = entry
            idleTextViewKeys.append(key)
        }
    }

    /// Selectable prose whose expensive parsing and glyph layout can be
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

            let reusedView = layoutStore?.takeTextView(
                for: layout,
                id: layoutID ?? "unknown"
            )

            // A TextKit 1 container can drive only one live text view. A
            // duplicate host is unusual, but keeping this fallback makes the
            // cache safe for previews and tests as well as the timeline.
            let duplicatedLayout = layout.isAttached
            let adopted =
                if duplicatedLayout {
                    ChatTextLayout(
                        source: source,
                        style: style,
                        width: layout.width
                    )
                } else {
                    layout
                }
            adopted.isAttached = true

            let view = reusedView ?? Self.makeTextView(for: adopted, frame: bounds)
            if view.frame != bounds {
                view.frame = bounds
            }

            addSubview(view)
            textView = view
            presentedLayout = adopted
            presentedLayoutID = layoutID
            #if DEBUG
                ChatTextLayoutDiagnostics.slowAttachment(
                    id: layoutID ?? "unknown",
                    style: style,
                    byteCount: source.utf8.count,
                    durationMilliseconds: (CACurrentMediaTime() - attachmentStart) * 1_000,
                    duplicatedLayout: duplicatedLayout,
                    reusedTextView: reusedView != nil
                )
            #endif
        }

        private func releasePresentedTextView() {
            guard let textView, let presentedLayout else { return }
            textView.removeFromSuperview()
            presentedLayout.isAttached = false
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

        private static func makeTextView(
            for layout: ChatTextLayout,
            frame: CGRect
        ) -> UITextView {
            let view = UITextView(
                frame: frame,
                textContainer: layout.textContainer
            )
            view.isEditable = false
            view.isSelectable = true
            view.isScrollEnabled = false
            view.backgroundColor = .clear
            view.textContainerInset = .zero
            view.contentInset = .zero
            view.adjustsFontForContentSizeCategory = false
            return view
        }
    }
#endif
