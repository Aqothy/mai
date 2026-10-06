import SwiftUI

struct AppRootView: View {
    let store: ThreadStore
    let draftStore: ThreadDraftStore
    let projectFolders: ProjectFolderStore
    let terminalStore: TerminalStore

    var body: some View {
        #if os(macOS)
            DesktopAppContainer(
                store: store,
                draftStore: draftStore,
                projectFolders: projectFolders,
                terminalStore: terminalStore
            )
        #else
            IOSAppContainer(
                store: store,
                draftStore: draftStore,
                projectFolders: projectFolders,
                terminalStore: terminalStore
            )
        #endif
    }
}
