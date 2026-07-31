import SwiftUI

struct ThreadRowStatusView: View {
    let thread: ThreadListEntry

    var body: some View {
        if thread.hasPendingApprovals {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Approval required")
        } else if thread.latestTurn?.turnState == .running {
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Agent working")
        } else if thread.latestTurn?.turnState == .error
            || thread.session?.sessionStatus == .error {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Failed")
        } else if thread.latestTurn?.turnState == .interrupted {
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Interrupted")
        }
    }
}
