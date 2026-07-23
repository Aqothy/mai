import SwiftUI

struct ChatView: View {
    let thread: Thread?
    let errorMessage: String?
    let retry: () -> Void

    var body: some View {
        Group {
            if let errorMessage {
                ContentUnavailableView {
                    Label("Unable to Load Thread", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry", action: retry)
                }
            } else if let thread {
                ContentUnavailableView(
                    thread.title,
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("The chat timeline is the next feature to implement.")
                )
                .navigationTitle(thread.title)
            } else {
                ContentUnavailableView(
                    "No Thread Selected",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Select a thread from the sidebar.")
                )
            }
        }
    }
}

#if DEBUG
#Preview("Selected Chat") {
    NavigationStack {
        ChatView(
            thread: PreviewData.selectedThread,
            errorMessage: nil,
            retry: {}
        )
    }
}

#Preview("Empty Chat") {
    ChatView(thread: nil, errorMessage: nil, retry: {})
}
#endif
