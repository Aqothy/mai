import SwiftUI

struct WorkspaceFilePickerRow: View {
    let displayName: String
    let directoryPath: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(displayName)
                    .font(.callout)
                    .lineLimit(1)
                    .layoutPriority(1)

                Text(directoryPath)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: WorkspaceFilePickerLayout.rowHeight)
            .background(
                isSelected ? Color.primary.opacity(0.1) : Color.clear,
                in: .rect(cornerRadius: 10)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(displayName), \(directoryPath)")
        .accessibilityHint("Adds a reference to this file to the prompt.")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
