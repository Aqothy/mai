#if os(macOS)
    import AppKit
    import QuartzCore
    import SwiftUI

    /// Native transcript viewport with stable row geometry and bounded view reuse.
    /// The parent prepares content before publishing a new set of rows.
    struct ChatNativeTranscript<Content: View>: NSViewRepresentable {
        let ids: [String]
        /// What each row shows; see `ChatVirtualTranscriptGeometry.sources`.
        var sourceIDs: [String] = []
        let width: CGFloat
        var isPrepared = true
        var measurementKeys: [ChatNativeRowMeasurementKey?] = []
        var presentationTheme: ChatCodeHighlightTheme? = nil
        /// The store the rows' prepared heights came from.
        var layoutStore: ObjectIdentifier? = nil
        var historyLoadDistance: CGFloat = 0
        var onGeometryChange: ((ChatScrollGeometry, ChatScrollGeometry) -> Void)? = nil
        var onAttach: ((ChatTranscriptScrollDocument) -> Void)? = nil
        var nativeRowHeight: ((Int, CGFloat) -> CGFloat?)? = nil
        var nativeRowFactory: ((Int, NSView?) -> NSView?)? = nil
        @ViewBuilder let content: (Int) -> Content

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> ChatMacTranscriptScrollView {
            let scroll = ChatMacTranscriptScrollView()
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            let document = context.coordinator.virtualDocument
            scroll.documentView = document
            document.observeViewport(of: scroll)
            return scroll
        }

        func updateNSView(_ scroll: ChatMacTranscriptScrollView, context: Context) {
            guard isPrepared else {
                context.coordinator.task?.cancel()
                #if DEBUG
                    ChatBenchmarkAutoRun.isNativeGeometryWarm = false
                #endif
                return
            }
            context.coordinator.virtualDocument.historyLoadDistance = historyLoadDistance
            context.coordinator.virtualDocument.geometryReporter.onChange = onGeometryChange
            context.coordinator.update(
                ids: ids, sourceIDs: sourceIDs, width: width, measurementKeys: measurementKeys,
                presentationTheme: presentationTheme, layoutStore: layoutStore,
                nativeRowHeight: nativeRowHeight,
                nativeRowFactory: nativeRowFactory,
                onAttach: onAttach, content: content)
        }

        static func dismantleNSView(_ scroll: ChatMacTranscriptScrollView, coordinator: Coordinator) {
            coordinator.task?.cancel()
            scroll.onTile = nil
            coordinator.virtualDocument.tearDown()
        }

        final class VirtualDocument: NSView, ChatMacScrollDocument {
            // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
            nonisolated deinit {}

            var numberOfRows: Int { geometry.ids.count }

            /// Sizes one SwiftUI row at a width. The hosting controller is
            /// shared by every row of an update and built on first use.
            func makeRowMeasurer() -> (Content, CGFloat) -> CGFloat {
                var controller: NSHostingController<Content>?
                return { rootView, width in
                    let measuring: NSHostingController<Content>
                    if let controller {
                        controller.rootView = rootView
                        measuring = controller
                    } else {
                        measuring = NSHostingController(rootView: rootView)
                        controller = measuring
                    }
                    return measuring.sizeThatFits(
                        in: CGSize(width: width, height: .greatestFiniteMagnitude)
                    ).height
                }
            }

            override var isFlipped: Bool { true }
            var geometry = ChatVirtualTranscriptGeometry()
            var offsets: [CGFloat] { geometry.offsets }
            var contentWidth: CGFloat = 0
            var historyLoadDistance: CGFloat = 0
            let geometryReporter = ChatScrollGeometryReporter()
            var isBottomFollowingEnabled: () -> Bool = { false }
            var initialBottomAlignmentCompletion: (() -> Void)?
            var isReaderScrolling = false
            /// The clip's size and insets when last seen, and where its
            /// origin was. A change to the first is layout, not the reader.
            private var lastViewport: Viewport?
            private var lastClipY: CGFloat = 0
            private(set) var rowRevisions = ChatTranscriptRowRevisions()
            var heightUpdateTask: Task<Void, Never>?
            var isApplyingHeights = false

            private struct Viewport: Equatable {
                let size: CGSize
                let topInset: CGFloat
                let bottomInset: CGFloat

                init(_ clip: NSClipView) {
                    size = clip.bounds.size
                    topInset = clip.contentInsets.top
                    bottomInset = clip.contentInsets.bottom
                }
            }

            func tearDown() {
                NotificationCenter.default.removeObserver(self)
                preparationTask?.cancel()
                heightUpdateTask?.cancel()
                geometryReporter.cancel()
                geometryReporter.onChange = nil
                initialBottomAlignmentCompletion = nil
            }
            var content: ((Int) -> Content)?
            var hosts: [Int: NSView] = [:]
            var nativeRowFactory: ((Int, NSView?) -> NSView?)?
            #if DEBUG
                var nativeMounts = 0
                var hostingMounts = 0
                var createdRows = 0
            #endif
            /// Unmounted rows by kind. One mixed pool hands a hosting view to
            /// a native row (and the reverse) about half the time, and the
            /// mismatched view is then thrown away.
            var reusableNative: [NSView] = []
            var reusableHosting: [NSView] = []
            private static var maximumPooledRows: Int { 32 }
            var preparationTask: Task<Void, Never>?
            var preparedRange: ClosedRange<Int>?
            /// The rows last tiled and the width they were tiled at. Most
            /// scrolled frames stay inside the same rows and need no work.
            private var tiledViewport: TiledViewport?

            private struct TiledViewport: Equatable {
                let resident: ClosedRange<Int>
                let visible: ClosedRange<Int>
                let width: CGFloat
            }

            func install(
                heights: [CGFloat], width: CGFloat, ids: [String] = [], sourceIDs: [String] = [],
                changedIDs: Set<String>? = nil, heightInvalidatedIDs: Set<String>? = nil,
                content: @escaping (Int) -> Content
            ) {
                // Content, row frames, document extent and scroll compensation
                // belong to one render transaction. Never yield between them.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                isApplyingHeights = true
                defer {
                    isApplyingHeights = false
                    viewportChanged()
                    CATransaction.commit()
                }
                preparationTask?.cancel()
                preparedRange = nil
                tiledViewport = nil
                self.content = content
                contentWidth = width
                let ids = ids.isEmpty ? heights.indices.map(String.init) : ids
                let oldIDs = geometry.ids
                updateGeometry {
                    let rowsChanged = geometry.replace(
                        ids: ids, sources: sourceIDs, estimatedHeight: 1)
                    geometry.setHeights(heights)
                    rowRevisions.install(
                        invalidatedIDs: heightInvalidatedIDs ?? changedIDs ?? Set(ids),
                        rowsChanged: rowsChanged, in: geometry)
                    hosts = ChatTranscriptMountedRows.retained(
                        hosts, oldIDs: oldIDs, in: geometry, changedIDs: changedIDs,
                        configure: { configuredHost($0, current: $1, content: content) },
                        recycle: recycle, show: { addSubview($0) })
                    subviews = hosts.keys.sorted().compactMap { hosts[$0] }
                }
                alignInitialBottomIfPossible()
            }

            func row(at y: CGFloat) -> Int { geometry.index(at: y) ?? -1 }

            func noteHeight(_ height: CGFloat, id: String, revision: Int) {
                guard rowRevisions.accepts(height, id: id, revision: revision, in: geometry)
                else { return }
                // Commit geometry before this layout can paint. Deferring these
                // frames leaves the working row over newly expanded content.
                let wasApplyingHeights = isApplyingHeights
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                isApplyingHeights = true
                updateGeometry { geometry.updateHeights([id: height]) }
                isApplyingHeights = wasApplyingHeights
                CATransaction.commit()
                // Mounting newly exposed rows may re-enter SwiftUI layout, so
                // keep that work coalesced outside the height-report callback.
                guard heightUpdateTask == nil else { return }
                heightUpdateTask = Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self, !Task.isCancelled else { return }
                    self.heightUpdateTask = nil
                    self.viewportChanged()
                }
            }

            // MARK: Reading position

            var viewportTop: CGFloat? {
                enclosingScrollView.map {
                    $0.contentView.bounds.minY + $0.contentView.contentInsets.top
                }
            }

            var bottomViewportTop: CGFloat? {
                guard numberOfRows > 0, let clip = enclosingScrollView?.contentView,
                    clip.bounds.height > 0
                else { return nil }
                return ChatScrollGeometry.bottomOffset(
                    contentHeight: geometry.totalHeight, viewportHeight: clip.bounds.height,
                    topInset: clip.contentInsets.top, bottomInset: clip.contentInsets.bottom)
                    + clip.contentInsets.top
            }

            func setViewportTop(_ top: CGFloat) {
                guard let scroll = enclosingScrollView else { return }
                moveClip(toY: top - scroll.contentView.contentInsets.top, in: scroll)
            }

            func applyGeometryToViews() {
                repositionMountedRows()
                setFrameSize(
                    NSSize(
                        width: enclosingScrollView?.contentSize.width ?? contentWidth,
                        height: geometry.totalHeight))
            }

            /// Moves the clip, kept inside the document, and records the move
            /// as the reader's position before the clip reports it.
            private func moveClip(toY y: CGFloat, in scroll: NSScrollView) {
                let clip = scroll.contentView
                var proposed = clip.bounds
                proposed.origin.y = y
                let origin = clip.constrainBoundsRect(proposed).origin
                lastViewport = Viewport(clip)
                lastClipY = origin.y
                guard origin != clip.bounds.origin else { return }
                clip.scroll(to: origin)
                scroll.reflectScrolledClipView(clip)
            }

            var isNearBottom: Bool {
                guard numberOfRows > 0, let clip = enclosingScrollView?.contentView else {
                    return false
                }
                return bounds.maxY + clip.contentInsets.bottom - clip.documentVisibleRect.maxY
                    <= ChatTimelineMetrics.nearBottomDistance
            }

            /// A resize or an inset change moves the clip without the reader:
            /// AppKit keeps its origin or constrains it to the new extent.
            /// While following, the viewport lands on the new end; otherwise
            /// the clip stays where the reader left it.
            private func keepReadingPositionThroughViewportChange(_ scroll: NSScrollView) {
                let clip = scroll.contentView
                let viewport = Viewport(clip)
                guard let lastViewport, lastViewport != viewport else {
                    self.lastViewport = viewport
                    lastClipY = clip.bounds.minY
                    return
                }
                if isFollowingBottom {
                    scrollToBottom()
                } else if !isReaderScrolling {
                    moveClip(toY: lastClipY, in: scroll)
                } else {
                    self.lastViewport = viewport
                    lastClipY = clip.bounds.minY
                }
            }

            /// Geometry changes move every resident row, including prepared neighbors.
            /// Otherwise a growing reply can overlap an already-mounted working row.
            private func repositionMountedRows() {
                let width = enclosingScrollView?.contentSize.width ?? contentWidth
                for (index, host) in hosts {
                    let frame = NSRect(
                        x: 0, y: offsets[index], width: width, height: geometry.heights[index])
                    if host.frame != frame {
                        host.frame = frame
                    }
                }
            }

            private func notifyGeometryChange() {
                guard let clip = enclosingScrollView?.contentView else { return }
                geometryReporter.report(
                    ChatScrollGeometry(
                        isNearTop: numberOfRows > 0
                            && clip.documentVisibleRect.minY + clip.contentInsets.top
                                <= historyLoadDistance,
                        isNearBottom: isNearBottom,
                        containerWidth: clip.bounds.width.rounded(),
                        containerHeight: clip.bounds.height.rounded(),
                        bottomInset: clip.contentInsets.bottom.rounded(),
                        contentHeight: bounds.height.rounded()))
            }

            /// The transcript scrolls vertically only. Sidebar, divider and window
            /// changes resize the clip without a new install, so keep the document
            /// and every resident row as wide as the clip, and drop a horizontal
            /// offset that a previously wider document allowed.
            private func matchViewportWidth(_ scroll: NSScrollView) {
                let width = scroll.contentSize.width
                if frame.width != width {
                    setFrameSize(NSSize(width: width, height: frame.height))
                    repositionMountedRows()
                }
                let clip = scroll.contentView
                if clip.bounds.origin.x != 0 {
                    clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y))
                    scroll.reflectScrolledClipView(clip)
                }
            }

            /// Scrolling moves the clip's bounds, which changes the mounted rows.
            /// Sidebar, divider and window changes and new insets re-tile the
            /// scroll view, which can leave the clip's bounds origin unchanged;
            /// rows and the reading position must still follow.
            func observeViewport(of scroll: ChatMacTranscriptScrollView) {
                let clip = scroll.contentView
                clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self, selector: #selector(viewportChanged),
                    name: NSView.boundsDidChangeNotification, object: clip)
                scroll.onTile = { [weak self] in self?.viewportChanged() }
            }

            @objc func viewportChanged() {
                guard !isApplyingHeights, let scroll = enclosingScrollView else { return }
                matchViewportWidth(scroll)
                keepReadingPositionThroughViewportChange(scroll)
                // The first install can come before the viewport has a size.
                alignInitialBottomIfPossible()
                notifyGeometryChange()
                let visible = scroll.contentView.documentVisibleRect
                guard let content,
                    let tiling = geometry.tiling(top: visible.minY, bottom: visible.maxY)
                else { return }
                let (visibleFirst, visibleLast) = (tiling.visible.lowerBound, tiling.visible.upperBound)
                let viewport = TiledViewport(
                    resident: tiling.resident, visible: tiling.visible, width: visible.width)
                guard viewport != tiledViewport else { return }
                tiledViewport = viewport
                for index in hosts.keys where !tiling.resident.contains(index) {
                    if let host = hosts.removeValue(forKey: index) {
                        recycle(host)
                    }
                }
                for index in tiling.visible {
                    mount(index, width: visible.width, content: content)
                }
                let range = tiling.resident
                guard range != preparedRange else { return }
                preparedRange = range
                preparationTask?.cancel()
                preparationTask = Task(priority: .utility) { @MainActor [weak self] in
                    let nearby = range.sorted {
                        min(abs($0 - visibleFirst), abs($0 - visibleLast))
                            < min(abs($1 - visibleFirst), abs($1 - visibleLast))
                    }
                    for index in nearby {
                        guard !Task.isCancelled, let self else { return }
                        guard self.hosts[index] == nil else { continue }
                        self.mount(index, width: visible.width, content: content)
                        await Task.yield()
                    }
                }
            }

            /// Takes a row out of the document into the pool of its kind.
            private func recycle(_ host: NSView) {
                host.removeFromSuperview()
                if host is NSHostingView<ChatMeasuredTranscriptRow<Content>> {
                    if reusableHosting.count < Self.maximumPooledRows { reusableHosting.append(host) }
                } else if reusableNative.count < Self.maximumPooledRows {
                    reusableNative.append(host)
                }
            }

            private func configuredHost(
                _ index: Int, current: NSView? = nil, content: (Int) -> Content
            ) -> NSView {
                ChatTranscriptMountedRows.configuredHost(
                    index, current: current,
                    isHosting: { $0 is NSHostingView<ChatMeasuredTranscriptRow<Content>> },
                    nativePool: &reusableNative, hostingPool: &reusableHosting,
                    nativeRow: { index, candidate in
                        let native = nativeRowFactory?(index, candidate)
                        #if DEBUG
                            if let native {
                                nativeMounts += 1
                                if native !== candidate { createdRows += 1 }
                            }
                        #endif
                        return native
                    },
                    hostingRow: { hostingView($0, reused: $1, content: content) })
            }

            private func hostingView(_ index: Int, reused: NSView?, content: (Int) -> Content)
                -> NSView
            {
                #if DEBUG
                    if reused == nil { createdRows += 1 }
                #endif
                let id = geometry.ids[index]
                let revision = rowRevisions[id] ?? 0
                let measured = ChatMeasuredTranscriptRow(id: id, content: content(index)) {
                    [weak self] height in
                    self?.noteHeight(height, id: id, revision: revision)
                }
                let hosting =
                    reused as? NSHostingView<ChatMeasuredTranscriptRow<Content>>
                    ?? NSHostingView(rootView: measured)
                hosting.sizingOptions = []
                hosting.rootView = measured
                #if DEBUG
                    hostingMounts += 1
                #endif
                return hosting
            }

            private func mount(_ index: Int, width: CGFloat, content: (Int) -> Content) {
                let host: NSView
                if let existing = hosts[index] {
                    host = existing
                } else {
                    host = configuredHost(index, content: content)
                    let next = hosts.keys.filter { $0 > index }.min().flatMap { hosts[$0] }
                    hosts[index] = host
                    addSubview(host, positioned: next == nil ? .above : .below, relativeTo: next)
                }
                host.frame = NSRect(
                    x: 0, y: offsets[index], width: width,
                    height: offsets[index + 1] - offsets[index])
                // Offscreen preparation must perform display layout now; mounting
                // an unlaid-out hosting view only postpones the work until exposure.
                host.layoutSubtreeIfNeeded()
            }
        }

    }
#endif
