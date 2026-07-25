import SwiftUI

struct AppRootView: View {
    let store: ThreadStore
    let draftStore: ThreadDraftStore

    var body: some View {
        #if os(iOS)
        IOSAppContainer(store: store, draftStore: draftStore)
        #else
        DesktopAppContainer(store: store, draftStore: draftStore)
        #endif
    }
}
