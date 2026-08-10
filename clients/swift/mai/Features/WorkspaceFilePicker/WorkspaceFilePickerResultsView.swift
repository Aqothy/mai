import SwiftUI

struct WorkspaceFilePickerResultsView: View {
    let matches: [WorkspaceFileMatch]
    let selectedMatchID: WorkspaceFileMatch.ID?
    let showsOverflow: Bool
    let select: (WorkspaceFileMatch) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: WorkspaceFilePickerLayout.rowSpacing) {
                    ForEach(matches) { match in
                        WorkspaceFilePickerRow(
                            displayName: match.displayName,
                            directoryPath: match.directoryPath,
                            isSelected: match.id == selectedMatchID
                        ) {
                            select(match)
                        }
                        .id(match.id)
                    }
                }
                .padding(WorkspaceFilePickerLayout.contentInset)
            }
            .onChange(of: selectedMatchID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
}
