import SwiftUI

@main
struct MaiApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var connection: RPCConnectionCoordinator
    @State private var threadStore: ThreadStore
    @State private var threadDraftStore = ThreadDraftStore()

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
                    previewThreads: [thread.summary],
                    selectedThread: thread
                )
            }
        #endif
        usesSyntheticBenchmarkStore = syntheticStore != nil
        _threadStore = State(
            initialValue: syntheticStore
                ?? ThreadStore(rpc: rpc, connection: connection)
        )
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(
                store: threadStore,
                draftStore: threadDraftStore
            )
            .task {
                guard !usesSyntheticBenchmarkStore else { return }
                await connection.start()
            }
            .task(priority: .utility) {
                // Only warm highlight.js/JSC for the legacy transcript; the new
                // engine renders plain code until the replacement highlighter lands.
                guard !TranscriptEngine.isNewEngineEnabled else { return }
                await ChatCodeHighlighter.shared.warmUp()
            }
            .onChange(of: scenePhase) {
                if scenePhase == .active {
                    guard !usesSyntheticBenchmarkStore else { return }
                    connection.resume()
                } else {
                    threadDraftStore.flushPendingSave()
                }
            }
        }
        #if DEBUG
            .commands {
                if usesSyntheticBenchmarkStore { ChatPlaygroundCommands(store: threadStore) }
            }
        #endif
    }
}
