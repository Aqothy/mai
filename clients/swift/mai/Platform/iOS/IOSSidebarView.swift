#if os(iOS)
import SwiftUI

struct IOSSidebarView: View {
    let threads: [ThreadListEntry]
    @Binding var isPresented: Bool

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(threads, id: \.id) { thread in
                    Button {
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
            threads: PreviewData.threads,
            isPresented: $isPresented
        )
    }
}
#endif
#endif
