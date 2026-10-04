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
        var historyLoadDistance: CGFloat = 0
        var onGeometryChange: ((ChatMacScrollGeometry, ChatMacScrollGeometry) -> Void)? = nil
        var onAttach: ((any ChatMacScrollDocument) -> Void)? = nil
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
                ChatBenchmarkAutoRun.isNativeGeometryWarm = false
                return
            }
            context.coordinator.virtualDocument.historyLoadDistance = historyLoadDistance
            context.coordinator.virtualDocument.onGeometryChange = onGeometryChange
            context.coordinator.update(
                ids: ids, width: width, measurementKeys: measurementKeys,
                presentationTheme: presentationTheme, nativeRowHeight: nativeRowHeight,
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

        final class Coordinator {
            // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
            nonisolated deinit {}

            let virtualDocument = VirtualDocument()
            var task: Task<Void, Never>?
            struct Measurement {
                let key: ChatNativeRowMeasurementKey?
                let width: CGFloat
                let height: CGFloat
            }
            var measurements: [String: Measurement] = [:]
            private var presentationTheme: ChatCodeHighlightTheme?
            private(set) var lastMeasuredRowCount = 0

            func update(
                ids: [String], width: CGFloat, measurementKeys: [ChatNativeRowMeasurementKey?] = [],
                presentationTheme: ChatCodeHighlightTheme? = nil,
                nativeRowHeight: ((Int, CGFloat) -> CGFloat?)? = nil,
                nativeRowFactory: ((Int, NSView?) -> NSView?)?,
                onAttach: ((any ChatMacScrollDocument) -> Void)?,
                content: @escaping (Int) -> Content
            ) {
                guard width > 0 else { return }
                if ids.isEmpty {
                    task?.cancel()
                    measurements.removeAll()
                    virtualDocument.install(heights: [], width: width, content: content)
                    return
                }
                task?.cancel()
                ChatBenchmarkAutoRun.isNativeGeometryWarm = false
                task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    let started = ContinuousClock.now
                    let measure = NSHostingController(rootView: content(0))
                    var result: [CGFloat] = []
                    var updatedMeasurements: [String: Measurement] = [:]
                    var changedIDs: Set<String> =
                        self.presentationTheme == presentationTheme ? [] : Set(ids)
                    var heightInvalidatedIDs = changedIDs
                    self.lastMeasuredRowCount = 0
                    result.reserveCapacity(ids.count)
                    for index in ids.indices {
                        if Task.isCancelled { return }
                        let key =
                            measurementKeys.indices.contains(index) ? measurementKeys[index] : nil
                        let previous = self.measurements[ids[index]]
                        let height: CGFloat
                        if let previous, previous.width == width, previous.key == key {
                            height =
                                self.virtualDocument.geometry.index(for: ids[index]).map {
                                    self.virtualDocument.geometry.heights[$0]
                                } ?? previous.height
                            if key == nil { changedIDs.insert(ids[index]) }
                        } else {
                            if let preparedHeight = nativeRowHeight?(index, width) {
                                height = max(1, ceil(preparedHeight))
                            } else {
                                measure.rootView = content(index)
                                let size = measure.sizeThatFits(
                                    in: CGSize(width: width, height: .greatestFiniteMagnitude))
                                height = max(1, ceil(size.height))
                            }
                            self.lastMeasuredRowCount += 1
                            changedIDs.insert(ids[index])
                            heightInvalidatedIDs.insert(ids[index])
                            await Task.yield()
                        }
                        result.append(height)
                        updatedMeasurements[ids[index]] = Measurement(
                            key: key, width: width, height: height)
                    }
                    guard !Task.isCancelled else { return }
                    self.measurements = updatedMeasurements
                    self.presentationTheme = presentationTheme
                    self.virtualDocument.nativeRowFactory = nativeRowFactory
                    self.virtualDocument.install(
                        heights: result, width: width, ids: ids, changedIDs: changedIDs,
                        heightInvalidatedIDs: heightInvalidatedIDs, content: content)
                    onAttach?(self.virtualDocument)
                    ChatBenchmarkAutoRun.trace(
                        "native geometry rows=\(result.count) measured=\(self.lastMeasuredRowCount) width=\(width) totalHeight=\(result.reduce(0,+)) elapsed=\(started.duration(to: .now))"
                    )
                    ChatBenchmarkAutoRun.isNativeGeometryWarm = true
                }
            }

        }

        final class VirtualDocument: NSView, ChatBenchmarkAnchoredDocument, ChatMacScrollDocument {
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

            func scrollToBenchmarkRow(_ index: Int) {
                guard index >= 0, index < offsets.count - 1 else { return }
                guard let scroll = enclosingScrollView else { return }
                ChatBenchmarkModel.setContentOffsetY(offsets[index], on: scroll)
            }
            override var isFlipped: Bool { true }
            var geometry = ChatVirtualTranscriptGeometry()
            var offsets: [CGFloat] { geometry.offsets }
            var contentWidth: CGFloat = 0
            var historyLoadDistance: CGFloat = 0
            var onGeometryChange: ((ChatMacScrollGeometry, ChatMacScrollGeometry) -> Void)?
            private var lastReportedGeometry: ChatMacScrollGeometry?
            private var pendingGeometry: ChatMacScrollGeometry?
            var geometryNotificationTask: Task<Void, Never>?
            var rowRevisions: [String: Int] = [:]
            private var nextRowRevision = 0
            var heightUpdateTask: Task<Void, Never>?
            var isApplyingHeights = false
            private var geometryCommitHandler: (() -> Void)?

            @discardableResult
            func setGeometryCommitHandler(_ handler: (() -> Void)?) -> Bool {
                geometryCommitHandler = handler
                return true
            }
            var content: ((Int) -> Content)?
            var hosts: [Int: NSView] = [:]
            var nativeRowFactory: ((Int, NSView?) -> NSView?)?
            var nativeMounts = 0
            var hostingMounts = 0
            var benchmarkStatistics: String {
                "nativeMounts=\(nativeMounts) hostingMounts=\(hostingMounts) resident=\(hosts.count) pooled=\(reusable.count)"
            }
            var reusable: [NSView] = []
            var preparationTask: Task<Void, Never>?
            var preparedRange: ClosedRange<Int>?

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
                self.content = content
                contentWidth = width
                let ids = ids.isEmpty ? heights.indices.map(String.init) : ids
                let oldIDs = geometry.ids
                geometry.replace(ids: ids, estimatedHeight: 1)
                geometry.updateHeights(Dictionary(uniqueKeysWithValues: zip(ids, heights)))
                rowRevisions = rowRevisions.filter { geometry.index(for: $0.key) != nil }
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
                            addSubview(updated)
                        }
                        retained[index] = updated
                    } else {
                        host.removeFromSuperview()
                        reusable.append(host)
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
                    host.frame = NSRect(x: 0, y: offsets[index], width: width,
                                        height: geometry.heights[index])
                }
            }

            private func notifyGeometryChange() {
                guard onGeometryChange != nil, let scroll = enclosingScrollView else { return }
                let clip = scroll.contentView
                let visible = clip.documentVisibleRect
                let geometry = ChatMacScrollGeometry(
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
                guard first <= last else { return }
                for index in Array(hosts.keys) where !(first...last).contains(index) {
                    if let host = hosts.removeValue(forKey: index) {
                        host.removeFromSuperview()
                        reusable.append(host)
                    }
                }
                let visibleFirst = max(first, row(at: visible.minY))
                let visibleLast = min(last, row(at: visible.maxY))
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
                        if self.hosts[index] == nil {
                            self.mount(index, width: visible.width, content: content)
                        }
                        await Task.yield()
                    }
                }
            }

            private func configuredHost(_ index: Int, reused: NSView?, content: (Int) -> Content)
                -> NSView
            {
                if let native = nativeRowFactory?(index, reused) {
                    nativeMounts += 1
                    return native
                } else {
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
                    hostingMounts += 1
                    return hosting
                }
            }

            private func mount(_ index: Int, width: CGFloat, content: (Int) -> Content) {
                let host: NSView
                if let existing = hosts[index] {
                    host = existing
                } else {
                    host = configuredHost(index, reused: reusable.popLast(), content: content)
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
