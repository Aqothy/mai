#if os(iOS)
    import UIKit

    /// VoiceOver on iOS (PLAN 7): the rows within a screen of the viewport,
    /// in order, as elements over the document; scrolling brings the next
    /// ones. Elements are kept per row, so VoiceOver's focus survives the
    /// list being asked for again.
    extension TranscriptTextInputView {
        override var accessibilityElements: [Any]? {
            get { accessibleRowElements() }
            set {}
        }

        private func accessibleRowElements() -> [Any] {
            guard let controller, let scrollView = superview as? UIScrollView else { return [] }
            let visible = CGRect(origin: scrollView.contentOffset, size: scrollView.bounds.size)
            let rows = controller.accessibleRows(
                minY: visible.minY - visible.height, maxY: visible.maxY + visible.height, columnX: columnX())
            var ordered: [(y: CGFloat, element: Any)] = []
            var kept: [String: TranscriptAccessibilityRow] = [:]
            for row in rows {
                let element = rowElements[row.id] ?? TranscriptAccessibilityRow(accessibilityContainer: self)
                element.accessibilityFrameInContainerSpace = row.frame
                element.accessibilityLabel = row.text
                if let turnID = row.expandsTurnID {
                    element.accessibilityTraits = .button
                    element.accessibilityValue = row.isExpanded ? "Expanded" : "Collapsed"
                    element.onActivate = { [weak controller] in controller?.toggleExpansion(turnID: turnID) }
                } else {
                    element.accessibilityTraits = .staticText
                    element.accessibilityValue = nil
                    element.onActivate = nil
                }
                kept[row.id] = element
                ordered.append((row.frame.minY, element))
            }
            rowElements = kept
            // Controls on the rows (copy, fork), in reading order with the
            // rows. A row's element already reads a wide block's whole text.
            for view in subviews where !view.isHidden && view is UIControl {
                ordered.append((view.frame.minY, view))
            }
            return ordered.sorted { $0.y < $1.y }.map(\.element)
        }
    }
#endif
