import SwiftUI

struct ThreadRow: View {
    let thread: ThreadListEntry

    var body: some View {
        HStack {
            Text(thread.title)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if thread.hasPendingApprovals {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Approval required")
            } else if thread.latestTurn?.turnState == .running {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Agent working")
            } else if thread.latestTurn?.turnState == .error || thread.session?.sessionStatus == .error {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Failed")
            } else if thread.latestTurn?.turnState == .interrupted {
                Image(systemName: "stop.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Interrupted")
            } else if thread.latestTurn?.turnState == .completed {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Completed")
            }
        }
    }
}

#if DEBUG
#Preview("Thread Row") {
    ThreadRow(thread: PreviewData.threads[0])
        .padding()
}
#endif
