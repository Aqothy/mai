#if os(iOS)
import SwiftUI

struct IOSThreadFilterMenu: View {
    let store: ThreadStore
    @Binding var filter: ThreadListFilter

    var body: some View {
        Menu(
            "Filter Chats",
            systemImage: filter.hasActivePresets
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle"
        ) {
            Picker("Project", systemImage: "folder", selection: $filter.projectCwd) {
                Text("All Projects").tag(String?.none)
                ForEach(store.recentWorkingDirectories, id: \.self) { cwd in
                    Text(URL(filePath: cwd).lastPathComponent).tag(String?.some(cwd))
                }
            }
            .pickerStyle(.menu)

            Picker("Provider", systemImage: "cpu", selection: $filter.driver) {
                Text("All Providers").tag(String?.none)
                ForEach(store.availableDrivers, id: \.self) { driver in
                    Text(driver)
                        .tag(String?.some(driver))
                }
            }
            .pickerStyle(.menu)

            Picker("Activity", selection: $filter.activityFilter) {
                ForEach(ThreadListActivityFilter.allCases) { activityFilter in
                    Text(activityFilter.title).tag(activityFilter)
                }
            }
            .pickerStyle(.inline)

            if filter.hasActivePresets {
                Button("Reset Filters", systemImage: "arrow.counterclockwise") {
                    filter.resetPresets()
                }
            }
        }
    }
}
#endif
