import SwiftUI

@main
struct MaiApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var threadStore = ThreadStore()
    @State private var threadDraftStore = ThreadDraftStore()

    var body: some Scene {
        WindowGroup {
            AppRootView(store: threadStore, draftStore: threadDraftStore)
                .task {
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
