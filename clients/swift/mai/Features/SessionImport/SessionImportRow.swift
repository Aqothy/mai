import SwiftUI

struct SessionImportRow: View {
    let entry: SessionImportEntry
    let isImporting: Bool
    let importSession: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .lineLimit(2)
                    .truncationMode(.tail)
                if let cwd = entry.cwd, !cwd.isEmpty {
                    Text(cwd)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                }
                if let updatedAt = entry.updatedAt {
                    Text(updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            if isImporting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Import", action: importSession)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        }
        .contentShape(.rect)
    }
}
