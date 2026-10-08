import SwiftUI

struct AppRootView: View {
    let store: ThreadStore
    let draftStore: ThreadDraftStore
    let projectFolders: ProjectFolderStore
    let terminalStore: TerminalStore

    var body: some View {
        Group {
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
        // Lets deep screens (provider sign-in) open a terminal.
        .environment(terminalStore)
    }
}
