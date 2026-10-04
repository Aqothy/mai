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
    @State private var isPerformanceLabPresented = false

    var body: some View {
        if ChatBenchmarkAutoRun.plan != nil,
            ChatBenchmarkAutoRun.threadTitleQuery == nil
        {
            // Headless benchmarking must reach the lab without navigating
            // through (or connecting to) the real thread list.
            NavigationStack {
                MockChatView()
            }
        } else {
            container
                .modifier(
                    ChatRealThreadBenchmarkRunner(
                        store: store,
                        selectThread: { threadID in
                            store.selectThread(threadID)
                        }
                    )
                )
        }
    }

    private var container: some View {
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
        .toolbar {
            if ChatPerformanceLab.isEnabled {
                ToolbarItem(placement: .automatic) {
                    Button("Mock Chat", systemImage: "ladybug") {
                        isPerformanceLabPresented = true
                    }
                }
            }
        }
        .sheet(isPresented: $isPerformanceLabPresented) {
            NavigationStack {
                MockChatView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                isPerformanceLabPresented = false
                            }
                        }
                    }
            }
            .frame(minWidth: 900, minHeight: 700)
        }
        .onChange(of: terminalRoute) { _, route in
            // Detach is navigation-driven: leaving the terminal detail
            // releases control without terminating the shell.
            if route == nil {
                terminalStore.closeActiveTerminal()
            }
        }
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
