#if os(iOS)
import SwiftUI

struct IOSAppContainer: View {
    let store: ThreadStore
    let draftStore: ThreadDraftStore

    @State private var isSidebarPresented = false

    var body: some View {
        SlideOutMenu(isOpen: $isSidebarPresented) { _ in
            NavigationStack {
                IOSSidebarView(
                    store: store,
                    draftStore: draftStore,
                    isPresented: $isSidebarPresented
                )
            }
        } content: { _ in
            NavigationStack {
                ChatView(store: store, draftStore: draftStore)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button(
                            isSidebarPresented ? "Close menu" : "Open menu",
                            systemImage: "line.3.horizontal"
                        ) {
                            isSidebarPresented.toggle()
                        }
                        .labelStyle(.iconOnly)
                    }
                }
            }
        }
    }
}

#if DEBUG
#Preview("iOS App") {
    IOSAppContainer(
        store: PreviewData.threadStore(),
        draftStore: ThreadDraftStore()
    )
}
#endif
#endif
