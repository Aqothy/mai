import SwiftUI

struct DesktopAppContainer: View {
    let store: ThreadStore

    var body: some View {
        NavigationSplitView {
            DesktopSidebarView(store: store)
                .navigationSplitViewColumnWidth(260)
        } detail: {
        }
        .toolbar(removing: .title)
    }
}

#if DEBUG
#Preview("Desktop App") {
    DesktopAppContainer(store: PreviewData.threadStore())
}
#endif
