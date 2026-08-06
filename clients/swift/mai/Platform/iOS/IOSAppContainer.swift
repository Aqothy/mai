#if os(iOS)
import SwiftUI

struct IOSAppContainer: View {
    let store: ThreadStore
    let draftStore: ThreadDraftStore
    let terminalStore: TerminalStore

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .regular {
            IOSRegularAppContainer(
                store: store,
                draftStore: draftStore,
                terminalStore: terminalStore
            )
        } else {
            IOSCompactAppContainer(
                store: store,
                draftStore: draftStore,
                terminalStore: terminalStore
            )
        }
    }
}

#if DEBUG
#Preview("iOS App") {
    IOSAppContainer(
        store: PreviewData.threadStore(),
        draftStore: ThreadDraftStore(),
        terminalStore: TerminalStore()
    )
}
#endif
#endif
