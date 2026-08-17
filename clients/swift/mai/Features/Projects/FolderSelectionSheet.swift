import SwiftUI

struct FolderSelectionSheet: View {
    let store: ThreadStore
    let projectFolders: ProjectFolderStore
    let title: String
    let selectedFolder: String?
    let onSelectExisting: (String) -> Void
    let onSelectBrowsed: (String, String?) -> Void

    @State private var isBrowsing = false

    var body: some View {
        if isBrowsing {
            FolderPickerView(
                store: store,
                projectFolders: projectFolders,
                title: "Choose Folder",
                confirmationTitle: "Choose",
                onCancel: { isBrowsing = false },
                onSelect: onSelectBrowsed
            )
        } else {
            SearchableSelectionSheet(
                title: title,
                choices: projectFolders.folders.map { path in
                    SearchableSelectionChoice(
                        id: path,
                        title: URL(filePath: path).lastPathComponent,
                        subtitle: path,
                        systemImage: "folder"
                    )
                },
                selectedID: selectedFolder,
                emptyTitle: "No Project Folders",
                actionTitle: "Choose Another Folder",
                actionSystemImage: "folder.badge.plus",
                onSelect: { path in
                    guard let path else { return }
                    onSelectExisting(path)
                },
                onAction: { isBrowsing = true }
            )
        }
    }
}
