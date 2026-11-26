#if os(macOS)
    import AppKit

    /// Selection on the Mac (PLAN 5): mouse down sets the anchor, dragging
    /// extends it (by words after a double-click, by paragraphs after a
    /// triple-click) and scrolls at the edges, shift-click extends; ⌘C, ⌘A
    /// and the context menu's Copy and Comment…; links open on a click
    /// without a drag. Positions come from the controller, so a selection
    /// spans rows, code, tables and messages.
    extension TranscriptDocumentView {
        private enum Granularity {
            case character, word, paragraph
        }

        override var acceptsFirstResponder: Bool { true }

        override func becomeFirstResponder() -> Bool {
            defer { updateSelectionColor() }
            return super.becomeFirstResponder()
        }

        override func resignFirstResponder() -> Bool {
            defer { updateSelectionColor() }
            return super.resignFirstResponder()
        }

        @objc func windowKeyStateDidChange() {
            updateSelectionColor()
        }

        /// The highlight is the accent color while this view takes keys in
        /// the key window, gray otherwise (as `NSTextView`).
        func updateSelectionColor() {
            guard let palette else { return }
            let isActive = window?.isKeyWindow == true && window?.firstResponder === self
            let color = isActive ? palette.selection : palette.inactiveSelection
            guard color != mounter.selectionColor else { return }
            mounter.selectionColor = color
            setNeedsSelectionDisplay()
        }

        // MARK: Mouse

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            let point = convert(event.locationInWindow, from: nil)
            // A finished turn's header expands and collapses its work.
            if let turnID = controller.expandableTurn(atDocumentPoint: point, columnX: columnX) {
                controller.toggleExpansion(turnID: turnID)
                return
            }
            guard let position = textPosition(at: point) else {
                controller.setSelection(nil)
                return
            }
            let granularity: Granularity =
                switch event.clickCount {
                case 2: .word
                case 3...: .paragraph
                default: .character
                }
            // The fixed end of the selection: a caret, word or paragraph.
            var anchor = TranscriptSelection(caret: position)
            if granularity == .word, let word = controller.wordRange(around: position) { anchor = word }
            if granularity == .paragraph, let paragraph = controller.paragraphRange(around: position) {
                anchor = paragraph
            }
            if event.modifierFlags.contains(.shift), let current = controller.selection {
                anchor = TranscriptSelection(caret: current.anchor)
                extend(anchor, granularity: granularity, to: point)
            } else if granularity != .character {
                controller.setSelection(anchor)
            }
            trackMouse(from: event, anchor: anchor, granularity: granularity)
        }

        /// Follows the drag until the button goes up, in AppKit's event
        /// tracking mode (layout results and the display link keep running
        /// in it). Periodic events keep scrolling while the pointer rests
        /// beyond an edge.
        private func trackMouse(from down: NSEvent, anchor: TranscriptSelection, granularity: Granularity) {
            guard let window else { return }
            var last = down
            var dragged = false
            NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
            defer { NSEvent.stopPeriodicEvents() }
            while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
                switch event.type {
                case .leftMouseDragged:
                    last = event
                    let moved = hypot(
                        event.locationInWindow.x - down.locationInWindow.x,
                        event.locationInWindow.y - down.locationInWindow.y)
                    if !dragged, moved < 3 { continue }
                    dragged = true
                    _ = autoscroll(with: event)
                    extend(anchor, granularity: granularity, to: convert(event.locationInWindow, from: nil))
                case .periodic:
                    guard dragged, autoscroll(with: last) else { continue }
                    extend(anchor, granularity: granularity, to: convert(last.locationInWindow, from: nil))
                default:
                    if !dragged, granularity == .character, !down.modifierFlags.contains(.shift) {
                        controller.setSelection(nil)
                        let point = convert(event.locationInWindow, from: nil)
                        if let url = controller.link(atDocumentPoint: point, columnX: columnX, scrollX: wideScrollX) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    return
                }
            }
        }

        /// Extends the selection from `anchor` to the text at `point`, by
        /// whole words or paragraphs when the drag began with a double or
        /// triple click.
        private func extend(_ anchor: TranscriptSelection, granularity: Granularity, to point: CGPoint) {
            guard let position = textPosition(at: point) else { return }
            var focus = position
            var fixed = anchor.anchor
            let unit: TranscriptSelection? =
                switch granularity {
                case .character: nil
                case .word: controller.wordRange(around: position)
                case .paragraph: controller.paragraphRange(around: position)
                }
            let anchorStart = controller.isBefore(anchor.anchor, anchor.focus) == false ? anchor.focus : anchor.anchor
            let anchorEnd = anchorStart == anchor.anchor ? anchor.focus : anchor.anchor
            if let unit {
                if controller.isBefore(position, anchorStart) == true {
                    fixed = anchorEnd
                    focus = unit.anchor
                } else {
                    fixed = anchorStart
                    focus = unit.focus
                }
            }
            let selection = TranscriptSelection(anchor: fixed, focus: focus)
            controller.setSelection(selection.isEmpty && granularity == .character ? nil : selection)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let point = convert(event.locationInWindow, from: nil)
            let linkURL = controller.link(atDocumentPoint: point, columnX: columnX, scrollX: wideScrollX)
            // Strict hit-test: a right-click in the margin or over chrome
            // never snaps to and selects text in an adjacent row.
            let hit = controller.strictTextPosition(atDocumentPoint: point, columnX: columnX, scrollX: wideScrollX)
            if let hit, !isSelected(hit), !isPointNearSelection(point) {
                controller.setSelection(controller.wordRange(around: hit))
            }
            let hasSelection = controller.hasValidSelection && (hit != nil || linkURL == nil && isPointNearSelection(point))
            guard linkURL != nil || hasSelection else { return nil }
            // Targets are explicit: a right-click over a code block's scroller
            // reaches here without making this view first responder.
            let menu = NSMenu()
            if let linkURL {
                let openAction = TranscriptMenuAction { NSWorkspace.shared.open(linkURL) }
                let openItem = NSMenuItem(title: "Open Link", action: #selector(TranscriptMenuAction.run(_:)), keyEquivalent: "")
                openItem.target = openAction
                openItem.representedObject = openAction
                menu.addItem(openItem)

                let copyLinkAction = TranscriptMenuAction {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(linkURL.absoluteString, forType: .string)
                }
                let copyLinkItem = NSMenuItem(
                    title: "Copy Link", action: #selector(TranscriptMenuAction.run(_:)), keyEquivalent: "")
                copyLinkItem.target = copyLinkAction
                copyLinkItem.representedObject = copyLinkAction
                menu.addItem(copyLinkItem)
                if hasSelection { menu.addItem(.separator()) }
            }
            if hasSelection {
                let text = controller.selectedText()
                let lookUpItem = NSMenuItem(title: "Look Up", action: #selector(lookUp(_:)), keyEquivalent: "")
                lookUpItem.target = self
                menu.addItem(lookUpItem)

                let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
                copyItem.target = self
                menu.addItem(copyItem)
                if onComment != nil {
                    let commentItem = NSMenuItem(title: "Comment…", action: #selector(comment(_:)), keyEquivalent: "")
                    commentItem.target = self
                    menu.addItem(commentItem)
                }
                menu.addItem(.separator())
                let sharePicker = NSSharingServicePicker(items: [text])
                menu.addItem(sharePicker.standardShareMenuItem)
            }
            return menu
        }

        /// Force-Touch / three-finger tap / ⌃⌘D Look Up over a word or the
        /// active selection.
        override func quickLook(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if let hit = controller.strictTextPosition(atDocumentPoint: point, columnX: columnX, scrollX: wideScrollX) {
                if !isSelected(hit), let word = controller.wordRange(around: hit) {
                    let text = controller.text(from: word.anchor, to: word.focus)
                    guard !text.isEmpty else { return }
                    let anchor =
                        controller.selectionRects(from: word.anchor, to: word.focus, columnX: columnX, scrollX: wideScrollX)
                        .first.map { NSPoint(x: $0.minX, y: $0.maxY) } ?? point
                    showDefinition(for: NSAttributedString(string: text), at: anchor)
                    return
                }
            }
            lookUp(nil)
        }

        // MARK: Keyboard navigation

        override func keyDown(with event: NSEvent) {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !modifiers.contains(.command), !modifiers.contains(.control), !modifiers.contains(.option),
                event.charactersIgnoringModifiers == " "
            {
                scrollBy(deltaY: pageScrollDistance * (modifiers.contains(.shift) ? -1 : 1))
                return
            }
            interpretKeyEvents([event])
        }

        override func moveUp(_ sender: Any?) { scrollBy(deltaY: -40) }
        override func moveDown(_ sender: Any?) { scrollBy(deltaY: 40) }
        override func pageUp(_ sender: Any?) { scrollBy(deltaY: -pageScrollDistance) }
        override func pageDown(_ sender: Any?) { scrollBy(deltaY: pageScrollDistance) }
        override func scrollPageUp(_ sender: Any?) { scrollBy(deltaY: -pageScrollDistance) }
        override func scrollPageDown(_ sender: Any?) { scrollBy(deltaY: pageScrollDistance) }
        override func scrollToBeginningOfDocument(_ sender: Any?) { scrollToTop() }
        override func scrollToEndOfDocument(_ sender: Any?) { controller.jumpToEnd(animated: false) }
        override func moveToBeginningOfDocument(_ sender: Any?) { scrollToTop() }
        override func moveToEndOfDocument(_ sender: Any?) { controller.jumpToEnd(animated: false) }

        override func cancelOperation(_ sender: Any?) {
            if controller.selection != nil {
                controller.setSelection(nil)
            } else {
                nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender)
            }
        }

        private var pageScrollDistance: CGFloat {
            let visible = controller.lastViewport?.visibleHeight ?? enclosingScrollView?.contentView.bounds.height ?? 400
            return max(40, (visible * 0.9).rounded(.down))
        }

        private func scrollBy(deltaY: CGFloat) {
            guard let scrollView = enclosingScrollView else { return }
            let clip = scrollView.contentView
            var proposed = clip.bounds
            proposed.origin.y += deltaY
            let origin = clip.constrainBoundsRect(proposed).origin
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
        }

        private func scrollToTop() {
            guard let scrollView = enclosingScrollView else { return }
            let clip = scrollView.contentView
            let origin = clip.constrainBoundsRect(
                NSRect(origin: NSPoint(x: 0, y: -clip.contentInsets.top), size: clip.bounds.size)
            ).origin
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
        }

        // MARK: Cursor

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            guard trackingAreas.isEmpty else { return }
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                    owner: self))
        }

        override func cursorUpdate(with event: NSEvent) {
            updateCursor(at: convert(event.locationInWindow, from: nil))
        }

        override func mouseMoved(with event: NSEvent) {
            updateCursor(at: convert(event.locationInWindow, from: nil))
        }

        /// A pointing hand over links, an I-beam over selectable text. One
        /// geometry and layout lookup per pointer move.
        private func updateCursor(at point: CGPoint) {
            let geometry = controller.geometry
            guard !geometry.isEmpty, point.y >= 0, let index = geometry.index(at: point.y) else {
                NSCursor.arrow.set()
                return
            }
            let row = controller.rows[index]
            guard let layout = controller.layouts[row.id] else {
                NSCursor.arrow.set()
                return
            }
            var local = CGPoint(x: point.x - columnX, y: point.y - geometry.offset(at: index))
            if let body = layout.content.wideBody, local.y >= body.frame.minY {
                guard local.x >= body.frame.minX, local.x <= body.frame.maxX else {
                    NSCursor.arrow.set()
                    return
                }
                local.x += wideBlocks[row.id]?.scrollX ?? 0
            }
            if layout.content.link(at: local) != nil {
                NSCursor.pointingHand.set()
            } else if row.kind.isSelectable, layout.content.containsSelectablePoint(local) {
                NSCursor.iBeam.set()
            } else {
                NSCursor.arrow.set()
            }
        }

        // MARK: Commands

        @objc func copy(_ sender: Any?) {
            let text = controller.selectedText()
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        @objc override func selectAll(_ sender: Any?) {
            controller.selectAll()
        }

        @objc func comment(_ sender: Any?) {
            let quote = controller.selectedText()
            guard !quote.isEmpty else { return }
            let target = controller.selectionCommentTarget()
            onComment?(quote, target.messageID, target.role)
        }

        @objc func lookUp(_ sender: Any?) {
            let text = controller.selectedText()
            guard !text.isEmpty else { return }
            let rect = selectionAnchorRect
            let origin = rect.isNull ? NSPoint(x: columnX, y: visibleRect.midY) : NSPoint(x: rect.minX, y: rect.maxY)
            showDefinition(for: NSAttributedString(string: text), at: origin)
        }

        /// Exposes selected text to macOS Services (including legacy
        /// `"NSStringPboardType"` checked by AppKit Services dispatch).
        override func validRequestor(
            forSendType sendType: NSPasteboard.PasteboardType?,
            returnType: NSPasteboard.PasteboardType?
        ) -> Any? {
            if returnType == nil,
                let sendType,
                sendType == .string || sendType == Self.legacyStringPboardType,
                controller.hasValidSelection
            {
                return self
            }
            return super.validRequestor(forSendType: sendType, returnType: returnType)
        }

        static let legacyStringPboardType = NSPasteboard.PasteboardType("NSStringPboardType")

        // MARK: Positions

        /// The column's left edge in the document.
        var columnX: CGFloat {
            max(0, ((bounds.width - controller.columnWidth) / 2).rounded(.down))
        }

        private func wideScrollX(_ rowID: String) -> CGFloat {
            wideBlocks[rowID]?.scrollX ?? 0
        }

        private func textPosition(at point: CGPoint) -> TextPosition? {
            controller.textPosition(atDocumentPoint: point, columnX: columnX, scrollX: wideScrollX)
        }

        private func isSelected(_ position: TextPosition) -> Bool {
            guard let selection = controller.selection, !selection.isEmpty,
                let anchorFirst = controller.isBefore(selection.anchor, selection.focus)
            else { return false }
            let start = anchorFirst ? selection.anchor : selection.focus
            let end = anchorFirst ? selection.focus : selection.anchor
            return controller.isBefore(position, start) == false && controller.isBefore(position, end) == true
        }

        /// True when `point` falls inside any current selection highlight rect
        /// (also accepts AppKit's synthetic `showContextMenuForSelection` event
        /// centered on `selectionAnchorRect`).
        private func isPointNearSelection(_ point: CGPoint) -> Bool {
            currentSelectionRects().contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
        }

        func currentSelectionRects() -> [CGRect] {
            guard let selection = controller.selection, !selection.isEmpty,
                let anchorFirst = controller.isBefore(selection.anchor, selection.focus)
            else { return [] }
            let start = anchorFirst ? selection.anchor : selection.focus
            let end = anchorFirst ? selection.focus : selection.anchor
            return controller.selectionRects(from: start, to: end, columnX: columnX, scrollX: wideScrollX)
        }
    }

    extension TranscriptDocumentView: NSViewContentSelectionInfo {
        var selectionAnchorRect: NSRect {
            currentSelectionRects().first ?? .null
        }
    }

    extension TranscriptDocumentView: NSServicesMenuRequestor {
        func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
            guard types.contains(.string) || types.contains(Self.legacyStringPboardType) else { return false }
            let text = controller.selectedText()
            guard !text.isEmpty else { return false }
            pboard.declareTypes([.string], owner: nil)
            return pboard.setString(text, forType: .string)
        }
    }

    extension TranscriptDocumentView: NSMenuItemValidation {
        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            switch menuItem.action {
            case #selector(copy(_:)), #selector(comment(_:)), #selector(lookUp(_:)):
                controller.hasValidSelection
            case #selector(selectAll(_:)):
                !controller.rows.isEmpty
            default:
                true
            }
        }
    }
#endif
