import SwiftUI

struct AppRootView: View {
    let store: ThreadStore
    let draftStore: ThreadDraftStore
    let terminalStore: TerminalStore

    var body: some View {
        #if os(iOS)
        IOSAppContainer(store: store, draftStore: draftStore, terminalStore: terminalStore)
        #else
        DesktopAppContainer(store: store, draftStore: draftStore, terminalStore: terminalStore)
        #endif
    }
}
