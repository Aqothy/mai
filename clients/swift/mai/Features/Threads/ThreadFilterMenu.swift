import SwiftUI

/// View arrangement plus project and provider filters for the Threads list.
struct ThreadFilterMenu: View {
    let store: ThreadStore
    let projectFolders: ProjectFolderStore
    @Binding var filter: ThreadListFilter

    @AppStorage(ThreadListDisplayMode.appStorageKey)
    private var displayModeRaw = ThreadListDisplayMode.recent.rawValue

    @State private var isProjectFilterPresented = false
    @State private var isProviderFilterPresented = false

    var body: some View {
        let projectName = filter.projectCwd.map { URL(filePath: $0).lastPathComponent }
        let providerName = filter.providerID.flatMap { selectedID in
            store.availableProviders.first { $0.id == selectedID }?.name
        }
        let projectPaths = projectFolders.folders
            + store.recentWorkingDirectories.filter { !projectFolders.contains($0) }

        Menu(
            "Filter Threads",
            systemImage: filter.hasActivePresets
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle"
        ) {
            Picker("View", selection: $displayModeRaw) {
                ForEach(ThreadListDisplayMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode.rawValue)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Button {
                isProjectFilterPresented = true
            } label: {
                Label(projectName ?? "All Projects", systemImage: "folder")
            }

            Button {
                isProviderFilterPresented = true
            } label: {
                Label(providerName ?? "All Providers", systemImage: "cpu")
            }

            if filter.hasActivePresets {
                Button("Reset Filters", systemImage: "arrow.counterclockwise") {
                    filter.resetPresets()
                }
            }
        }
        .sheet(isPresented: $isProjectFilterPresented) {
            SearchableSelectionSheet(
                title: "Project",
                choices: projectPaths.map { path in
                    SearchableSelectionChoice(
                        id: path,
                        title: URL(filePath: path).lastPathComponent,
                        subtitle: path,
                        systemImage: "folder"
                    )
                },
                selectedID: filter.projectCwd,
                clearSelectionTitle: "All Projects",
                emptyTitle: "No Projects",
                onSelect: { filter.projectCwd = $0 }
            )
        }
        .sheet(isPresented: $isProviderFilterPresented) {
            SearchableSelectionSheet(
                title: "Provider",
                choices: store.availableProviders.map { provider in
                    SearchableSelectionChoice(
                        id: provider.id,
                        title: provider.name,
                        subtitle: nil,
                        systemImage: "server.rack"
                    )
                },
                selectedID: filter.providerID,
                clearSelectionTitle: "All Providers",
                emptyTitle: "No Providers",
                onSelect: { filter.providerID = $0 }
            )
        }
    }
}
