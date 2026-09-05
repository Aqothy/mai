import SwiftUI

@main
struct MaiApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var connection: RPCConnectionCoordinator
    @State private var threadStore: ThreadStore
    @State private var threadDraftStore = ThreadDraftStore()
    @State private var projectFolderStore = ProjectFolderStore()
    @State private var terminalStore: TerminalStore

    /// A synthetic benchmark transcript replaces the daemon-backed store; the
    /// app must then never open the RPC connection.
    private let usesSyntheticBenchmarkStore: Bool

    init() {
        let rpc = RPCClient()
        let connection = RPCConnectionCoordinator(rpc: rpc)
        _connection = State(initialValue: connection)
        var syntheticStore: ThreadStore?
        #if DEBUG
            if let turnCount = ChatBenchmarkAutoRun.syntheticThreadTurnCount {
                let thread = ChatSyntheticBenchmarkThread.thread(turnCount: turnCount)
                syntheticStore = ThreadStore(
                    previewThreads: [ChatSyntheticBenchmarkThread.listEntry(for: thread)],
                    selectedThread: thread
                )
            }
        #endif
        usesSyntheticBenchmarkStore = syntheticStore != nil
        _threadStore = State(
            initialValue: syntheticStore
                ?? ThreadStore(rpc: rpc, connection: connection)
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
                projectFolders: projectFolderStore,
                terminalStore: terminalStore
            )
            .task {
                guard !usesSyntheticBenchmarkStore else { return }
                await connection.start()
            }
            .task(priority: .utility) {
                // Off the launch path and off the main actor; the first code
                // block a chat shows then highlights without a stall.
                await ChatCodeHighlighter.shared.warmUp()
            }
            .onChange(of: scenePhase) {
                if scenePhase != .active {
                    threadDraftStore.flushPendingSave()
                }
            }
        }
    }
}
