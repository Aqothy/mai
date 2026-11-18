#if os(iOS)
    import UIKit

    /// Touch on the iOS transcript. UIKit's non-editable text interaction
    /// gives long-press selection, handles, loupe and the edit menu over
    /// `contentView` (PLAN 5); its gestures live on the scroll view, which
    /// UIKit supports. A tap on a finished turn's header expands or
    /// collapses its work, on a link opens it, anywhere else clears the
    /// selection.
    extension TranscriptScrollView {
        func installInteractions() {
            let selection = UITextInteraction(for: .nonEditable)
            selection.textInput = contentView
            addInteraction(selection)
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.cancelsTouchesInView = false
            addGestureRecognizer(tap)
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            let point = recognizer.location(in: contentView)
            if let turnID = controller.expandableTurn(atDocumentY: point.y) {
                controller.toggleExpansion(turnID: turnID)
            } else if let url = controller.link(atDocumentPoint: point, columnX: columnX) {
                UIApplication.shared.open(url)
            } else if controller.selection != nil {
                controller.setSelection(nil)
            }
        }

        /// The selection changed: UIKit redraws its highlight and handles
        /// unless the change came from UIKit itself.
        func selectionDidChange() {
            guard !contentView.isApplyingSystemSelection else { return }
            contentView.selectionGeometryDidChange()
        }
    }
#endif
