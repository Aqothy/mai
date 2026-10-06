#if os(macOS)
import SwiftUI

struct DesktopAppContainer: View {
    let store: ThreadStore
    let draftStore: ThreadDraftStore
    let projectFolders: ProjectFolderStore
    let terminalStore: TerminalStore

    /// The open terminal, if any. Chat selection lives in ThreadStore; only
    /// presentation merges the two domains.
    @State private var terminalRoute: TerminalOpenRequest?

    var body: some View {
        NavigationSplitView {
            DesktopSidebarView(
                store: store,
                projectFolders: projectFolders,
                terminalStore: terminalStore,
                terminalRoute: $terminalRoute
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 400)
        } detail: {
            if let terminalRoute {
                TerminalThreadScreen(
                    store: terminalStore,
                    request: terminalRoute,
                    onCreated: { terminalID in
                        self.terminalRoute = .existing(terminalID: terminalID)
                    },
                    onDeleted: {
                        self.terminalRoute = nil
                    }
                )
            } else {
                ChatView(
                    store: store,
                    draftStore: draftStore,
                    projectFolders: projectFolders,
                    openThread: { threadID in
                        store.selectThread(threadID)
                    }
                )
            }
        }
        .toolbar(removing: .title)
        .onChange(of: terminalRoute) { _, route in
            // Detach is navigation-driven: leaving the terminal detail
            // releases control without terminating the shell.
            if route == nil {
                terminalStore.closeActiveTerminal()
            }
        }
        #if DEBUG
            .modifier(
                ChatBenchmarkHarness(
                    store: store, selectThread: { store.selectThread($0) }, showsLabButton: true)
            )
        #endif
    }
}

#if DEBUG
#Preview("Desktop App") {
    DesktopAppContainer(
        store: PreviewData.threadStore(),
        draftStore: ThreadDraftStore(),
        projectFolders: ProjectFolderStore(defaults: nil),
        terminalStore: TerminalStore()
    )
}
#endif
#endif
