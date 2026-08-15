import SwiftUI

/// View options for the Threads list: display mode plus preset filters.
/// Shared by the desktop sidebar and the iOS toolbar.
struct ThreadFilterMenu: View {
    let store: ThreadStore
    @Binding var filter: ThreadListFilter
    var showsActivityFilter = true

    @AppStorage(ThreadListDisplayMode.appStorageKey)
    private var displayModeRaw = ThreadListDisplayMode.recent.rawValue

    var body: some View {
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

            Picker("Project", systemImage: "folder", selection: $filter.projectCwd) {
                Text("All Projects").tag(String?.none)
                ForEach(store.recentWorkingDirectories, id: \.self) { cwd in
                    Text(URL(filePath: cwd).lastPathComponent).tag(String?.some(cwd))
                }
            }
            .pickerStyle(.menu)

            Picker("Provider", systemImage: "cpu", selection: $filter.providerID) {
                Text("All Providers").tag(String?.none)
                ForEach(store.availableProviders) { provider in
                    Text(provider.name)
                        .tag(String?.some(provider.id))
                }
            }
            .pickerStyle(.menu)

            if showsActivityFilter {
                Picker("Activity", selection: $filter.activityFilter) {
                    ForEach(ThreadListActivityFilter.allCases) { activityFilter in
                        Text(activityFilter.title).tag(activityFilter)
                    }
                }
                .pickerStyle(.inline)
            }

            if filter.hasActivePresets {
                Button("Reset Filters", systemImage: "arrow.counterclockwise") {
                    filter.resetPresets()
                }
            }
        }
    }
}
