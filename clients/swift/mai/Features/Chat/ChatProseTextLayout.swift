import Foundation

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// A fully laid-out TextKit 1 stack for one prose segment at one width.
///
/// The whole stack is built and laid out on whatever thread creates it —
/// that's the entire point: the layout store builds these on a background
/// task so scrolling never pays glyph layout on the main thread. After
/// creation the stack must only be touched on the main thread, where a text
/// view adopts `textContainer` and draws the already-computed layout.
nonisolated final class ChatProseTextLayout: @unchecked Sendable {
    let width: CGFloat
    let height: CGFloat
    let textContainer: NSTextContainer

    /// Main-thread bookkeeping: a TextKit 1 container can back only one text
    /// view at a time. Guarded by main-actor usage, not locks.
    nonisolated(unsafe) var isAttached = false

    private let textStorage: NSTextStorage
    private let layoutManager: NSLayoutManager

    init(source: String, width: CGFloat) {
        let rendered = ChatProseMarkdownRenderer.attributedString(from: source)
        let storage = NSTextStorage(attributedString: rendered)
        let manager = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        // The adopting text view must never resize this container: width
        // tracking would shrink it against the view's default insets on
        // attach and re-run the entire layout on the main thread.
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
}

/// Pre-laid-out prose keyed by (source, width). `warm` runs layout off the
/// main thread ahead of scrolling — the SwiftUI equivalent of a virtualized
/// list's draw distance; `layout` is the synchronous fallback when a row
/// realizes before its warm finishes (one bounded hitch instead of a blank).
@MainActor
final class ChatProseLayoutStore {
    static let shared = ChatProseLayoutStore()

    /// Generous for one thread's realized prose; beyond it, oldest entries
    /// re-warm on demand.
    private static let maximumEntryCount = 96

    private struct Key: Hashable {
        let source: String
        let width: CGFloat
    }

    private var layouts: [Key: ChatProseTextLayout] = [:]
    private var recentKeys: [Key] = []
    private var warmingKeys: Set<Key> = []

    init() {
        #if canImport(UIKit)
            // Prose is laid out with fonts resolved at build time, so a
            // Dynamic Type change invalidates every cached layout.
            NotificationCenter.default.addObserver(
                forName: UIContentSizeCategory.didChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    ChatProseLayoutStore.shared.removeAll()
                }
            }
        #endif
    }

    func layout(source: String, width: CGFloat) -> ChatProseTextLayout {
        let key = Key(source: source, width: width)
        if let cached = layouts[key] {
            touch(key)
            return cached
        }
        let built = ChatProseTextLayout(source: source, width: width)
        insert(built, for: key)
        return built
    }

    func warm(sources: [String], width: CGFloat) {
        guard width > 0 else { return }
        let pending = sources.filter { source in
            let key = Key(source: source, width: width)
            return layouts[key] == nil && !warmingKeys.contains(key)
        }
        guard !pending.isEmpty else { return }
        for source in pending {
            warmingKeys.insert(Key(source: source, width: width))
        }

        Task.detached(priority: .userInitiated) {
            for source in pending {
                let layout = ChatProseTextLayout(source: source, width: width)
                await ChatProseLayoutStore.shared.finishWarming(
                    layout,
                    source: source,
                    width: width
                )
            }
        }
    }

    private func finishWarming(
        _ layout: ChatProseTextLayout,
        source: String,
        width: CGFloat
    ) {
        let key = Key(source: source, width: width)
        warmingKeys.remove(key)
        guard layouts[key] == nil else { return }
        insert(layout, for: key)
    }

    private func insert(_ layout: ChatProseTextLayout, for key: Key) {
        layouts[key] = layout
        touch(key)
        while recentKeys.count > Self.maximumEntryCount {
            layouts.removeValue(forKey: recentKeys.removeFirst())
        }
    }

    private func touch(_ key: Key) {
        if let index = recentKeys.firstIndex(of: key) {
            recentKeys.remove(at: index)
        }
        recentKeys.append(key)
    }

    private func removeAll() {
        layouts.removeAll()
        recentKeys.removeAll()
        warmingKeys.removeAll()
    }
}
