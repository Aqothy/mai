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
            // A right-click outside the selection selects the word under it,
            // as text views do.
            if let position = textPosition(at: point), !isSelected(position) {
                controller.setSelection(controller.wordRange(around: position))
            }
            guard controller.hasValidSelection else { return nil }
            // Targets are explicit: a right-click over a code block's scroller
            // reaches here without making this view first responder.
            let menu = NSMenu()
            menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "").target = self
            if onComment != nil {
                menu.addItem(withTitle: "Comment…", action: #selector(comment(_:)), keyEquivalent: "").target = self
            }
            return menu
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
            } else if row.kind.isSelectable,
                layout.content.textSegments.contains(where: { segment in
                    (segment.hitRect ?? CGRect(origin: segment.origin, size: segment.layout.size)).contains(local)
                })
            {
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
    }

    extension TranscriptDocumentView: NSMenuItemValidation {
        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            switch menuItem.action {
            case #selector(copy(_:)), #selector(comment(_:)):
                controller.hasValidSelection
            case #selector(selectAll(_:)):
                !controller.rows.isEmpty
            default:
                true
            }
        }
    }
#endif
