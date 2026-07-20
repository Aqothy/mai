import SwiftUI

struct ChatView: View {
    let thread: Thread?
    let errorMessage: String?

    var body: some View {
        Group {
            if let thread {
                ContentUnavailableView(
                    thread.title,
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("The chat timeline is the next feature to implement.")
                )
                .navigationTitle(thread.title)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Unable to Load Thread",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
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
            errorMessage: nil
        )
    }
}

#Preview("Empty Chat") {
    ChatView(thread: nil, errorMessage: nil)
}
#endif
