#if os(macOS)
    import AppKit

    /// VoiceOver on the Mac (PLAN 7): the rows within a screen of the
    /// viewport, in order, as elements over the document; scrolling brings
    /// the next ones. Subviews (copy and fork buttons, code scrollers) keep
    /// their own elements.
    extension TranscriptDocumentView {
        override func isAccessibilityElement() -> Bool { false }

        override func accessibilityRole() -> NSAccessibility.Role? { .group }

        override func accessibilityLabel() -> String? { "Transcript" }

        override func accessibilityChildren() -> [Any]? {
            guard let window, let clip = enclosingScrollView?.contentView else { return super.accessibilityChildren() }
            let visible = clip.documentVisibleRect
            let rows = controller.accessibleRows(
                minY: visible.minY - visible.height, maxY: visible.maxY + visible.height, columnX: columnX)
            var children: [Any] = rows.map { row in
                let element = TranscriptAccessibilityElement()
                element.setAccessibilityParent(self)
                element.setAccessibilityFrame(window.convertToScreen(convert(row.frame, to: nil)))
                if let turnID = row.expandsTurnID {
                    element.setAccessibilityRole(.disclosureTriangle)
                    element.setAccessibilityLabel(row.text)
                    element.setAccessibilityValue(row.isExpanded ? 1 : 0)
                    element.onPress = { [weak self] in self?.controller.toggleExpansion(turnID: turnID) }
                } else {
                    element.setAccessibilityRole(.staticText)
                    element.setAccessibilityValue(row.text)
                }
                return element
            }
            children += super.accessibilityChildren() ?? []
            return children
        }
    }
#endif
