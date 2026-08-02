import SwiftUI

struct ThreadRowStatusView: View {
    let hasPendingApprovals: Bool
    let turnState: MaidTurnState?
    let sessionStatus: MaidSessionStatus?

    var body: some View {
        if hasPendingApprovals {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Approval required")
        } else if turnState == .running {
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Agent working")
        } else if turnState == .error || sessionStatus == .error {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Failed")
        } else if turnState == .interrupted {
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Interrupted")
        }
    }
}
