import SwiftUI

struct DesktopAppContainer: View {
    var body: some View {
        NavigationSplitView {
            DesktopSidebarView(threads: [])
                .navigationSplitViewColumnWidth(260)
        } detail: {
        }
        .toolbar(removing: .title)
    }
}

#if DEBUG
#Preview("Desktop App") {
    DesktopAppContainer()
}
#endif
