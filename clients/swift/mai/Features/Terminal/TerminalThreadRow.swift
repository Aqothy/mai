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

                TimelineView(.everyMinute) { context in
                    Text(updatedAtText(now: context.date))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 6) {
                if let workingDirectoryName = summary.workingDirectoryName {
                    HStack(spacing: 3) {
                        Image(systemName: "folder")
                        Text(workingDirectoryName)
                    }
                }

                Spacer(minLength: 8)

                if let statusLabel = summary.statusLabel {
                    Text(statusLabel)
                        .foregroundStyle(statusStyle)
                }
            }
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var statusStyle: HierarchicalShapeStyle {
        // Continuous lifecycle states stay visually calm; only Error uses
        // stronger emphasis, applied by the caller's tint if desired.
        switch summary.terminalStatus {
        case .error: .primary
        default: .secondary
        }
    }

    private var accessibilityText: String {
        var parts = ["Terminal", summary.displayTitle]
        if let statusLabel = summary.statusLabel {
            parts.append(statusLabel)
        }
        return parts.joined(separator: ", ")
    }

    private func updatedAtText(now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(summary.updatedAt)) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        return summary.updatedAt.formatted(.dateTime.day().month(.abbreviated))
    }
}
