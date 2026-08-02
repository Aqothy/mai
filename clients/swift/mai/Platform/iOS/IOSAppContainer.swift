#if os(iOS)
import SwiftUI

struct IOSAppContainer: View {
    let store: ThreadStore
    let draftStore: ThreadDraftStore

    var body: some View {
        IOSCompactAppContainer(store: store, draftStore: draftStore)
    }
}

#if DEBUG
#Preview("iOS App") {
    IOSAppContainer(
        store: PreviewData.threadStore(),
        draftStore: ThreadDraftStore()
    )
}
#endif
#endif
