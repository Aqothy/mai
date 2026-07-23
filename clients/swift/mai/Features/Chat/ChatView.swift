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
                VStack(alignment: .leading, spacing: 24) {
                    Text(thread.title)
                        .font(.largeTitle.bold())
                        .foregroundStyle(.primary)
                        .accessibilityHeading(.h1)

                    ContentUnavailableView(
                        "No Messages Yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("The chat timeline is the next feature to implement.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding()
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
