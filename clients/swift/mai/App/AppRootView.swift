import SwiftUI

struct AppRootView: View {
    let store: ThreadStore

    var body: some View {
        #if os(iOS)
        IOSAppContainer(store: store)
        #else
        DesktopAppContainer(store: store)
        #endif
    }
}
