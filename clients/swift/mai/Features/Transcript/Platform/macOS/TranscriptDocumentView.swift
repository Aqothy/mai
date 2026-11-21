#if os(macOS)
    import AppKit
    import QuartzCore

    /// The transcript's document on the Mac: as tall as its rows, it mounts a
    /// layer per row near the viewport and positions it from the controller's
    /// geometry. It reports every clip move to the controller synchronously
    /// and moves the clip only when the controller asks (PLAN 3.9).
    ///
    /// Opted into responsive scrolling: AppKit then scrolls without waiting
    /// for the main thread and asks for the overdraw region it wants ready
    /// through `prepareContent(in:)`, which mounts and draws rows there. No
    /// `scrollWheel` or drawing overrides here, the clip view or the scroll
    /// view, which AppKit's compatibility checks may read as opting out.
    final class TranscriptDocumentView: NSView, TranscriptViewportHost, TranscriptRowMounterDelegate {
        let controller: TranscriptController
        /// Starts a Comment on the selected text: quote, message ID, role
        /// (PLAN Q4). Nil hides the menu item.
        var onComment: ((String, String?, String?) -> Void)?
        /// The fork menu of finished turn `turnID`; nil when the chat cannot
        /// fork. Fork buttons show only while there is one; rows place their
        /// buttons only when their layout or place changes, so they follow
        /// it here.
        var forkMenu: ((String) -> TranscriptMenu?)? {
            didSet {
                guard (oldValue == nil) != (forkMenu == nil) else { return }
                for button in accessoryButtons.values.joined() {
                    if case .fork = button.accessory { button.isHidden = forkMenu == nil }
                }
            }
        }
        private var accessoryButtons: [String: [TranscriptAccessoryButton]] = [:]
        private var accessoryPool: [TranscriptAccessoryButton] = []
        private let rowsView = TranscriptRowsView()
        let mounter: TranscriptRowMounter
        private(set) var wideBlocks: [String: TranscriptWideBlockScrollView] = [:]
        private var wideBlockPool: [TranscriptWideBlockScrollView] = []
        private(set) var palette: TextPalette?
        private var displayLink: CADisplayLink?
        private var needsFrames = false
        private var isContentVisible = false

        // Constant, so AppKit's frequent calls skip the main-actor check.
        nonisolated override var isFlipped: Bool { true }
        override class var isCompatibleWithResponsiveScrolling: Bool { true }
        override var wantsUpdateLayer: Bool { true }

        init(controller: TranscriptController) {
            self.controller = controller
            mounter = TranscriptRowMounter(container: rowsView.rowsLayer)
            mounter.drawsOffMain = controller.configuration.drawsOffMain
            super.init(frame: .zero)
            mounter.delegate = self
            wantsLayer = true
            layerContentsRedrawPolicy = .never
            addSubview(rowsView)
            alphaValue = 0
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func updateLayer() {}

        private var clip: NSClipView? { enclosingScrollView?.contentView }
        var scale: CGFloat { window?.backingScaleFactor ?? 2 }
        var colorSpace: CGColorSpace { window?.colorSpace?.cgColorSpace ?? RowLayer.colorSpace }

        // MARK: Lifecycle

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard window != nil, let clip else {
                controller.detach(self)
                displayLink?.invalidate()
                displayLink = nil
                return
            }
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipDidChange), name: NSView.boundsDidChangeNotification, object: clip)
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipDidChange), name: NSView.frameDidChangeNotification, object: clip)
            updatePalette()
            if let window {
                for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                    NotificationCenter.default.addObserver(
                        self, selector: #selector(windowKeyStateDidChange), name: name, object: window)
                }
            }
            displayLink?.invalidate()
            let link = displayLink(target: self, selector: #selector(frameDidTick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            controller.attach(self)
            updateFrameLink()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updatePalette()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            mounter.invalidate()
            placeRowsIfNeeded()
        }

        /// The appearance and contrast the palette was resolved for: AppKit
        /// calls `viewDidChangeEffectiveAppearance` more often than it changes,
        /// and a new palette places every row again.
        private var paletteAppearance: NSAppearance.Name?
        private var paletteIncreasedContrast = false

        private func updatePalette() {
            let name = effectiveAppearance.name
            let increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            guard name != paletteAppearance || increasedContrast != paletteIncreasedContrast || palette == nil else {
                return
            }
            paletteAppearance = name
            paletteIncreasedContrast = increasedContrast
            let palette = TextPalette.resolve(for: effectiveAppearance)
            self.palette = palette
            updateSelectionColor()
            controller.setPalette(palette)
            mounter.invalidate()
            placeRowsIfNeeded()
        }

        @objc private func clipDidChange() {
            matchClipWidth()
            controller.viewportDidChange()
            placeRowsIfNeeded()
        }

        /// The transcript scrolls vertically only: the document is as wide as
        /// the clip, and a horizontal offset a wider document allowed goes.
        private func matchClipWidth() {
            guard let scrollView = enclosingScrollView else { return }
            let width = scrollView.contentSize.width
            if frame.width != width { setFrameSize(NSSize(width: width, height: frame.height)) }
            if scrollView.contentView.bounds.origin.x != 0 {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollView.contentView.bounds.origin.y))
            }
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            attachRowsLayer()
        }

        /// The rows view is as big as the document, under the code scrollers.
        private func attachRowsLayer() {
            if rowsView.frame != bounds { rowsView.frame = bounds }
        }

        override func layout() {
            super.layout()
            placeRowsIfNeeded()
        }

        /// AppKit's responsive scrolling asks for the overdraw region it
        /// wants ready; the mounter draws it with its own window.
        override func prepareContent(in rect: NSRect) {
            mounter.prepare(rect)
            placeRowsIfNeeded()
            super.prepareContent(in: rect)
        }

        // MARK: TranscriptViewportHost

        var viewport: TranscriptViewport? {
            guard let clip, clip.bounds.width > 0, clip.bounds.height > 0 else { return nil }
            return TranscriptViewport(
                size: clip.bounds.size, topInset: clip.contentInsets.top, bottomInset: clip.contentInsets.bottom)
        }

        var viewportTop: CGFloat {
            guard let clip else { return 0 }
            return clip.bounds.minY + clip.contentInsets.top
        }

        func setDocumentHeight(_ height: CGFloat) {
            let width = enclosingScrollView?.contentSize.width ?? frame.width
            if frame.size != NSSize(width: width, height: height) {
                setFrameSize(NSSize(width: width, height: height))
            }
        }

        func setViewportTop(_ top: CGFloat) {
            guard let scrollView = enclosingScrollView else { return }
            let clip = scrollView.contentView
            var proposed = clip.bounds
            proposed.origin = NSPoint(x: 0, y: top - clip.contentInsets.top)
            let origin = clip.constrainBoundsRect(proposed).origin
            guard origin != clip.bounds.origin else { return }
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
        }

        func setContentVisible(_ visible: Bool) {
            isContentVisible = visible
            alphaValue = visible ? 1 : 0
        }

        func setNeedsRowPlacement() {
            mounter.invalidate()
            needsLayout = true
        }

        func setNeedsSelectionDisplay() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mounter.showSelection(controller)
            CATransaction.commit()
        }

        func setNeedsFrameUpdates(_ needed: Bool) {
            needsFrames = needed
            updateFrameLink()
        }

        private func updateFrameLink() {
            #if DEBUG
                let blocks = TranscriptMainThreadBlocker.milliseconds > 0
            #else
                let blocks = false
            #endif
            displayLink?.isPaused = !(needsFrames || blocks)
        }

        @objc private func frameDidTick(_ link: CADisplayLink) {
            #if DEBUG
                TranscriptMainThreadBlocker.blockIfRequested()
            #endif
            if needsFrames { controller.frameDidTick() }
        }

        // MARK: Rows

        /// Places rows if the viewport left what was placed for it or the
        /// controller changed something; at most once per frame however many
        /// of the clip move, `prepareContent(in:)` and layout ask.
        private func placeRowsIfNeeded() {
            // Mid-change, rows may be a moment from their layouts: place them
            // in this frame's layout pass instead, once the change is whole.
            guard !controller.isUpdating else {
                needsLayout = true
                return
            }
            guard let clip, mounter.needsPlacement(visible: clip.documentVisibleRect) else { return }
            placeRows()
        }

        /// A visible row without a layout gets one now (PLAN D3); the mounter
        /// does the rest.
        private func placeRows() {
            guard let clip, let palette, controller.columnWidth > 0 else { return }
            attachRowsLayer()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            if isContentVisible {
                let visible = clip.documentVisibleRect
                controller.layOutVisibleRows(minY: visible.minY, maxY: visible.maxY)
            }
            mounter.place(
                controller, visible: clip.documentVisibleRect, documentWidth: bounds.width, palette: palette,
                scale: scale, colorSpace: colorSpace, showsContent: isContentVisible)
        }

        // MARK: TranscriptRowMounterDelegate

        func showWideBlock(
            rowID: String, body: WideBlockBody, key: RowLayoutKey, origin: CGPoint, drawn: CGRect, visible: CGRect,
            streamed: DrawnBands?
        ) {
            let scroller = wideBlocks[rowID] ?? wideBlockPool.popLast() ?? TranscriptWideBlockScrollView()
            if wideBlocks[rowID] == nil {
                wideBlocks[rowID] = scroller
                scroller.transcriptScrollView = enclosingScrollView
                if scroller.superview == nil { addSubview(scroller) }
                scroller.isHidden = false
            }
            let frame = body.frame.offsetBy(dx: origin.x, dy: origin.y)
            if scroller.frame != frame { scroller.frame = frame }
            guard let palette else { return }
            let localDrawn = drawn.offsetBy(dx: -frame.minX, dy: -frame.minY)
            let localVisible = visible.isNull ? .null : visible.offsetBy(dx: -frame.minX, dy: -frame.minY)
            scroller.show(
                rowID: rowID, body: body, key: key, palette: palette, scale: scale, colorSpace: colorSpace,
                drawsOffMain: controller.configuration.drawsOffMain, drawn: localDrawn, visible: localVisible,
                streamed: streamed)
        }

        func showWideBlockSelection(rowID: String, range: Range<Int>?, color: CGColor) {
            wideBlocks[rowID]?.showSelection(range, color: color)
        }

        func showAccessories(rowID: String, accessories: [RowAccessory], origin: CGPoint) {
            var buttons = accessoryButtons[rowID] ?? []
            while buttons.count > accessories.count { recycle(buttons.removeLast()) }
            while buttons.count < accessories.count {
                let button = accessoryPool.popLast() ?? TranscriptAccessoryButton()
                if button.superview == nil { addSubview(button) }
                buttons.append(button)
            }
            for (button, accessory) in zip(buttons, accessories) {
                if case .fork = accessory.action {
                    button.isHidden = forkMenu == nil
                } else {
                    button.isHidden = false
                }
                let frame = accessory.frame.offsetBy(dx: origin.x, dy: origin.y)
                if button.frame != frame { button.frame = frame }
                button.show(accessory.action)
                button.onFork = { [weak self] turnID, button in
                    guard let menu = self?.forkMenu?(turnID) else { return }
                    NSMenu(menu).popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 2), in: button)
                }
            }
            accessoryButtons[rowID] = buttons
        }

        func removeAccessories(rowID: String) {
            for button in accessoryButtons.removeValue(forKey: rowID) ?? [] { recycle(button) }
        }

        /// Pooled controls stay in the view tree, hidden: adding or removing
        /// a subview makes SwiftUI's hosting view lay the chat screen out
        /// again, which in a fast scroll was most of a slow frame.
        private func recycle(_ button: TranscriptAccessoryButton) {
            button.resetForReuse()
            button.isHidden = true
            if accessoryPool.count < 16 {
                accessoryPool.append(button)
            } else {
                button.removeFromSuperview()
            }
        }

        func removeWideBlock(rowID: String) {
            guard let scroller = wideBlocks.removeValue(forKey: rowID) else { return }
            scroller.resetForReuse()
            scroller.isHidden = true
            if wideBlockPool.count < 8 {
                wideBlockPool.append(scroller)
            } else {
                scroller.removeFromSuperview()
            }
        }

        #if DEBUG
            var mountedRowCount: Int { mounter.mountedRowCount }
        #endif
    }
#endif
