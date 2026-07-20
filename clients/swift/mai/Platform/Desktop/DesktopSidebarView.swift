import SwiftUI

struct DesktopSidebarView: View {
    let threads: [ThreadListEntry]

    var body: some View {
        List {
            ForEach(threads, id: \.id) { thread in
                ThreadRow(thread: thread)
            }
        }
        .listStyle(.sidebar)
    }
}

#if DEBUG
#Preview("Desktop Sidebar") {
    NavigationStack {
        DesktopSidebarView(threads: PreviewData.threads)
    }
}
#endif
