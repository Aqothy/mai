import SwiftUI

/// Single-line rows for the "By Project" display mode, where the section
/// header carries project context and the row stays quiet: title, plus live
/// status (or recency when idle) at the trailing edge.
struct CompactThreadRow: View {
    let thread: ThreadListEntry
    let isUnread: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isUnread {
                Circle()
                    .fill(.tint)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Unread")
            }

            Text(thread.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .fontWeight(isUnread ? .semibold : .regular)

            Spacer(minLength: 8)

            if let status = thread.rowIndicatorStatus {
                ThreadRowStatusView(status: status)
            } else {
                ThreadRowTimestampText(updatedAt: thread.updatedAt)
            }
        }
        .contentShape(.rect)
    }
}

/// The terminal counterpart, marked by a glyph in place of project context.
struct CompactTerminalRow: View {
    let summary: TerminalSummary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(summary.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            if let status = summary.rowIndicatorStatus {
                ThreadRowStatusView(status: status)
            } else {
                ThreadRowTimestampText(updatedAt: summary.updatedAt)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Terminal, \(summary.displayTitle)")
    }
}

/// Compact relative recency that keeps ticking while on screen, driven by
/// the schedule's date rather than Date.now.
struct ThreadRowTimestampText: View {
    let updatedAt: Date

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(text(now: context.date))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    private func text(now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(updatedAt)) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        return updatedAt.formatted(.dateTime.day().month(.abbreviated))
    }
}

extension ThreadListEntry {
    /// The same status precedence ThreadRow renders, exposed for row
    /// variants that live outside that view.
    var rowIndicatorStatus: ThreadRowIndicatorStatus? {
        if hasPendingApprovals {
            return .needsInput
        }
        if latestTurn?.turnState == .running {
            return .working
        }
        if latestTurn?.turnState == .error || session?.sessionStatus == .error {
            return .failed
        }
        if latestTurn?.turnState == .interrupted {
            return .interrupted
        }
        return nil
    }
}
