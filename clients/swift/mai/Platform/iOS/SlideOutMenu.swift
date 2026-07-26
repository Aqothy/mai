import SwiftUI
import UIKit

struct SlideOutMenu<Menu: View, Content: View>: View {
    @Binding var isOpen: Bool

    var preferredWidth: CGFloat = 280

    @ViewBuilder var menu: Menu
    @ViewBuilder var content: Content

    @State private var xOffset: CGFloat = 0
    @State private var hapticTrigger = false
    @State private var dragStartOffset: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Open-ness in 0...1. Derived from xOffset rather than tracked alongside
    /// it, so the two can never disagree mid-drag or mid-animation.
    private var progress: CGFloat {
        preferredWidth > 0 ? xOffset / preferredWidth : 0
    }

    var body: some View {
        ZStack(alignment: .leading) {
            menu
                .frame(width: preferredWidth)
                .frame(maxHeight: .infinity)
                .accessibilityHidden(!isOpen)

            SlideOutMenuContentView(
                content: content,
                progress: progress,
                xOffset: xOffset
            ) {
                setOpen(false, menuWidth: preferredWidth)
            }
        }
        .contentShape(.rect)
        .onAppear {
            xOffset = isOpen ? preferredWidth : 0
        }
        .onChange(of: isOpen) { _, newValue in
            setOpen(newValue, menuWidth: preferredWidth)
        }
        .gesture(
            HorizontalPanGesture(
                canBegin: { velocityX in
                    if xOffset <= 0 {
                        return velocityX > 0
                    }
                    if xOffset >= preferredWidth {
                        return velocityX < 0
                    }
                    return true
                },
                onBegan: {
                    dragStartOffset = xOffset
                },
                onChanged: { translationX in
                    xOffset = clamp(
                        (dragStartOffset ?? xOffset) + translationX,
                        lower: 0,
                        upper: preferredWidth
                    )
                },
                onEnded: { velocityX in
                    let projectedOffset = clamp(
                        xOffset + velocityX * 0.2,
                        lower: 0,
                        upper: preferredWidth
                    )
                    dragStartOffset = nil
                    setOpen(
                        projectedOffset > preferredWidth / 2,
                        menuWidth: preferredWidth
                    )
                },
                onCancelled: {
                    dragStartOffset = nil
                    setOpen(
                        xOffset > preferredWidth / 2,
                        menuWidth: preferredWidth
                    )
                }
            )
        )
        .sensoryFeedback(.impact(weight: .light), trigger: hapticTrigger)
        .ignoresSafeArea(.container, edges: .vertical)
    }

    private func setOpen(_ newValue: Bool, menuWidth: CGFloat) {
        let targetOffset = newValue ? menuWidth : 0
        let animation: Animation =
            reduceMotion
            ? .easeOut(duration: 0.15)
            : .interactiveSpring(response: 0.35, dampingFraction: 0.86)

        if xOffset != targetOffset {
            hapticTrigger.toggle()
        }

        withAnimation(animation) {
            xOffset = targetOffset
            isOpen = newValue
        }
    }

    private func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}

private struct HorizontalPanGesture: UIGestureRecognizerRepresentable {
    var canBegin: (CGFloat) -> Bool
    var onBegan: () -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat) -> Void
    var onCancelled: () -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var gesture: HorizontalPanGesture

        init(gesture: HorizontalPanGesture) {
            self.gesture = gesture
        }

        func gestureRecognizerShouldBegin(
            _ gestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard let panGesture = gestureRecognizer as? UIPanGestureRecognizer,
                let view = panGesture.view
            else {
                return false
            }

            let velocity = panGesture.velocity(in: view)
            return abs(velocity.x) > abs(velocity.y)
                && gesture.canBegin(velocity.x)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // A vertical pan fails our direction check, then scrolling proceeds.
            // A horizontal pan wins first so both views cannot move together.
            otherGestureRecognizer.view is UIScrollView
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(gesture: self)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }

    func updateUIGestureRecognizer(
        _ recognizer: UIPanGestureRecognizer,
        context: Context
    ) {
        context.coordinator.gesture = self
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: UIPanGestureRecognizer,
        context: Context
    ) {
        switch recognizer.state {
        case .began:
            context.coordinator.gesture.onBegan()
        case .changed:
            let translationX = recognizer.translation(in: recognizer.view).x
            context.coordinator.gesture.onChanged(translationX)
        case .ended:
            let velocityX = recognizer.velocity(in: recognizer.view).x
            context.coordinator.gesture.onEnded(velocityX)
        case .cancelled, .failed:
            context.coordinator.gesture.onCancelled()
        case .possible:
            break
        @unknown default:
            context.coordinator.gesture.onCancelled()
        }
    }
}
