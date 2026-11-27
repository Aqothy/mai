import SwiftUI

struct AppRootView: View {
    let store: ThreadStore
    let draftStore: ThreadDraftStore

    var body: some View {
        Group {
            #if os(macOS)
                DesktopAppContainer(
                    store: store,
                    draftStore: draftStore
                )
            #else
                IOSAppContainer(
                    store: store,
                    draftStore: draftStore
                )
            #endif
        }
    }
}
