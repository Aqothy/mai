#if os(iOS)
import SwiftUI

struct IOSThreadRows: View {
    let store: ThreadStore
    let threads: [ThreadListEntry]
    let selectThread: (String) -> Void

    var body: some View {
        ForEach(threads, id: \.id) { thread in
            Button {
                #if DEBUG
                if thread.id != store.selectedThreadID {
                    ChatPerformanceDiagnostics.beginNavigation(
                        threadID: thread.id,
                        cachedRowCount: store.cachedThread(for: thread.id)?.timeline.count,
                        wasSubscribed: store.subscribedThreadIDs.contains(thread.id)
                    )
                }
                #endif
                selectThread(thread.id)
            } label: {
                ThreadRow(
                    thread: thread,
                    isUnread: store.isThreadUnread(thread.id),
                    providerName: store.providerDisplayName(for: thread)
                )
            }
            // The title's taller line box carries more headroom than the
            // caption line's descender, so an optically even row needs a
            // slightly shorter top inset.
            .listRowInsets(EdgeInsets(top: 9, leading: 16, bottom: 11, trailing: 16))
            .contextMenu {
                if store.isThreadUnread(thread.id) {
                    Button("Mark as Read", systemImage: "envelope.open") {
                        store.markThreadRead(thread.id)
                    }
                } else {
                    Button("Mark as Unread", systemImage: "envelope.badge") {
                        store.markThreadUnread(thread.id)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}
#endif
