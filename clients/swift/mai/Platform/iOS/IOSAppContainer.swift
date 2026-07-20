#if os(iOS)
import SwiftUI

struct IOSAppContainer: View {
    @State private var isSidebarPresented = false

    var body: some View {
        SlideOutMenu(isOpen: $isSidebarPresented) { _ in
            NavigationStack {
                IOSSidebarView(
                    threads: [],
                    isPresented: $isSidebarPresented
                )
            }
        } content: { _ in
            NavigationStack {
                Color.clear
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
    IOSAppContainer()
}
#endif
#endif
