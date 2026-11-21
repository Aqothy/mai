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
        private var keyboardTransition: KeyboardTransition?

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
            contentView.alpha = 0
            addSubview(contentView)
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardWillChangeFrame(_:)),
                name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) {
                (view: TranscriptScrollView, _) in
                view.updatePalette()
            }
            // Bold Text changes the fonts' weight, not their size.
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
                controller.detach(self)
                return
            }
            if updateLink == nil {
                let link = UIUpdateLink(view: self)
                link.addAction(target: self, selector: #selector(frameDidTick))
                updateLink = link
            }
            updatePalette()
            controller.attach(self)
            updateFrameLink()
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
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mounter.showSelection(controller)
            CATransaction.commit()
            selectionDidChange()
        }

        var animatesJumps: Bool { window != nil }

        func stopDeceleration() {
            // Ends a fling where it is unless a finger holds the content.
            guard !isTracking else { return }
            setContentOffset(contentOffset, animated: false)
        }

        private func updateFrameLink() {
            updateLink?.isEnabled = needsFrames
            updateLink?.requiresContinuousUpdates = needsFrames
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
            guard let palette, controller.columnWidth > 0, !controller.geometry.isEmpty else { return }
            matchContentWidth()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            if isContentVisible { controller.layOutVisibleRows(minY: visibleRect.minY, maxY: visibleRect.maxY) }
            UIView.performWithoutAnimation {
                mounter.place(
                    controller, visible: visibleRect, documentWidth: bounds.width, palette: palette, scale: scale,
                    showsContent: isContentVisible)
            }
            // Rows laid out again move the selection's rects.
            if controller.selection != nil { contentView.selectionGeometryDidChange() }
        }

        // MARK: TranscriptRowMounterDelegate

        func showWideBlock(rowID: String, body: WideBlockBody, key: RowLayoutKey, origin: CGPoint, isVisible: Bool) {
            let scroller = wideBlocks[rowID] ?? wideBlockPool.popLast() ?? TranscriptWideBlockScroller()
            if wideBlocks[rowID] == nil {
                wideBlocks[rowID] = scroller
                contentView.addSubview(scroller)
            }
            let frame = body.frame.offsetBy(dx: origin.x, dy: origin.y)
            if scroller.frame != frame { scroller.frame = frame }
            guard let palette else { return }
            scroller.show(
                rowID: rowID, body: body, key: key, palette: palette, scale: scale,
                drawsOffMain: controller.configuration.drawsOffMain, isVisible: isVisible)
        }

        func showWideBlockSelection(rowID: String, range: Range<Int>?, color: CGColor) {
            wideBlocks[rowID]?.showSelection(range, color: color)
        }

        func removeWideBlock(rowID: String) {
            guard let scroller = wideBlocks.removeValue(forKey: rowID) else { return }
            scroller.removeFromSuperview()
            scroller.resetForReuse()
            if wideBlockPool.count < 8 { wideBlockPool.append(scroller) }
        }

        func showAccessories(rowID: String, accessories: [RowAccessory], origin: CGPoint) {
            var buttons = accessoryButtons[rowID] ?? []
            while buttons.count > accessories.count { recycle(buttons.removeLast()) }
            while buttons.count < accessories.count {
                let button = accessoryPool.popLast() ?? TranscriptAccessoryControl()
                contentView.addSubview(button)
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
                button.show(accessory.action) { [weak self] turnID in self?.forkMenu?(turnID) }
            }
            accessoryButtons[rowID] = buttons
        }

        func removeAccessories(rowID: String) {
            for button in accessoryButtons.removeValue(forKey: rowID) ?? [] { recycle(button) }
        }

        private func recycle(_ button: TranscriptAccessoryControl) {
            button.removeFromSuperview()
            button.resetForReuse()
            if accessoryPool.count < 16 { accessoryPool.append(button) }
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
#endif
