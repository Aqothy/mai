#if os(iOS)
import SwiftUI

struct IOSSidebarView: View {
    let store: ThreadStore
    let selectThread: (String?) -> Void

    var body: some View {
        ScrollView {
            LazyVStack {
                IOSThreadRows(
                    store: store,
                    threads: store.threads,
                    selectThread: { selectThread($0) }
                )
            }
            .padding(.top, 48)
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
        .modifier(ThreadListStatusModifier(store: store))
    }
}

#if DEBUG
#Preview("iOS Sidebar") {
    let store = PreviewData.threadStore()
    IOSSidebarView(store: store, selectThread: store.selectThread)
}
#endif
#endif
