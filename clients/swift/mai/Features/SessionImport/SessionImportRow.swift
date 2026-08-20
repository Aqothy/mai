import SwiftUI

struct SessionImportRow: View {
    let entry: SessionImportEntry
    let capabilities: SessionImportCapabilities
    let isImporting: Bool
    let maintenanceAction: SessionMaintenanceAction?
    let isClosed: Bool
    let importSession: () -> Void
    let closeSession: () -> Void
    let deleteSession: () -> Void

    @State private var confirmationAction: SessionMaintenanceAction?

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
                if isClosed {
                    Label("Closed", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if isImporting || maintenanceAction != nil {
                ProgressView()
                    .controlSize(.small)
            } else {
                if capabilities.canImport {
                    Button("Import", action: importSession)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                }

                if capabilities.canClose || capabilities.canDelete {
                    Menu("Session Actions", systemImage: "ellipsis") {
                        if capabilities.canClose {
                            Button("Close Session", systemImage: "xmark.circle") {
                                confirmationAction = .close
                            }
                            .disabled(isClosed)
                        }
                        if capabilities.canDelete {
                            Button(
                                "Delete Session",
                                systemImage: "trash",
                                role: .destructive
                            ) {
                                confirmationAction = .delete
                            }
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
        .confirmationDialog(
            confirmationAction == .delete ? "Delete Session?" : "Close Session?",
            isPresented: Binding(
                get: { confirmationAction != nil },
                set: { if !$0 { confirmationAction = nil } }
            )
        ) {
            switch confirmationAction {
            case .close:
                Button("Close Session") {
                    confirmationAction = nil
                    closeSession()
                }
            case .delete:
                Button("Delete Session", role: .destructive) {
                    confirmationAction = nil
                    deleteSession()
                }
            case nil:
                EmptyView()
            }
            Button("Cancel", role: .cancel) {
                confirmationAction = nil
            }
        } message: {
            if confirmationAction == .delete {
                Text("This permanently deletes the provider session. This action cannot be undone.")
            } else {
                Text("This closes the provider session without deleting its history.")
            }
        }
        .accessibilityValue(isClosed ? "Closed" : "")
    }
}
