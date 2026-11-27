#if os(iOS)
    import UIKit

    /// The transcript on iOS: a scroll view that is its own document. It
    /// reports every offset, size and inset change to the controller
    /// synchronously and moves only when the controller asks (PLAN 3.9);
    /// rows are layers the shared mounter places in content coordinates.
    ///
    /// UIKit runs scrolling on the main thread, so a scrolled frame here
    /// costs a viewport report and, every eighth of a screen, a placement:
    /// layouts and drawing happen ahead, off the main thread (PLAN 1).
    final class TranscriptScrollView: UIScrollView, UIScrollViewDelegate, TranscriptViewportHost,
        TranscriptRowMounterDelegate
    {
        let controller: TranscriptController
        /// Starts a Comment on selected text: quote, message ID, role.
        var onComment: ((String, String?, String?) -> Void)? {
            get { contentView.onComment }
            set { contentView.onComment = newValue }
        }
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
        /// Document-sized, and the text input UIKit's selection works on: the
        /// rows view at the back, then the code scrollers and buttons, so
        /// controls sit over the rows they belong to.
        let contentView = TranscriptTextInputView()
        private let rowsView = UIView()
        /// The code blocks and tables wider than the column, above the rows
        /// and below the views UIKit's text interaction adds later (highlight,
        /// handles), so a scroller never covers the selection. Only the
        /// scrollers' scroll bars take touches (see `makeWideBlockScroller`).
        private let wideBlocksView = PassthroughView()
        let mounter: TranscriptRowMounter
        private(set) var palette: TextPalette?
        private var updateLink: UIUpdateLink?
        private var needsFrames = false
        private var isContentVisible = false
        private var laidOutSize = CGSize.zero
        private(set) var wideBlocks: [String: TranscriptWideBlockScroller] = [:]
        private var wideBlockPool: [TranscriptWideBlockScroller] = []
        private var accessoryButtons: [String: [TranscriptAccessoryControl]] = [:]
        private var accessoryPool: [TranscriptAccessoryControl] = []
        let tapDelegate = TranscriptTapGestureDelegate()
        private var keyboardTransition: KeyboardTransition?
        private var lastNotifiedSelectionRects: [CGRect] = []

        /// The keyboard's own animation, so insets change with it and the
        /// transcript's end rises and falls with the keyboard.
        private struct KeyboardTransition {
            let end: CFTimeInterval
            let options: UIView.AnimationOptions
        }

        init(controller: TranscriptController) {
            self.controller = controller
            mounter = TranscriptRowMounter(container: rowsView.layer)
            mounter.drawsOffMain = controller.configuration.drawsOffMain
            // UIKit's text interaction draws the selection highlight.
            mounter.drawsSelection = false
            super.init(frame: .zero)
            mounter.delegate = self
            delegate = self
            contentView.controller = controller
            contentView.columnX = { [weak self] in self?.columnX ?? 0 }
            contentView.scrollX = { [weak self] rowID in self?.wideBlocks[rowID]?.scrollX ?? 0 }
            alwaysBounceVertical = true
            showsHorizontalScrollIndicator = false
            // Scrolling leaves the keyboard up; a drag reaching it pulls it down.
            keyboardDismissMode = .interactive
            // Insets come from SwiftUI through `setViewportInsets`.
            contentInsetAdjustmentBehavior = .never
            automaticallyAdjustsScrollIndicatorInsets = false
            backgroundColor = .clear
            rowsView.isUserInteractionEnabled = false
            contentView.addSubview(rowsView)
            contentView.addSubview(wideBlocksView)
            contentView.alpha = 0
            addSubview(contentView)
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardWillChangeFrame(_:)),
                name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            for name in [
                UIApplication.didReceiveMemoryWarningNotification, UIApplication.didEnterBackgroundNotification,
            ] {
                NotificationCenter.default.addObserver(self, selector: #selector(releaseOffscreenMemory), name: name, object: nil)
            }
            registerForTraitChanges([
                UITraitUserInterfaceStyle.self, UITraitDisplayScale.self, UITraitAccessibilityContrast.self,
            ]) { (view: TranscriptScrollView, _) in
                view.updatePalette()
            }
            registerForTraitChanges([
                UITraitPreferredContentSizeCategory.self, UITraitLegibilityWeight.self,
            ]) { (view: TranscriptScrollView, _) in
                view.controller.updateStyle()
            }
            installInteractions()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        var scale: CGFloat { max(1, traitCollection.displayScale) }

        // MARK: Lifecycle

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else {
                updateLink?.isEnabled = false
                updateLink = nil
                controller.detach(self)
                return
            }
            updatePalette()
            controller.attach(self)
            updateFrameLink()
        }

        @objc private func releaseOffscreenMemory() {
            let visible = visibleRect
            mounter.releaseOffscreen(keeping: visible)
            for scroller in wideBlocks.values {
                let localVisible = visible.offsetBy(dx: -scroller.frame.minX, dy: -scroller.frame.minY)
                scroller.releaseOffscreenBands(keeping: localVisible)
            }
            for scroller in wideBlockPool { discard(scroller) }
            wideBlockPool.removeAll()
            for button in accessoryPool { button.removeFromSuperview() }
            accessoryPool.removeAll()
        }

        private func updatePalette() {
            let palette = TextPalette.resolve(for: traitCollection)
            self.palette = palette
            mounter.selectionColor = palette.selection
            controller.setPalette(palette)
            mounter.invalidate()
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size != laidOutSize {
                // Rotation, split view and the first layout resize the
                // viewport; the controller re-anchors (rule 3).
                laidOutSize = bounds.size
                matchContentWidth()
                controller.viewportDidChange()
            }
            placeRowsIfNeeded()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            controller.viewportDidChange()
            placeRowsIfNeeded()
        }

        /// The keyboard and the composer change the visible area without
        /// changing the bounds.
        override func adjustedContentInsetDidChange() {
            super.adjustedContentInsetDidChange()
            controller.viewportDidChange()
            setNeedsLayout()
        }

        /// Allow drags that begin on a Copy/Fork button to scroll the
        /// transcript instead of sticking on the button (UIKit's default
        /// returns false for `UIControl`).
        override func touchesShouldCancel(in view: UIView) -> Bool {
            if view is UIButton { return true }
            return super.touchesShouldCancel(in: view)
        }

        // MARK: Insets and keyboard

        @objc private func keyboardWillChangeFrame(_ notification: Notification) {
            guard
                let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
                    as? TimeInterval, duration > 0,
                let curve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt
            else {
                keyboardTransition = nil
                return
            }
            // The curve's raw value is an animation option's curve bits.
            keyboardTransition = KeyboardTransition(
                end: CACurrentMediaTime() + duration, options: UIView.AnimationOptions(rawValue: curve << 16))
        }

        /// The bars, composer and keyboard over the transcript. While the
        /// keyboard moves, insets change with its own animation.
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

        // MARK: TranscriptViewportHost

        var viewport: TranscriptViewport? {
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            return TranscriptViewport(
                size: bounds.size, topInset: adjustedContentInset.top, bottomInset: adjustedContentInset.bottom)
        }

        var viewportTop: CGFloat { contentOffset.y + adjustedContentInset.top }

        func setDocumentHeight(_ height: CGFloat) {
            let size = CGSize(width: bounds.width, height: height)
            if contentSize != size { contentSize = size }
            matchContentWidth()
        }

        private func matchContentWidth() {
            let frame = CGRect(x: 0, y: 0, width: bounds.width, height: contentSize.height)
            if contentView.frame != frame {
                contentView.frame = frame
                rowsView.frame = contentView.bounds
                wideBlocksView.frame = contentView.bounds
            }
        }

        /// Assigning the offset keeps a drag or deceleration going from the
        /// new position; `setContentOffset(_:animated:)` would end it. A
        /// gesture may hold the content past either end; layout may not.
        func setViewportTop(_ top: CGFloat) {
            var y = top - adjustedContentInset.top
            if !isTracking, !isDecelerating {
                let maximum = max(-adjustedContentInset.top, contentSize.height + adjustedContentInset.bottom - bounds.height)
                y = min(max(y, -adjustedContentInset.top), maximum)
            }
            let aligned = (y * scale).rounded() / scale
            guard abs(contentOffset.y - aligned) > 0.01 else { return }
            contentOffset = CGPoint(x: contentOffset.x, y: aligned)
        }

        func setContentVisible(_ visible: Bool) {
            isContentVisible = visible
            contentView.alpha = visible ? 1 : 0
        }

        func setNeedsRowPlacement() {
            mounter.invalidate()
            setNeedsLayout()
        }

        func setNeedsFrameUpdates(_ needed: Bool) {
            needsFrames = needed
            updateFrameLink()
        }

        func setNeedsSelectionDisplay() {
            lastNotifiedSelectionRects = currentSelectionRects()
            selectionDidChange()
        }

        func selectedTextWillChange() {
            contentView.inputDelegate?.textWillChange(contentView)
        }

        func selectedTextDidChange() {
            contentView.inputDelegate?.textDidChange(contentView)
            lastNotifiedSelectionRects = currentSelectionRects()
        }

        private func currentSelectionRects() -> [CGRect] {
            controller.currentSelectionRects(columnX: columnX, scrollX: { wideBlocks[$0]?.scrollX ?? 0 })
        }

        private func notifySelectionGeometryIfChanged() {
            guard controller.selection != nil, !isTracking, !isDecelerating else { return }
            let current = currentSelectionRects()
            guard current != lastNotifiedSelectionRects else { return }
            lastNotifiedSelectionRects = current
            contentView.selectionGeometryDidChange()
        }

        var animatesJumps: Bool { window != nil }

        func stopDeceleration() {
            // Ends a fling where it is unless a finger holds the content.
            guard !isTracking else { return }
            setContentOffset(contentOffset, animated: false)
        }

        private func updateFrameLink() {
            let active = needsFrames && window?.windowScene != nil
            if active, updateLink == nil {
                let link = UIUpdateLink(view: self)
                link.addAction(target: self, selector: #selector(frameDidTick))
                updateLink = link
            }
            updateLink?.isEnabled = active
            updateLink?.requiresContinuousUpdates = active
        }

        @objc private func frameDidTick() {
            controller.frameDidTick()
        }

        // MARK: Rows

        private func placeRowsIfNeeded() {
            guard !controller.isUpdating else {
                setNeedsLayout()
                return
            }
            guard mounter.needsPlacement(visible: visibleRect) else { return }
            placeRows()
        }

        /// The document rect the viewport shows.
        private var visibleRect: CGRect {
            CGRect(x: 0, y: contentOffset.y, width: bounds.width, height: bounds.height)
        }

        private func placeRows() {
            guard let palette, controller.columnWidth > 0 else { return }
            if isContentVisible {
                controller.ensureVisibleRowsReady(in: visibleRect)
            }
            matchContentWidth()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            UIView.performWithoutAnimation {
                mounter.place(
                    controller, visible: visibleRect, documentWidth: bounds.width, palette: palette, scale: scale,
                    colorSpace: colorSpace, showsContent: isContentVisible)
            }
            // Notify UIKit only when the selection's highlight rects actually
            // moved or changed layout, not unconditionally on every scroll placement.
            notifySelectionGeometryIfChanged()
        }

        // MARK: TranscriptRowMounterDelegate

        func showWideBlock(
            rowID: String, body: WideBlockBody, key: RowLayoutKey, origin: CGPoint, drawn: CGRect,
            visible: CGRect, streamed: DrawnBands?
        ) {
            let scroller = wideBlocks[rowID] ?? wideBlockPool.popLast() ?? makeWideBlockScroller()
            if wideBlocks[rowID] == nil {
                wideBlocks[rowID] = scroller
                scroller.isHidden = false
                scroller.onHorizontalScroll = { [weak self] in
                    self?.notifySelectionGeometryIfChanged()
                }
                scroller.onReaderScroll = { [weak self] in self?.wideBlockDidScroll($0) }
            }
            let frame = body.frame.offsetBy(dx: origin.x, dy: origin.y)
            if scroller.frame != frame { scroller.frame = frame }
            guard let palette else { return }
            let localDrawn = drawn.offsetBy(dx: -frame.minX, dy: -frame.minY)
            let localVisible = visible.isNull ? .null : visible.offsetBy(dx: -frame.minX, dy: -frame.minY)
            scroller.show(
                rowID: rowID, offset: controller.wideBlockOffsets[rowID] ?? 0, body: body, key: key,
                palette: palette, scale: scale, colorSpace: colorSpace,
                drawsOffMain: controller.configuration.drawsOffMain, drawn: localDrawn, visible: localVisible,
                streamed: streamed)
        }

        /// UIKit's text gestures take a touch only when the touched view is
        /// `contentView` or above it, not a view inside it (measured on iOS
        /// 27). So a touch in a block lands on `contentView` (all but the
        /// block's scroll bar), and the block's pan listens there instead
        /// (UIKit lets a scroll view's pan sit on another view).
        private func makeWideBlockScroller() -> TranscriptWideBlockScroller {
            let scroller = TranscriptWideBlockScroller()
            wideBlocksView.addSubview(scroller)
            contentView.addGestureRecognizer(scroller.panGestureRecognizer)
            return scroller
        }

        private func discard(_ scroller: TranscriptWideBlockScroller) {
            contentView.removeGestureRecognizer(scroller.panGestureRecognizer)
            scroller.removeFromSuperview()
        }

        /// The reader scrolled a wide block: keep its sideways offset across
        /// remounts (browser `scrollLeft`).
        private func wideBlockDidScroll(_ scroller: TranscriptWideBlockScroller) {
            guard let rowID = scroller.rowID else { return }
            controller.wideBlockOffsets[rowID] = scroller.scrollX
        }

        func showWideBlockSelection(rowID: String, range: Range<Int>?, color: CGColor) {
            wideBlocks[rowID]?.showSelection(range, color: color)
        }

        func removeWideBlock(rowID: String) {
            guard let scroller = wideBlocks.removeValue(forKey: rowID) else { return }
            scroller.resetForReuse()
            scroller.isHidden = true
            if wideBlockPool.count < 8 {
                wideBlockPool.append(scroller)
            } else {
                discard(scroller)
            }
        }

        func showAccessories(rowID: String, accessories: [RowAccessory], origin: CGPoint) {
            var buttons = accessoryButtons[rowID] ?? []
            while buttons.count > accessories.count { recycle(buttons.removeLast()) }
            while buttons.count < accessories.count {
                let action = accessories[buttons.count].action
                let button: TranscriptAccessoryControl
                if let match = accessoryPool.lastIndex(where: { $0.matchesKind(of: action) }) {
                    button = accessoryPool.remove(at: match)
                } else {
                    button = accessoryPool.popLast() ?? TranscriptAccessoryControl()
                }
                if button.superview == nil { contentView.addSubview(button) }
                buttons.append(button)
            }
            for (button, accessory) in zip(buttons, accessories) {
                if case .fork = accessory.action {
                    button.isHidden = forkMenu == nil
                } else {
                    button.isHidden = false
                }
                // A larger touch target around the small symbol.
                let frame = accessory.frame.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -8, dy: -8)
                if button.frame != frame { button.frame = frame }
                button.show(
                    accessory.action,
                    resolveCopy: { [weak self] action in
                        self?.controller.copyText(for: action) ?? ""
                    },
                    forkMenu: { [weak self] turnID in self?.forkMenu?(turnID) })
            }
            accessoryButtons[rowID] = buttons
        }

        func removeAccessories(rowID: String) {
            for button in accessoryButtons.removeValue(forKey: rowID) ?? [] { recycle(button) }
        }

        private func recycle(_ button: TranscriptAccessoryControl) {
            button.resetForReuse()
            button.isHidden = true
            if accessoryPool.count < 16 {
                accessoryPool.append(button)
            } else {
                button.removeFromSuperview()
            }
        }

        // MARK: Positions

        /// The column's left edge in the document.
        var columnX: CGFloat {
            max(0, ((bounds.width - controller.columnWidth) / 2).rounded(.down))
        }

        #if DEBUG
            var mountedRowCount: Int { mounter.mountedRowCount }
        #endif
    }

    /// Takes no touches itself, only through its subviews.
    private final class PassthroughView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let hit = super.hitTest(point, with: event)
            return hit === self ? nil : hit
        }
    }
#endif
