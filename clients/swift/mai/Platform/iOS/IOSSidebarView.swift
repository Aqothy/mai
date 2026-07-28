#if os(iOS)
import SwiftUI

struct IOSSidebarView: View {
    let store: ThreadStore
    @Binding var isPresented: Bool

    var body: some View {
        ScrollView {
            LazyVStack {
                Button("New Chat", systemImage: "square.and.pencil") {
                    store.startNewDraft()
                    isPresented = false
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .padding(.top, 48)

                ForEach(store.threads, id: \.id) { thread in
                    Button {
                        store.selectThread(thread.id)
                        isPresented = false
                    } label: {
                        ThreadRow(thread: thread)
                            .frame(minHeight: 36)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
        .modifier(ThreadListStatusModifier(store: store))
    }
}

#if DEBUG
#Preview("iOS Sidebar") {
    @Previewable @State var isPresented = true

    IOSSidebarView(store: PreviewData.threadStore(), isPresented: $isPresented)
}
#endif
#endif
