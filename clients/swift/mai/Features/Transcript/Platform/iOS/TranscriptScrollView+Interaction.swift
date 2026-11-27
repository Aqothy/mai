#if os(iOS)
    import UIKit

    /// Ignores taps on native accessory controls without conforming
    /// `TranscriptScrollView` itself to `UIGestureRecognizerDelegate` (which
    /// also intercepts `UIScrollView.panGestureRecognizer` and blocks vertical
    /// scrolling that starts on Copy/Fork buttons).
    final class TranscriptTapGestureDelegate: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            !(touch.view is UIControl)
        }
    }

    /// Latches horizontal pans that start inside a scrollable wide code block
    /// or table while yielding immediately to vertical drags and
    /// `UITextInteraction` long-presses.
    final class TranscriptWideBlockPanDelegate: NSObject, UIGestureRecognizerDelegate {
        weak var scrollView: TranscriptScrollView?

        init(scrollView: TranscriptScrollView) {
            self.scrollView = scrollView
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Never steal touches from UIKit selection grab handles or
            // accessory controls (Copy/Fork buttons).
            touch.view === scrollView?.contentView || touch.view === scrollView
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let scrollView else { return false }
            let velocity = pan.velocity(in: scrollView)
            let translation = pan.translation(in: scrollView)
            let motion = abs(velocity.x) > 10 || abs(velocity.y) > 10 ? velocity : translation
            guard abs(motion.x) > abs(motion.y) * 1.25, abs(motion.x) > 1 else { return false }
            let point = pan.location(in: scrollView.contentView)
            return scrollView.scrollableWideBlock(at: point) != nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }

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
            selection.delegate = contentView
            addInteraction(selection)
            let panDelegate = TranscriptWideBlockPanDelegate(scrollView: self)
            let horizontalPan = UIPanGestureRecognizer(target: self, action: #selector(handleWideBlockPan(_:)))
            horizontalPan.delegate = panDelegate
            horizontalPan.cancelsTouchesInView = false
            wideBlockPanDelegate = panDelegate
            wideBlockPan = horizontalPan
            addGestureRecognizer(horizontalPan)
            panGestureRecognizer.require(toFail: horizontalPan)
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = tapDelegate
            for gesture in selection.gesturesForFailureRequirements {
                tap.require(toFail: gesture)
            }
            addGestureRecognizer(tap)
        }

        func scrollableWideBlock(at contentPoint: CGPoint) -> TranscriptWideBlockScroller? {
            for scroller in wideBlocks.values
            where !scroller.isHidden && scroller.maxScrollX > 0.5 && scroller.frame.contains(contentPoint) {
                return scroller
            }
            return nil
        }

        @objc private func handleWideBlockPan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                stopWideBlockDeceleration()
                let point = recognizer.location(in: contentView)
                guard let scroller = scrollableWideBlock(at: point) else { return }
                activeWidePan = (scroller, scroller.scrollX)
                scroller.flashScrollIndicators()
            case .changed:
                guard let active = activeWidePan else { return }
                let dx = recognizer.translation(in: self).x
                active.scroller.pan(toX: active.startX - dx)
            case .ended, .cancelled, .failed:
                guard let active = activeWidePan else { return }
                activeWidePan = nil
                let vx = -recognizer.velocity(in: self).x
                if abs(vx) > 40 {
                    wideDecel = (active.scroller, vx, CACurrentMediaTime())
                    updateFrameLink()
                }
            default:
                break
            }
        }

        func stepWideBlockDeceleration() {
            guard var decel = wideDecel else { return }
            let now = CACurrentMediaTime()
            let dt = min(0.05, max(0.001, now - decel.lastTime))
            let nextX = decel.scroller.scrollX + decel.velocity * dt
            decel.scroller.pan(toX: nextX)
            // Apple's standard `UIScrollView.DecelerationRate.normal` (0.998 per ms).
            decel.velocity *= pow(0.998, dt * 1000)
            decel.lastTime = now
            if abs(decel.velocity) < 15 || nextX <= 0 || nextX >= decel.scroller.maxScrollX {
                stopWideBlockDeceleration()
            } else {
                wideDecel = decel
            }
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            let point = recognizer.location(in: contentView)
            if let turnID = controller.expandableTurn(atDocumentPoint: point, columnX: columnX) {
                controller.toggleExpansion(turnID: turnID)
            } else if let url = controller.link(
                atDocumentPoint: point, columnX: columnX, scrollX: { wideBlocks[$0]?.scrollX ?? 0 })
            {
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
