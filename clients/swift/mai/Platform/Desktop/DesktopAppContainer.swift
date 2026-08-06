import SwiftUI

struct DesktopAppContainer: View {
    let store: ThreadStore
    let draftStore: ThreadDraftStore
    @State private var showsDevTerminal = false

    var body: some View {
        NavigationSplitView {
            DesktopSidebarView(store: store)
                .navigationSplitViewColumnWidth(260)
        } detail: {
            ChatView(store: store, draftStore: draftStore)
        }
        .toolbar(removing: .title)
        .toolbar {
            if TerminalLab.isEnabled {
                ToolbarItem(placement: .automatic) {
                    Button("Terminal", systemImage: "terminal") {
                        showsDevTerminal = true
                    }
                }
            }
        }
        .sheet(isPresented: $showsDevTerminal) {
            NavigationStack {
                TerminalDevView()
            }
            .frame(minWidth: 720, minHeight: 480)
        }
    }
}

#if DEBUG
#Preview("Desktop App") {
    DesktopAppContainer(
        store: PreviewData.threadStore(),
        draftStore: ThreadDraftStore()
    )
}
#endif
