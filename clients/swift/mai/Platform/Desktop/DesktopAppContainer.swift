import SwiftUI

struct DesktopAppContainer: View {
    let store: ThreadStore
    let draftStore: ThreadDraftStore

    var body: some View {
        NavigationSplitView {
            DesktopSidebarView(store: store, draftStore: draftStore)
                .navigationSplitViewColumnWidth(260)
        } detail: {
            ChatView(store: store, draftStore: draftStore)
        }
        .toolbar(removing: .title)
    }
}

#if DEBUG
#Preview("Desktop App") {
    DesktopAppContainer(
        store: PreviewData.threadStore(),
        draftStore: ThreadDraftStore()
    )
}
#endif
