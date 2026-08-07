import SwiftUI

enum ThreadRowIndicatorStatus: Equatable {
    case needsInput
    case working
    case failed
    case interrupted
    case done
}

struct ThreadRowStatusView: View {
    let status: ThreadRowIndicatorStatus?

    var body: some View {
        switch status {
        case .needsInput:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Needs input")
        case .working:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Agent working")
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Failed")
        case .interrupted:
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Interrupted")
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.blue)
                .accessibilityLabel("Agent done")
        case nil:
            EmptyView()
        }
    }
}
