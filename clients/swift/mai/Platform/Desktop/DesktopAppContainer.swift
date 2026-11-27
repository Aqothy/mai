#if os(macOS)
import SwiftUI

struct DesktopAppContainer: View {
    let store: ThreadStore
    let draftStore: ThreadDraftStore

    @State private var columnVisibility = Self.initialColumnVisibility

    /// A transcript-only benchmark shows the detail column alone.
    private static var initialColumnVisibility: NavigationSplitViewVisibility {
        #if DEBUG
            if ChatBenchmarkAutoRun.isTranscriptOnly { return .detailOnly }
        #endif
        return .automatic
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            DesktopSidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
        } detail: {
            ChatView(
                store: store,
                draftStore: draftStore,
                openThread: { threadID in
                    store.selectThread(threadID)
                },
                openDraft: {
                    store.selectThread(nil)
                }
            )
        }
        .toolbar(removing: .title)
        #if DEBUG
            .modifier(
                ChatRealThreadBenchmarkRunner(store: store, selectThread: { store.selectThread($0) })
            )
        #endif
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
#endif
