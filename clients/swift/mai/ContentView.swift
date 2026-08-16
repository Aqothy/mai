import SwiftUI

@main
struct MaiApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var connection: RPCConnectionCoordinator
    @State private var threadStore: ThreadStore
    @State private var threadDraftStore = ThreadDraftStore()
    @State private var terminalStore: TerminalStore

    init() {
        let rpc = RPCClient()
        let connection = RPCConnectionCoordinator(rpc: rpc)
        _connection = State(initialValue: connection)
        _threadStore = State(
            initialValue: ThreadStore(rpc: rpc, connection: connection)
        )
        _terminalStore = State(
            initialValue: TerminalStore(rpc: rpc, connection: connection)
        )
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(
                store: threadStore,
                draftStore: threadDraftStore,
                terminalStore: terminalStore
            )
            .task {
                await connection.start()
            }
            .onChange(of: scenePhase) {
                if scenePhase != .active {
                    threadDraftStore.flushPendingSave()
                }
            }
        }
    }
}
