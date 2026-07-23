#if os(iOS)
import SwiftUI

struct IOSAppContainer: View {
    let store: ThreadStore

    @State private var isSidebarPresented = false

    var body: some View {
        SlideOutMenu(isOpen: $isSidebarPresented) { _ in
            NavigationStack {
                IOSSidebarView(
                    store: store,
                    isPresented: $isSidebarPresented
                )
            }
        } content: { _ in
            NavigationStack {
                ChatView(
                    thread: store.selectedThread,
                    errorMessage: store.selectedThreadLoadErrorMessage,
                    retry: store.retry
                )
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
    IOSAppContainer(store: PreviewData.threadStore())
}
#endif
#endif
