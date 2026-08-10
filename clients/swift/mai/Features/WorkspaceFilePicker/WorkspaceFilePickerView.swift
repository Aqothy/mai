import SwiftUI

enum WorkspaceFilePickerLayout {
    static let rowHeight: CGFloat = 36
    static let rowSpacing: CGFloat = 2
    static let contentInset: CGFloat = 6
    static let maximumVisibleRowCount = 5
}

struct WorkspaceFilePickerView: View {
    let model: WorkspaceFilePickerModel
    let select: (WorkspaceFileMatch) -> Void

    var body: some View {
        let height = panelHeight

        Group {
            if model.phase == .results, !model.matches.isEmpty {
                WorkspaceFilePickerResultsView(
                    matches: model.matches,
                    selectedMatchID: model.selectedMatchID,
                    showsOverflow: model.matches.count
                        > WorkspaceFilePickerLayout.maximumVisibleRowCount,
                    select: select
                )
            } else {
                WorkspaceFilePickerStatusView(
                    phase: model.phase,
                    query: model.query,
                    retry: model.retry
                )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(.rect(cornerRadius: 16))
        .glassSurface(in: .rect(cornerRadius: 16), isShadowed: true)
        .task(id: model.searchKey) {
            await model.search()
        }
    }

    private var panelHeight: CGFloat {
        guard model.phase == .results, !model.matches.isEmpty else { return 48 }

        let rowCount = min(
            model.matches.count,
            WorkspaceFilePickerLayout.maximumVisibleRowCount
        )
        return CGFloat(rowCount) * WorkspaceFilePickerLayout.rowHeight
            + CGFloat(max(rowCount - 1, 0)) * WorkspaceFilePickerLayout.rowSpacing
            + 2 * WorkspaceFilePickerLayout.contentInset
    }
}
