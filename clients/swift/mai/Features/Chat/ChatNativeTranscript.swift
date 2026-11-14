#if os(macOS)
    import AppKit
    import QuartzCore
    import SwiftUI

    /// Native transcript viewport with stable row geometry and bounded view reuse.
    /// The parent prepares content before publishing a new set of rows.
    struct ChatNativeTranscript<Content: View>: NSViewRepresentable {
        let ids: [String]
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

        func makeNSView(context: Context) -> NSScrollView {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            let document = context.coordinator.virtualDocument
            scroll.documentView = document
            document.observeViewport(of: scroll)
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            guard isPrepared else {
                context.coordinator.task?.cancel()
                #if DEBUG
                    ChatBenchmarkAutoRun.isNativeGeometryWarm = false
                #endif
                return
            }
            context.coordinator.virtualDocument.historyLoadDistance = historyLoadDistance
            context.coordinator.virtualDocument.onGeometryChange = onGeometryChange
            context.coordinator.update(
                ids: ids, width: width, measurementKeys: measurementKeys,
                presentationTheme: presentationTheme, layoutStore: layoutStore,
                nativeRowHeight: nativeRowHeight,
                nativeRowFactory: nativeRowFactory,
                onAttach: onAttach, content: content)
        }

        static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
            coordinator.task?.cancel()
            NotificationCenter.default.removeObserver(coordinator.virtualDocument)
            coordinator.virtualDocument.preparationTask?.cancel()
            coordinator.virtualDocument.heightUpdateTask?.cancel()
            coordinator.virtualDocument.geometryNotificationTask?.cancel()
            coordinator.virtualDocument.setGeometryCommitHandler(nil)
        }

        final class VirtualDocument: NSView, ChatMacScrollDocument {
            // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
            nonisolated deinit {}

            var numberOfRows: Int { offsets.count - 1 }
            func stableIdentity(forRow row: Int) -> String? {
                geometry.ids.indices.contains(row) ? geometry.ids[row] : nil
            }
            func row(forStableIdentity id: String) -> Int? { geometry.index(for: id) }
            func rect(ofRow index: Int) -> NSRect {
                guard index >= 0, index < numberOfRows else { return .zero }
                return NSRect(
                    x: 0, y: offsets[index], width: bounds.width,
                    height: offsets[index + 1] - offsets[index])
            }
            func rows(in rect: NSRect) -> NSRange {
                guard numberOfRows > 0, rect.maxY > 0, rect.minY < bounds.height else {
                    return NSRange(location: NSNotFound, length: 0)
                }
                let first = row(at: max(0, rect.minY))
                let last = row(at: min(bounds.height, rect.maxY).nextDown)
                return NSRange(location: first, length: max(0, last - first + 1))
            }

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
            var onGeometryChange: ((ChatScrollGeometry, ChatScrollGeometry) -> Void)?
            private var lastReportedGeometry: ChatScrollGeometry?
            private var pendingGeometry: ChatScrollGeometry?
            var geometryNotificationTask: Task<Void, Never>?
            var rowRevisions: [String: Int] = [:]
            private var nextRowRevision = 0
            var heightUpdateTask: Task<Void, Never>?
            var isApplyingHeights = false
            private var geometryCommitHandler: (() -> Void)?

            func setGeometryCommitHandler(_ handler: (() -> Void)?) {
                geometryCommitHandler = handler
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
                heights: [CGFloat], width: CGFloat, ids: [String] = [],
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
                if geometry.replace(ids: ids, estimatedHeight: 1) {
                    rowRevisions = rowRevisions.filter { geometry.index(for: $0.key) != nil }
                }
                geometry.setHeights(heights)
                // An unchanged live row keeps its reporting identity across parent
                // updates; otherwise a queued height can be discarded permanently.
                for id in heightInvalidatedIDs ?? changedIDs ?? Set(ids) {
                    nextRowRevision += 1
                    rowRevisions[id] = nextRowRevision
                }
                var retained: [Int: NSView] = [:]
                for (oldIndex, host) in hosts {
                    let id = oldIDs[oldIndex]
                    if let index = geometry.index(for: id) {
                        let updated =
                            changedIDs?.contains(id) == false
                            ? host : configuredHost(index, reused: host, content: content)
                        if updated !== host {
                            host.removeFromSuperview()
                            recycle(host)
                            addSubview(updated)
                        }
                        retained[index] = updated
                    } else {
                        host.removeFromSuperview()
                        recycle(host)
                    }
                }
                hosts = retained
                subviews = hosts.keys.sorted().compactMap { hosts[$0] }
                repositionMountedRows()
                setFrameSize(
                    NSSize(
                        width: enclosingScrollView?.contentSize.width ?? width,
                        height: geometry.totalHeight))
                geometryCommitHandler?()
            }

            func row(at y: CGFloat) -> Int { geometry.index(at: y) ?? -1 }

            func noteHeight(_ height: CGFloat, id: String, revision: Int) {
                guard height.isFinite, height > 0, rowRevisions[id, default: 0] == revision,
                    let index = geometry.index(for: id), geometry.heights[index] != height
                else { return }
                // Commit geometry before this layout can paint. Deferring these
                // frames leaves the working row over newly expanded content.
                let wasApplyingHeights = isApplyingHeights
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                isApplyingHeights = true
                geometry.updateHeights([id: height])
                repositionMountedRows()
                setFrameSize(NSSize(width: frame.width, height: geometry.totalHeight))
                geometryCommitHandler?()
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
                guard onGeometryChange != nil, let scroll = enclosingScrollView else { return }
                let clip = scroll.contentView
                let visible = clip.documentVisibleRect
                let geometry = ChatScrollGeometry(
                    isNearTop: numberOfRows > 0
                        && visible.minY + clip.contentInsets.top <= historyLoadDistance,
                    isNearBottom: numberOfRows > 0
                        && bounds.maxY + clip.contentInsets.bottom - visible.maxY
                            <= ChatTimelineMetrics.nearBottomDistance,
                    containerWidth: clip.bounds.width.rounded(),
                    containerHeight: clip.bounds.height.rounded(),
                    bottomInset: clip.contentInsets.bottom.rounded(),
                    contentHeight: bounds.height.rounded())
                guard geometry != (pendingGeometry ?? lastReportedGeometry) else { return }
                pendingGeometry = geometry
                guard geometryNotificationTask == nil else { return }
                geometryNotificationTask = Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self, !Task.isCancelled else { return }
                    self.geometryNotificationTask = nil
                    guard let geometry = self.pendingGeometry else { return }
                    self.pendingGeometry = nil
                    guard geometry != self.lastReportedGeometry else { return }
                    let previous = self.lastReportedGeometry ?? geometry
                    self.lastReportedGeometry = geometry
                    self.onGeometryChange?(previous, geometry)
                }
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
            /// Sidebar, divider and window changes resize the clip's frame, which
            /// can leave its bounds origin unchanged; rows must still match it.
            func observeViewport(of scroll: NSScrollView) {
                let clip = scroll.contentView
                clip.postsBoundsChangedNotifications = true
                clip.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self, selector: #selector(viewportChanged),
                    name: NSView.boundsDidChangeNotification, object: clip)
                NotificationCenter.default.addObserver(
                    self, selector: #selector(viewportResized),
                    name: NSView.frameDidChangeNotification, object: clip)
            }

            @objc private func viewportResized() {
                guard !isApplyingHeights, let scroll = enclosingScrollView else { return }
                matchViewportWidth(scroll)
            }

            @objc func viewportChanged() {
                notifyGeometryChange()
                guard !isApplyingHeights, let content, offsets.count > 1,
                    let scroll = enclosingScrollView
                else { return }
                matchViewportWidth(scroll)
                let visible = scroll.contentView.documentVisibleRect
                // One viewport of preparation on either side bounds resident views
                // while allowing ordinary wheel input to reuse already mounted rows.
                let first = max(0, row(at: max(0, visible.minY - visible.height)))
                let last = row(at: min(frame.height, visible.maxY + visible.height))
                let visibleFirst = max(first, row(at: visible.minY))
                let visibleLast = min(last, row(at: visible.maxY))
                guard first <= last, visibleFirst <= visibleLast else { return }
                let viewport = TiledViewport(
                    resident: first...last, visible: visibleFirst...visibleLast,
                    width: visible.width)
                guard viewport != tiledViewport else { return }
                tiledViewport = viewport
                for index in hosts.keys.filter({ $0 < first || $0 > last }) {
                    if let host = hosts.removeValue(forKey: index) {
                        host.removeFromSuperview()
                        recycle(host)
                    }
                }
                for index in visibleFirst...visibleLast {
                    mount(index, width: visible.width, content: content)
                }
                let range = first...last
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

            private func recycle(_ host: NSView) {
                if host is NSHostingView<ChatMeasuredTranscriptRow<Content>> {
                    if reusableHosting.count < Self.maximumPooledRows { reusableHosting.append(host) }
                } else if reusableNative.count < Self.maximumPooledRows {
                    reusableNative.append(host)
                }
            }

            /// A newly mounted row takes a pooled view of its own kind.
            private func pooledHost(_ index: Int, content: (Int) -> Content) -> NSView {
                let candidate = reusableNative.last
                if let native = nativeRowFactory?(index, candidate) {
                    if native === candidate { reusableNative.removeLast() }
                    #if DEBUG
                        nativeMounts += 1
                        if native !== candidate { createdRows += 1 }
                    #endif
                    return native
                }
                #if DEBUG
                    if reusableHosting.isEmpty { createdRows += 1 }
                #endif
                return hostingView(index, reused: reusableHosting.popLast(), content: content)
            }

            /// Refreshes a mounted row in place, replacing its view only when
            /// the row changed kind.
            private func configuredHost(_ index: Int, reused: NSView, content: (Int) -> Content)
                -> NSView
            {
                if let native = nativeRowFactory?(index, reused) {
                    #if DEBUG
                        nativeMounts += 1
                    #endif
                    return native
                }
                return hostingView(index, reused: reused, content: content)
            }

            private func hostingView(_ index: Int, reused: NSView?, content: (Int) -> Content)
                -> NSView
            {
                let id = geometry.ids[index]
                let revision = rowRevisions[id, default: 0]
                let measured = ChatMeasuredTranscriptRow(content: content(index)) {
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
                    host = pooledHost(index, content: content)
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
