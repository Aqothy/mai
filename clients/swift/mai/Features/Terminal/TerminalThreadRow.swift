import SwiftUI

/// One terminal row in the Threads list. Receives only the equatable summary
/// it renders; terminal output never reaches this view.
struct TerminalThreadRow: View {
    let summary: TerminalSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(summary.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                ThreadRowTimestampText(updatedAt: summary.updatedAt)
            }

            HStack(spacing: 6) {
                if let subtitle = summary.displaySubtitle {
                    HStack(spacing: 3) {
                        if subtitle == summary.workingDirectoryName {
                            Image(systemName: "folder")
                        }
                        Text(subtitle)
                    }
                }

                Spacer(minLength: 8)

                ThreadRowStatusView(status: summary.rowIndicatorStatus)
            }
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = ["Terminal", summary.displayTitle]
        if let statusLabel = summary.statusLabel {
            parts.append(statusLabel)
        }
        return parts.joined(separator: ", ")
    }
}
