import SwiftUI

struct ThreadRow: View {
    let thread: ThreadListEntry
    let isUnread: Bool
    var providerName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if isUnread {
                    Circle()
                        .fill(.tint)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Unread")
                }

                Text(thread.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .bold(isUnread)

                Spacer(minLength: 8)

                Text(updatedAtText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                if let workingDirectoryName {
                    HStack(spacing: 3) {
                        Image(systemName: "folder")
                        Text(workingDirectoryName)
                    }
                }

                if let providerName, !providerName.isEmpty {
                    if workingDirectoryName != nil {
                        Text("·")
                    }
                    Text(providerName)
                }

                Spacer(minLength: 8)

                ThreadRowStatusView(thread: thread)
            }
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
    }

    private var workingDirectoryName: String? {
        guard let cwd = thread.cwd, !cwd.isEmpty else { return nil }
        return URL(filePath: cwd).lastPathComponent
    }

    private var updatedAtText: String {
        let minutes = Int(max(0, Date.now.timeIntervalSince(thread.updatedAt)) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }
        return thread.updatedAt.formatted(.dateTime.day().month(.abbreviated))
    }
}

#if DEBUG
#Preview("Thread Row") {
    VStack(spacing: 12) {
        ThreadRow(thread: PreviewData.threads[0], isUnread: false, providerName: "Claude Code")
        ThreadRow(thread: PreviewData.threads[1], isUnread: true, providerName: "Codex")
        ThreadRow(thread: PreviewData.threads[2], isUnread: false, providerName: "Gemini")
    }
    .padding()
}
#endif
