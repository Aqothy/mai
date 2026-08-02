import SwiftUI

struct ACPRegistryRow: View {
    let entry: ACPRegistryEntry
    let isInstalling: Bool
    let install: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let description = entry.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                }
                if !entry.versionLabel.isEmpty {
                    Text(entry.versionLabel)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            ACPRegistryRowAction(
                entry: entry,
                isInstalling: isInstalling,
                install: install
            )
        }
        .contentShape(.rect)
    }
}

struct ACPRegistryRowAction: View {
    let entry: ACPRegistryEntry
    let isInstalling: Bool
    let install: () -> Void

    var body: some View {
        if isInstalling {
            ProgressView()
                .controlSize(.small)
        } else if !entry.isInstalled {
            Button("Install", action: install)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(entry.availableVersion == nil)
        } else if entry.hasUpdate {
            Button("Update", action: install)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
        } else {
            Label("Installed", systemImage: "checkmark")
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Installed")
        }
    }
}
