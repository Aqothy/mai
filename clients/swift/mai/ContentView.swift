import SwiftUI

@main
struct MaiApp: App {
    @State private var threadStore = ThreadStore()

    var body: some Scene {
        WindowGroup {
            AppRootView(store: threadStore)
                .task {
                    await threadStore.start()
                }
        }
    }
}
