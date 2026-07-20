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
    @GestureState private var dragTranslation: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let displayedOffset = clamp(
            xOffset + dragTranslation,
            lower: 0,
            upper: preferredWidth
        )
        let displayedProgress = dragTranslation == 0
            ? progress
            : displayedOffset / preferredWidth

        ZStack(alignment: .leading) {
            menu(displayedProgress)
                .frame(width: preferredWidth)
                .frame(maxHeight: .infinity)
                .accessibilityHidden(!isOpen)

            content(displayedProgress)
                .containerRelativeFrame(.horizontal)
                .frame(maxHeight: .infinity)
                .background(.background)
                .clipShape(.rect(cornerRadius: 26 * displayedProgress, style: .continuous))
                .overlay {
                    Button {
                        isOpen = false
                    } label: {
                        Color.black.opacity(0.18 * displayedProgress)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(.rect)
                    .buttonStyle(.plain)
                    .allowsHitTesting(displayedProgress > 0.001)
                    .accessibilityHidden(displayedProgress <= 0.001)
                    .accessibilityLabel("Close menu")
                }
                .shadow(
                    color: .black.opacity(0.22 * displayedProgress),
                    radius: 24 * displayedProgress,
                    x: -8 * displayedProgress
                )
                .offset(x: displayedOffset)
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
        .gesture(dragGesture(menuWidth: preferredWidth))
        .sensoryFeedback(.impact(weight: .light), trigger: hapticTrigger)
        .ignoresSafeArea()
    }

    private func dragGesture(menuWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .updating($dragTranslation) { value, translation, _ in
                guard canHandle(value) else { return }

                let baseOffset = isOpen ? menuWidth : 0
                let proposedOffset = clamp(
                    baseOffset + value.translation.width,
                    lower: 0,
                    upper: menuWidth
                )
                translation = proposedOffset - baseOffset
            }
            .onEnded { value in
                guard canHandle(value) else { return }

                let baseOffset = isOpen ? menuWidth : 0
                let predictedOffset = clamp(
                    baseOffset + value.predictedEndTranslation.width,
                    lower: 0,
                    upper: menuWidth
                )
                setOpen(predictedOffset > menuWidth / 2, menuWidth: menuWidth)
            }
    }

    private func canHandle(_ value: DragGesture.Value) -> Bool {
        guard isEnabled else { return false }

        let isHorizontal = abs(value.translation.width) > abs(value.translation.height)
        return isHorizontal
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
