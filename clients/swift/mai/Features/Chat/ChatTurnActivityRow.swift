import SwiftUI

/// The turn's work header. While the turn runs it is a live elapsed timer;
/// once finished it becomes the "Worked for 42s" disclosure that folds and
/// unfolds the turn's activity.
struct ChatTurnActivityRow: View {
    let activity: ChatTurnActivity
    let foldModel: ChatTimelineFoldModel
    let scrollState: ChatScrollState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if activity.isRunning {
                    Text("Working")
                    if let startedAt = activity.startedAt {
                        Text(startedAt, style: .timer)
                            .monospacedDigit()
                    }
                } else {
                    Button {
                        scrollState.noteContentExpansion()
                        foldModel.toggle(activity.sectionID)
                    } label: {
                        HStack(spacing: 6) {
                            Text(activity.title)

                            if activity.hasFailure {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }

                            Image(
                                systemName: activity.isExpanded
                                    ? "chevron.down" : "chevron.right"
                            )
                            .font(.caption2.weight(.semibold))
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        activity.isExpanded
                            ? "Hide agent activity, \(activity.title)"
                            : "Show agent activity, \(activity.title)"
                    )
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Divider()
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}
