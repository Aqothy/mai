import SwiftUI

@main
struct MaiApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var threadStore = ThreadStore()
    @State private var threadDraftStore = ThreadDraftStore()
    @State private var terminalStore = TerminalStore()

    var body: some Scene {
        WindowGroup {
            AppRootView(
                store: threadStore,
                draftStore: threadDraftStore,
                terminalStore: terminalStore
            )
            .task {
                // Independent connections: a terminal transport failure must
                // not disconnect agent threads, and vice versa.
                terminalStore.start()
                await threadStore.start()
            }
            .onChange(of: scenePhase) {
                if scenePhase != .active {
                    threadDraftStore.flushPendingSave()
                }
            }
        }
    }
}
