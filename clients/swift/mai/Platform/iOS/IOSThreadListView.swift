#if os(iOS)
import SwiftUI

struct IOSThreadListView: View {
    let store: ThreadStore
    let newChat: () -> Void
    let selectThread: (String) -> Void

    @State private var filter = ThreadListFilter()

    var body: some View {
        List {
            IOSThreadRows(
                store: store,
                threads: filteredThreads,
                selectThread: selectThread
            )
        }
        .listStyle(.plain)
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter.query, prompt: "Search Chats")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                IOSThreadFilterMenu(store: store, filter: $filter)
            }
        }
        .modifier(IOSThreadListBottomToolbar(newChat: newChat))
        .overlay {
            if filter.isActive, filteredThreads.isEmpty, !store.threads.isEmpty {
                if filter.trimmedQuery.isEmpty {
                    ContentUnavailableView(
                        "No Matching Chats",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Try adjusting your filters.")
                    )
                } else {
                    ContentUnavailableView.search(text: filter.trimmedQuery)
                }
            }
        }
        .modifier(ThreadListStatusModifier(store: store))
    }

    private var filteredThreads: [ThreadListEntry] {
        filter.apply(
            to: store.threads,
            isUnread: store.isThreadUnread,
            driver: store.driver(for:)
        )
    }
}

#if DEBUG
#Preview("iOS Thread List") {
    NavigationStack {
        IOSThreadListView(
            store: PreviewData.threadStore(),
            newChat: {},
            selectThread: { _ in }
        )
    }
}

#Preview("iOS Thread List Loading") {
    NavigationStack {
        IOSThreadListView(
            store: ThreadStore(),
            newChat: {},
            selectThread: { _ in }
        )
    }
}
#endif
#endif
