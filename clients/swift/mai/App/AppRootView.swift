import SwiftUI

struct AppRootView: View {
    let store: ThreadStore
    let draftStore: ThreadDraftStore
    let terminalStore: TerminalStore

    var body: some View {
        IOSAppContainer(store: store, draftStore: draftStore, terminalStore: terminalStore)
    }
}
