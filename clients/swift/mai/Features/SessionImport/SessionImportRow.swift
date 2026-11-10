import SwiftUI

struct SessionImportRow: View {
    let entry: SessionImportEntry
    let capabilities: SessionImportCapabilities
    let isImporting: Bool
    let isDeleting: Bool
    let importSession: () -> Void
    let deleteSession: () -> Void

    @State private var isConfirmingDelete = false

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

            if isImporting || isDeleting {
                ProgressView()
                    .controlSize(.small)
            } else {
                if capabilities.canImport {
                    Button("Import", action: importSession)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                }

                if capabilities.canDelete {
                    Menu("Session Actions", systemImage: "ellipsis") {
                        Button("Delete Session", systemImage: "trash", role: .destructive) {
                            isConfirmingDelete = true
                        }
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Session Actions")
                } else if !capabilities.canImport {
                    Label("No available actions", systemImage: "nosign")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("No available actions")
                }
            }
        }
        .contentShape(.rect)
        .confirmationDialog("Delete Session?", isPresented: $isConfirmingDelete) {
            Button("Delete Session", role: .destructive, action: deleteSession)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the provider session. This action cannot be undone.")
        }
    }
}
