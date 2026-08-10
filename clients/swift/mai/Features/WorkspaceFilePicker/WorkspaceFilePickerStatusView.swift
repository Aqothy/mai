import SwiftUI

struct WorkspaceFilePickerStatusView: View {
    let phase: WorkspaceFilePickerModel.Phase
    let query: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            switch phase {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                Text("Searching files…")
            case .indexing:
                ProgressView()
                    .controlSize(.small)
                Text("Indexing files…")
                Spacer()
                Button("Check Again", action: retry)
            case .results where query.isEmpty:
                Label("No files found", systemImage: "doc.text.magnifyingglass")
            case .results:
                Label("No matching files", systemImage: "doc.text.magnifyingglass")
            case .failed:
                Label("Couldn’t search files", systemImage: "exclamationmark.triangle")
                Spacer()
                Button("Try Again", action: retry)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
