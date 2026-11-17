#if os(iOS)
    import QuartzCore
    import SwiftUI
    import UIKit

    /// Native transcript viewport with stable row geometry and bounded view reuse.
    /// The parent prepares content before publishing a new set of rows.
    struct ChatNativeTranscript<Content: View>: UIViewRepresentable {
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
        var nativeRowFactory: ((Int, UIView?) -> UIView?)? = nil
        @ViewBuilder let content: (Int) -> Content

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeUIView(context: Context) -> VirtualDocument {
            context.coordinator.virtualDocument
        }

        func updateUIView(_ document: VirtualDocument, context: Context) {
            guard isPrepared else {
                context.coordinator.task?.cancel()
                #if DEBUG
                    ChatBenchmarkAutoRun.isNativeGeometryWarm = false
                #endif
                return
            }
            document.historyLoadDistance = historyLoadDistance
            document.geometryReporter.onChange = onGeometryChange
            context.coordinator.update(
                ids: ids, sourceIDs: sourceIDs, width: width, measurementKeys: measurementKeys,
                presentationTheme: presentationTheme, layoutStore: layoutStore,
                nativeRowHeight: nativeRowHeight,
                nativeRowFactory: nativeRowFactory,
                onAttach: onAttach, content: content)
        }

        static func dismantleUIView(_ document: VirtualDocument, coordinator: Coordinator) {
            coordinator.task?.cancel()
            document.tearDown()
        }

        /// The transcript's scroll view. Rows are direct subviews, mounted
        /// for the viewport and one viewport on either side of it, at frames
        /// taken from geometry that is complete before any row exists.
        ///
        /// Geometry and the content offset have this one owner: every change
        /// to row heights also repositions the mounted rows, resizes the
        /// content and restores the reading position before the frame draws.
        final class VirtualDocument: UIScrollView, ChatIOSScrollDocument {
            // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
            nonisolated deinit {}

            private struct TiledViewport: Equatable {
                let resident: ClosedRange<Int>
                let visible: ClosedRange<Int>
            }

            /// Main-thread time one display frame may spend mounting rows the
            /// reader has not reached yet. A mount cannot be split, so a slow
            /// row still takes one whole frame's share.
            private static var preparationBudget: CFTimeInterval { 0.002 }
            private static var maximumPooledRows: Int { 32 }

            var geometry = ChatVirtualTranscriptGeometry()
            var offsets: [CGFloat] { geometry.offsets }
            var numberOfRows: Int { geometry.ids.count }
            var historyLoadDistance: CGFloat = 0
            let geometryReporter = ChatScrollGeometryReporter()
            var isBottomFollowingEnabled: () -> Bool = { false }
            var initialBottomAlignmentCompletion: (() -> Void)?
            var onReaderScroll: ((_ fromTop: CGFloat) -> Void)?
            /// True while the document itself moves the content offset.
            private var isAdjustingScrollPosition = false
            /// The viewport the last move was seen in, and its top then.
            /// UIKit moves the offset itself, inside the assignment, when
            /// the insets or the size change; such a move is not the reader's.
            private var lastViewport: Viewport?
            private var lastViewportTop: CGFloat = 0
            private var scrollAnimation: ScrollAnimation?
            private(set) var rowRevisions = ChatTranscriptRowRevisions()
            var content: ((Int) -> Content)?
            var hosts: [Int: UIView] = [:]
            var nativeRowFactory: ((Int, UIView?) -> UIView?)?
            /// Unmounted rows by kind: a hosting view cannot become a native
            /// row, so a mixed pool would discard about half of what it holds.
            var reusableNative: [UIView] = []
            var reusableHosting: [UIView] = []
            #if DEBUG
                var nativeMounts = 0
                var hostingMounts = 0
                var createdRows = 0
            #endif
            private var tiledViewport: TiledViewport?
            private var preparationLink: CADisplayLink?
            private var laidOutSize = CGSize.zero
            private var laidOutOffsetY: CGFloat = 0
            private var scrollsTowardEnd = false
            private var keyboardTransition: KeyboardTransition?

            /// The keyboard's own animation, so the transcript's end rises
            /// and falls with it instead of jumping to where it will stop.
            private struct Viewport: Equatable {
                let size: CGSize
                let insets: UIEdgeInsets
            }

            private struct KeyboardTransition {
                let end: CFTimeInterval
                let options: UIView.AnimationOptions
            }

            /// The reader's jump to the end. Each frame lands a shrinking
            /// distance short of the end as it is then, so rows that grow
            /// on the way move the target and the jump still arrives.
            /// UIKit's own animation runs to the offset it computed at the
            /// start, and reports no end when something else stops it.
            private struct ScrollAnimation {
                let start: CFTimeInterval
                let distanceFromEnd: CGFloat
                let link: CADisplayLink
            }

            private static var scrollAnimationDuration: CFTimeInterval { 0.3 }

            override init(frame: CGRect) {
                super.init(frame: frame)
                alwaysBounceVertical = true
                showsHorizontalScrollIndicator = false
                // Scrolling the transcript leaves the keyboard up; a drag
                // that reaches the keyboard pulls it down with the finger.
                keyboardDismissMode = .interactive
                // The insets come from `setViewportInsets`.
                contentInsetAdjustmentBehavior = .never
                automaticallyAdjustsScrollIndicatorInsets = false
                backgroundColor = .clear
                NotificationCenter.default.addObserver(
                    self, selector: #selector(keyboardWillChangeFrame(_:)),
                    name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            func tearDown() {
                preparationLink?.invalidate()
                preparationLink = nil
                NotificationCenter.default.removeObserver(self)
                geometryReporter.cancel()
                geometryReporter.onChange = nil
                delegate = nil
                initialBottomAlignmentCompletion = nil
                endScrollAnimation()
            }

            // MARK: Rows

            func row(at y: CGFloat) -> Int { geometry.index(at: y) ?? -1 }

            /// Sizes one SwiftUI row at a width. The hosting controller is
            /// shared by every row of an update and built on first use.
            func makeRowMeasurer() -> (Content, CGFloat) -> CGFloat {
                var controller: UIHostingController<Content>?
                return { [weak self] rootView, width in
                    let measuring: UIHostingController<Content>
                    if let controller {
                        controller.rootView = rootView
                        measuring = controller
                    } else {
                        measuring = UIHostingController(rootView: rootView)
                        measuring.safeAreaRegions = []
                        // The controller is never in a window, so it would
                        // measure at the default text size and appearance.
                        if let traits = self?.traitCollection {
                            measuring.traitOverrides.preferredContentSizeCategory =
                                traits.preferredContentSizeCategory
                            measuring.traitOverrides.legibilityWeight = traits.legibilityWeight
                            measuring.traitOverrides.horizontalSizeClass = traits.horizontalSizeClass
                            measuring.traitOverrides.verticalSizeClass = traits.verticalSizeClass
                            measuring.traitOverrides.layoutDirection = traits.layoutDirection
                            measuring.traitOverrides.displayScale = traits.displayScale
                            measuring.traitOverrides.userInterfaceStyle = traits.userInterfaceStyle
                        }
                        controller = measuring
                    }
                    return measuring.sizeThatFits(
                        in: CGSize(width: width, height: .greatestFiniteMagnitude)
                    ).height
                }
            }

            func install(
                heights: [CGFloat], width: CGFloat, ids: [String] = [], sourceIDs: [String] = [],
                changedIDs: Set<String>? = nil, heightInvalidatedIDs: Set<String>? = nil,
                content: @escaping (Int) -> Content
            ) {
                // Content, row frames, content size and scroll compensation
                // belong to one layout pass. Never yield between them.
                UIView.performWithoutAnimation {
                    self.content = content
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
                            configure: { configuredHost($0, current: $1) },
                            recycle: recycle, show: show)
                    }
                    tiledViewport = nil
                    alignInitialBottomIfPossible()
                    setNeedsLayout()
                }
            }

            func noteHeight(_ height: CGFloat, id: String, revision: Int) {
                guard rowRevisions.accepts(height, id: id, revision: revision, in: geometry)
                else { return }
                // Commit geometry before this layout can paint. Deferring these
                // frames leaves the working row over newly expanded content.
                UIView.performWithoutAnimation {
                    updateGeometry { geometry.updateHeights([id: height]) }
                }
                // The report arrives inside the row's own SwiftUI layout. Rows
                // the new geometry exposes mount in the next layout pass.
                setNeedsLayout()
            }

            // MARK: Reading position

            var viewportTop: CGFloat? { contentOffset.y + adjustedContentInset.top }

            var bottomViewportTop: CGFloat? {
                guard numberOfRows > 0, bounds.height > 0 else { return nil }
                return bottomOffsetY + adjustedContentInset.top
            }

            func setViewportTop(_ top: CGFloat) {
                // A running jump places the viewport relative to the end on
                // its next frame.
                guard scrollAnimation == nil else { return }
                moveViewportTop(to: top)
            }

            private func moveViewportTop(to top: CGFloat) {
                var y = top - adjustedContentInset.top
                // A gesture may hold the content past either end; layout may not.
                if !isTracking, !isDecelerating {
                    y = min(max(y, -adjustedContentInset.top), bottomOffsetY)
                }
                setContentOffsetY(y)
            }

            func applyGeometryToViews() {
                let size = CGSize(width: bounds.width, height: geometry.totalHeight)
                if contentSize != size {
                    // UIKit may move the offset into a smaller content
                    // itself; that is layout, not the reader.
                    isAdjustingScrollPosition = true
                    contentSize = size
                    isAdjustingScrollPosition = false
                }
                repositionMountedRows()
            }

            private var bottomOffsetY: CGFloat {
                ChatScrollGeometry.bottomOffset(
                    contentHeight: contentSize.height, viewportHeight: bounds.height,
                    topInset: adjustedContentInset.top, bottomInset: adjustedContentInset.bottom)
            }

            var isNearBottom: Bool {
                numberOfRows > 0
                    && contentSize.height + adjustedContentInset.bottom - bounds.maxY
                        <= ChatTimelineMetrics.nearBottomDistance
            }

            /// Assigning the offset keeps a drag or deceleration going from the
            /// new position; `setContentOffset(_:animated:)` would end it.
            private func setContentOffsetY(_ y: CGFloat) {
                let scale = max(1, traitCollection.displayScale)
                let aligned = (y * scale).rounded() / scale
                guard abs(contentOffset.y - aligned) > 0.01 else { return }
                isAdjustingScrollPosition = true
                contentOffset = CGPoint(x: contentOffset.x, y: aligned)
                isAdjustingScrollPosition = false
            }

            @discardableResult
            func scrollToBottom(animated: Bool) -> Bool {
                endScrollAnimation()
                // Without a window there are no frames to animate in.
                guard animated, window != nil else { return scrollToBottom() }
                guard let bottom = bottomViewportTop, let top = viewportTop else { return false }
                let distance = bottom - top
                guard abs(distance) > ChatScrollFollowPolicy.minimumMovement else {
                    return scrollToBottom()
                }
                let link = CADisplayLink(target: self, selector: #selector(stepScrollAnimation))
                link.add(to: .main, forMode: .common)
                scrollAnimation = ScrollAnimation(
                    start: CACurrentMediaTime(), distanceFromEnd: distance, link: link)
                return true
            }

            @objc private func stepScrollAnimation(_ link: CADisplayLink) {
                advanceScrollAnimation(to: link.targetTimestamp)
            }

            /// Places the jump's frame for `time`, ending it at the end.
            func advanceScrollAnimation(to time: CFTimeInterval) {
                guard let animation = scrollAnimation, let bottom = bottomViewportTop else {
                    endScrollAnimation()
                    return
                }
                let progress = min(
                    1, max(0, (time - animation.start) / Self.scrollAnimationDuration))
                let remaining = pow(1 - progress, 3)
                moveViewportTop(to: bottom - animation.distanceFromEnd * remaining)
                if progress >= 1 {
                    endScrollAnimation()
                }
            }

            /// Called for every content offset change. One the document did
            /// not make, in an unchanged viewport, is the reader's.
            func noteOffsetChange() {
                let viewport = Viewport(size: bounds.size, insets: adjustedContentInset)
                guard !isAdjustingScrollPosition, viewport == lastViewport else {
                    recordViewport()
                    return
                }
                let from = lastViewportTop
                let top = contentOffset.y + adjustedContentInset.top
                // Small steps add up: a slow scroll moves less than this each frame.
                guard abs(top - from) > ChatScrollFollowPolicy.minimumMovement else { return }
                lastViewportTop = top
                // The reader took over from a jump to the end.
                endScrollAnimation()
                onReaderScroll?(from)
            }

            /// After the viewport changed, moved or not.
            private func recordViewport() {
                lastViewport = Viewport(size: bounds.size, insets: adjustedContentInset)
                lastViewportTop = contentOffset.y + adjustedContentInset.top
            }

            /// Stops a jump to the end where it is; the reader took over.
            func endScrollAnimation() {
                scrollAnimation?.link.invalidate()
                scrollAnimation = nil
            }

            /// Geometry changes move every resident row, including prepared neighbors.
            /// Otherwise a growing reply can overlap an already-mounted working row.
            private func repositionMountedRows() {
                let width = bounds.width
                for (index, host) in hosts {
                    let frame = CGRect(
                        x: 0, y: offsets[index], width: width, height: geometry.heights[index])
                    if host.frame != frame {
                        host.frame = frame
                    }
                }
            }

            // MARK: Viewport

            override func layoutSubviews() {
                super.layoutSubviews()
                if bounds.size != laidOutSize {
                    // Rotation, split view and the first layout resize the
                    // viewport without a new install.
                    laidOutSize = bounds.size
                    UIView.performWithoutAnimation {
                        applyGeometryToViews()
                        keepViewportInRange()
                    }
                    recordViewport()
                    tiledViewport = nil
                    alignInitialBottomIfPossible()
                }
                let offsetY = contentOffset.y
                if offsetY != laidOutOffsetY {
                    scrollsTowardEnd = offsetY > laidOutOffsetY
                    laidOutOffsetY = offsetY
                }
                tile()
                notifyGeometryChange()
            }

            @objc private func keyboardWillChangeFrame(_ notification: Notification) {
                guard
                    let duration = notification.userInfo?[
                        UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval,
                    duration > 0,
                    let curve = notification.userInfo?[
                        UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt
                else {
                    keyboardTransition = nil
                    return
                }
                // The curve's raw value is an animation option's curve bits.
                keyboardTransition = KeyboardTransition(
                    end: CACurrentMediaTime() + duration,
                    options: UIView.AnimationOptions(rawValue: curve << 16))
            }

            func setViewportInsets(_ insets: UIEdgeInsets) {
                guard contentInset != insets else { return }
                let change = {
                    self.contentInset = insets
                    self.verticalScrollIndicatorInsets = insets
                }
                let now = CACurrentMediaTime()
                if window != nil, let transition = keyboardTransition, transition.end > now {
                    UIView.animate(
                        withDuration: transition.end - now, delay: 0,
                        options: [transition.options, .beginFromCurrentState, .allowUserInteraction],
                        animations: change)
                } else {
                    UIView.performWithoutAnimation(change)
                }
            }

            /// The keyboard and the composer change the visible area without
            /// changing the bounds.
            override func adjustedContentInsetDidChange() {
                super.adjustedContentInsetDidChange()
                keepViewportInRange()
                recordViewport()
                setNeedsLayout()
            }

            /// After the viewport or its insets change: lands on the end
            /// while following, and otherwise moves back inside the content.
            /// UIKit leaves the offset where it was, so a keyboard closing
            /// while the reader is just above the end would leave blank space
            /// below the last row.
            private func keepViewportInRange() {
                if isFollowingBottom {
                    scrollToBottom()
                } else if let viewportTop {
                    setViewportTop(viewportTop)
                }
            }

            override func willMove(toWindow newWindow: UIWindow?) {
                super.willMove(toWindow: newWindow)
                if newWindow == nil {
                    // The display links retain their target.
                    preparationLink?.invalidate()
                    preparationLink = nil
                    if scrollAnimation != nil {
                        // A jump has no frames off screen; it lands now.
                        endScrollAnimation()
                        scrollToBottom()
                    }
                }
            }

            override func didMoveToWindow() {
                super.didMoveToWindow()
                if window != nil {
                    tiledViewport = nil
                    setNeedsLayout()
                }
            }

            /// Mounts what the viewport shows and returns to the pool what is
            /// more than a viewport away. Runs on every scrolled frame, so an
            /// unchanged viewport costs two binary searches.
            private func tile() {
                guard content != nil, bounds.height > 0,
                    let tiling = geometry.tiling(top: bounds.minY, bottom: bounds.maxY)
                else { return }
                let viewport = TiledViewport(resident: tiling.resident, visible: tiling.visible)
                guard viewport != tiledViewport else { return }
                tiledViewport = viewport

                UIView.performWithoutAnimation {
                    for index in hosts.keys where !tiling.resident.contains(index) {
                        if let host = hosts.removeValue(forKey: index) {
                            recycle(host)
                        }
                    }
                    for index in tiling.visible where hosts[index] == nil {
                        mount(index)
                    }
                }
                if nextRowToPrepare() != nil {
                    startPreparingNearbyRows()
                }
            }

            /// The nearest unmounted row in the resident range, looking first
            /// where the reader is heading.
            private func nextRowToPrepare() -> Int? {
                guard let viewport = tiledViewport else { return nil }
                let after = stride(
                    from: viewport.visible.upperBound + 1,
                    through: viewport.resident.upperBound, by: 1)
                let before = stride(
                    from: viewport.visible.lowerBound - 1,
                    through: viewport.resident.lowerBound, by: -1)
                if scrollsTowardEnd {
                    return after.first { hosts[$0] == nil } ?? before.first { hosts[$0] == nil }
                }
                return before.first { hosts[$0] == nil } ?? after.first { hosts[$0] == nil }
            }

            private func startPreparingNearbyRows() {
                guard window != nil else { return }
                if preparationLink == nil {
                    let link = CADisplayLink(
                        target: self, selector: #selector(prepareNearbyRows))
                    link.add(to: .main, forMode: .common)
                    preparationLink = link
                }
                preparationLink?.isPaused = false
            }

            /// Mounts rows the reader is about to reach, a little each frame,
            /// so the frame that exposes a row only moves it.
            @objc private func prepareNearbyRows() {
                let deadline = CACurrentMediaTime() + Self.preparationBudget
                UIView.performWithoutAnimation {
                    while let index = nextRowToPrepare() {
                        mount(index)
                        if CACurrentMediaTime() >= deadline { break }
                    }
                }
                if nextRowToPrepare() == nil {
                    preparationLink?.isPaused = true
                }
            }

            private func notifyGeometryChange() {
                let insets = adjustedContentInset
                geometryReporter.report(ChatScrollGeometry(
                    isNearTop: numberOfRows > 0
                        && contentOffset.y + insets.top <= historyLoadDistance,
                    isNearBottom: isNearBottom,
                    containerWidth: bounds.width.rounded(),
                    containerHeight: bounds.height.rounded(),
                    bottomInset: insets.bottom.rounded(),
                    contentHeight: contentSize.height.rounded()))
            }

            // MARK: Row views

            private func mount(_ index: Int) {
                guard hosts[index] == nil else { return }
                let host = configuredHost(index)
                hosts[index] = host
                host.frame = CGRect(
                    x: 0, y: offsets[index], width: bounds.width, height: geometry.heights[index])
                show(host)
                // Offscreen preparation must perform layout now; mounting an
                // unlaid-out row only postpones the work until exposure.
                host.layoutIfNeeded()
            }

            private func show(_ host: UIView) {
                if host.superview !== self {
                    // Below the scroll indicators, which are subviews too.
                    insertSubview(host, at: 0)
                }
                host.isHidden = false
            }

            /// A pooled native row stays in the hierarchy, hidden: moving a
            /// text view out of a window and back costs about as much as
            /// showing new text in it. A pooled SwiftUI row leaves, or its
            /// old content would go on observing and animating unseen.
            private func recycle(_ host: UIView) {
                if host is any UIContentView {
                    host.removeFromSuperview()
                    if reusableHosting.count < Self.maximumPooledRows {
                        reusableHosting.append(host)
                    }
                } else if reusableNative.count < Self.maximumPooledRows {
                    // A hidden view can stay first responder and keep its
                    // selection's edit menu up.
                    host.endEditing(true)
                    host.isHidden = true
                    reusableNative.append(host)
                } else {
                    host.removeFromSuperview()
                }
            }

            private func configuredHost(_ index: Int, current: UIView? = nil) -> UIView {
                ChatTranscriptMountedRows.configuredHost(
                    index, current: current, isHosting: { $0 is any UIContentView },
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
                    hostingRow: hostingView)
            }

            private func hostingView(_ index: Int, reused: UIView?) -> UIView {
                #if DEBUG
                    if reused == nil { createdRows += 1 }
                #endif
                guard let content else { return reused ?? UIView() }
                let id = geometry.ids[index]
                let revision = rowRevisions[id] ?? 0
                // A hosting configuration's view needs no view controller and
                // takes no part in the safe area or keyboard avoidance, which
                // would otherwise move a row's content as it scrolls under a bar.
                let configuration = UIHostingConfiguration {
                    ChatMeasuredTranscriptRow(revision: revision, content: content(index)) { [weak self] height in
                        self?.noteHeight(height, id: id, revision: revision)
                    }
                }
                .margins(.all, 0)
                .minSize(width: 0, height: 0)
                #if DEBUG
                    hostingMounts += 1
                #endif
                if let hosted = reused as? any (UIView & UIContentView) {
                    hosted.configuration = configuration
                    return hosted
                }
                return configuration.makeContentView()
            }
        }
    }
#endif
