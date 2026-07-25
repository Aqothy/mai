import SwiftUI

@main
struct MaiApp: App {
    @State private var threadStore = ThreadStore()
    @State private var threadDraftStore = ThreadDraftStore()

    var body: some Scene {
        WindowGroup {
            AppRootView(store: threadStore, draftStore: threadDraftStore)
                .task {
                    await threadStore.start()
                }
        }
    }
}
