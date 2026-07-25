import SwiftUI

struct DraftPromptEditor: View {
    @Binding var text: String

    let isEnabled: Bool
    let focusID: String?
    let canSend: Bool
    let send: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("Ask mai to build, explain, or fix something…")
                    .foregroundStyle(.tertiary)
                    .padding()
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .focused($isFocused)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120)
                .padding(.horizontal)
                .disabled(!isEnabled)
                .accessibilityLabel("Prompt")
        }
        #if os(macOS)
        .onKeyPress(phases: .down) { keyPress in
            guard keyPress.key == .return,
                  !keyPress.modifiers.contains(.shift),
                  canSend else {
                return .ignored
            }
            send()
            return .handled
        }
        #endif
        .onChange(of: focusID, initial: true) { _, focusID in
            if focusID != nil {
                isFocused = true
            }
        }
    }
}
