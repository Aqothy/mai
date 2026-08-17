import SwiftUI
import UIKit

/// Shared clipboard feedback for rich Markdown blocks.
struct ChatCopyButton: View {
    let title: String
    let accessibilityHint: String
    let text: String

    @State private var copied = false

    var body: some View {
        Button(
            copied ? "Copied" : title,
            systemImage: copied ? "checkmark" : "square.on.square",
            action: copy
        )
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .accessibilityHint(accessibilityHint)
        .task(id: copied) {
            guard copied else { return }
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            copied = false
        }
    }

    private func copy() {
        UIPasteboard.general.string = text
        copied = true
    }
}
