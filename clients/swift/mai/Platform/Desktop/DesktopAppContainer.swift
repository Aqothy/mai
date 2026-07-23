import SwiftUI

struct DesktopAppContainer: View {
    let store: ThreadStore

    var body: some View {
        NavigationSplitView {
            DesktopSidebarView(store: store)
                .navigationSplitViewColumnWidth(260)
        } detail: {
            ChatView(
                thread: store.selectedThread,
                errorMessage: store.selectedThreadLoadErrorMessage,
                retry: store.retry
            )
        }
        .toolbar(removing: .title)
    }
}

#if DEBUG
#Preview("Desktop App") {
    DesktopAppContainer(store: PreviewData.threadStore())
}
#endif
