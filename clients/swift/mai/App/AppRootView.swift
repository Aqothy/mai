import SwiftUI

struct AppRootView: View {
    let store: ThreadStore
    let draftStore: ThreadDraftStore
    let projectFolders: ProjectFolderStore
    let terminalStore: TerminalStore

    var body: some View {
        IOSAppContainer(
            store: store,
            draftStore: draftStore,
            projectFolders: projectFolders,
            terminalStore: terminalStore
        )
    }
}
