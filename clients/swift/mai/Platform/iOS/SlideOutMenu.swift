import SwiftUI

struct SlideOutMenu<Menu: View, Content: View>: View {
    @Binding var isOpen: Bool

    var isEnabled = true
    var preferredWidth: CGFloat = 280

    @ViewBuilder var menu: (_ progress: CGFloat) -> Menu
    @ViewBuilder var content: (_ progress: CGFloat) -> Content

    @State private var xOffset: CGFloat = 0
    @State private var progress: CGFloat = 0
    @State private var hapticTrigger = false
    @State private var dragStartOffset: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            menu(progress)
                .frame(width: preferredWidth)
                .frame(maxHeight: .infinity)
                .accessibilityHidden(!isOpen)

            content(progress)
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
            progress = isOpen ? 1 : 0
        }
        .onChange(of: isOpen) { _, newValue in
            setOpen(newValue, menuWidth: preferredWidth)
        }
        .simultaneousGesture(
            dragGesture(menuWidth: preferredWidth),
            isEnabled: isEnabled
        )
        .sensoryFeedback(.impact(weight: .light), trigger: hapticTrigger)
        .ignoresSafeArea()
    }

    private func dragGesture(menuWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                guard isEnabled else { return }

                if dragStartOffset == nil {
                    guard isHorizontal(value) else { return }
                    dragStartOffset = xOffset
                }

                let proposedOffset = clamp(
                    (dragStartOffset ?? xOffset) + value.translation.width,
                    lower: 0,
                    upper: menuWidth
                )
                xOffset = proposedOffset
                progress = proposedOffset / menuWidth
            }
            .onEnded { value in
                guard isEnabled, dragStartOffset != nil else {
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
        let targetProgress: CGFloat = newValue ? 1 : 0
        let animation: Animation = reduceMotion
            ? .easeOut(duration: 0.15)
            : .interactiveSpring(response: 0.35, dampingFraction: 0.86)

        if (newValue && progress < 1) || (!newValue && progress > 0) {
            hapticTrigger.toggle()
        }

        withAnimation(animation) {
            xOffset = targetOffset
            progress = targetProgress
            isOpen = newValue
        }
    }

    private func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}
