import SwiftUI

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

            content
                .containerRelativeFrame(.horizontal)
                .frame(maxHeight: .infinity)
                .background(.background)
                .clipShape(.rect(cornerRadius: 26 * progress, style: .continuous))
                .overlay {
                    Button {
                        isOpen = false
                    } label: {
                        Color.black.opacity(0.18 * progress)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(.rect)
                    .buttonStyle(.plain)
                    .allowsHitTesting(progress > 0.001)
                    .accessibilityHidden(progress <= 0.001)
                    .accessibilityLabel("Close menu")
                }
                .shadow(
                    color: .black.opacity(0.22 * progress),
                    radius: 24 * progress,
                    x: -8 * progress
                )
                .offset(x: xOffset)
                .accessibilityHidden(isOpen)
        }
        .contentShape(.rect)
        .onAppear {
            xOffset = isOpen ? preferredWidth : 0
        }
        .onChange(of: isOpen) { _, newValue in
            setOpen(newValue, menuWidth: preferredWidth)
        }
        .simultaneousGesture(dragGesture(menuWidth: preferredWidth))
        .sensoryFeedback(.impact(weight: .light), trigger: hapticTrigger)
        .ignoresSafeArea()
    }

    private func dragGesture(menuWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                if dragStartOffset == nil {
                    guard isHorizontal(value) else { return }
                    dragStartOffset = xOffset
                }

                xOffset = clamp(
                    (dragStartOffset ?? xOffset) + value.translation.width,
                    lower: 0,
                    upper: menuWidth
                )
            }
            .onEnded { value in
                guard dragStartOffset != nil else {
                    dragStartOffset = nil
                    return
                }

                let predictedOffset = clamp(
                    xOffset
                        + value.predictedEndTranslation.width
                        - value.translation.width,
                    lower: 0,
                    upper: menuWidth
                )
                dragStartOffset = nil
                setOpen(predictedOffset > menuWidth / 2, menuWidth: menuWidth)
            }
    }

    private func isHorizontal(_ value: DragGesture.Value) -> Bool {
        return abs(value.translation.width) > abs(value.translation.height)
    }

    private func setOpen(_ newValue: Bool, menuWidth: CGFloat) {
        let targetOffset = newValue ? menuWidth : 0
        let animation: Animation = reduceMotion
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
