import SwiftUI

/// A chat's transcript on the new engine, on both platforms. The controller
/// lives as long as this view's identity (one per chat), so a chat shown
/// again keeps its place.
struct TranscriptChatView: View {
    let store: ThreadStore
    let threadID: String
    /// The composer's Send asks the old scroll state for a jump; the new
    /// transcript answers it until the composer talks to the controller.
    let scrollState: ChatScrollState
    let annotationModel: ChatAnnotationModel
    let forkAction: ChatForkAction?

    @State private var controller = TranscriptController()
    #if os(iOS)
        @State private var insets = EdgeInsets()
    #endif

    var body: some View {
        TranscriptView(
            controller: controller,
            onComment: { quote, messageID, role in
                annotationModel.beginComment(quote: quote, messageID: messageID, role: role)
            },
            forkMenu: forkAction.map { fork in { turnID in forkMenu(turnID: turnID, fork: fork) } }
        )
        #if os(iOS)
            .viewportInsets(insets)
            // The scroll view runs under the navigation bar, the composer and
            // the keyboard; their heights reach it as insets.
            .ignoresSafeArea(edges: .vertical)
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets = $0 }
        #endif
        .overlay(alignment: .top) {
            if store.isLoadingOlderTurns {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 8)
                    .accessibilityLabel("Loading earlier messages")
                    .allowsHitTesting(false)
            }
        }
        .onAppear { controller.start(store: store, threadID: threadID) }
        .onChange(of: controller.isEndVisible, initial: true) { _, isEndVisible in
            if scrollState.isNearBottom != isEndVisible {
                scrollState.isNearBottom = isEndVisible
            }
        }
        .onChange(of: scrollState.bottomScrollRequest) { _, request in
            controller.jumpToEnd(animated: request.animated)
        }
    }

    /// The chat's fork menu for a finished turn: fork through it, edit its
    /// prompt in a new chat, or continue in another agent.
    private func forkMenu(turnID: String, fork: ChatForkAction) -> TranscriptMenu {
        let prompt = store.selectedThread?.turns.first { $0.id == turnID }?.entries
            .first { $0.itemKind == .userMessage }
            .map { ChatMessage(turnID: turnID, entry: $0) }
        var items = [
            TranscriptMenu.Item(title: "Fork from Here", systemImage: "arrow.triangle.branch") {
                fork(.through(turnID: turnID))
            }
        ]
        if let prompt {
            items.append(
                TranscriptMenu.Item(title: "Edit Prompt in New Chat", systemImage: "pencil") {
                    fork(.before(turnID: turnID), editing: prompt)
                })
        }
        if !fork.otherAgents.isEmpty {
            items.append(
                TranscriptMenu.Item(
                    title: "Continue in", systemImage: "arrow.forward.circle",
                    children: fork.otherAgents.map { agent in
                        TranscriptMenu.Item(title: agent.title) { fork(.through(turnID: turnID), into: agent.id) }
                    }))
        }
        return TranscriptMenu(items: items)
    }
}
