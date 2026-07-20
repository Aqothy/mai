#if os(iOS)
import SwiftUI

struct IOSSidebarView: View {
    let store: ThreadStore
    @Binding var isPresented: Bool

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.threads, id: \.id) { thread in
                    Button {
                        store.selectThread(thread.id)
                        isPresented = false
                    } label: {
                        ThreadRow(thread: thread)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
    }
}

#if DEBUG
#Preview("iOS Sidebar") {
    @Previewable @State var isPresented = true

    NavigationStack {
        IOSSidebarView(
            store: PreviewData.threadStore(),
            isPresented: $isPresented
        )
    }
}
#endif
#endif
