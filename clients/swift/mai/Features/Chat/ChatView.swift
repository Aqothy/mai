import Observation
import SwiftUI

struct ChatView: View {
    let store: ThreadStore
    let draftStore: ThreadDraftStore
    let openThread: ((String) -> Void)?
    /// Shows the new-chat draft.
    let openDraft: (() -> Void)?

    @State private var draftModel: DraftPromptModel
    @State private var chatModel: ChatPromptModel?
    @State private var scrollState = ChatScrollState()
    @State private var annotationModel = ChatAnnotationModel()

    init(
        store: ThreadStore,
        draftStore: ThreadDraftStore,
        initialWorkingDirectory: String? = nil,
        openThread: ((String) -> Void)? = nil,
        openDraft: (() -> Void)? = nil
    ) {
        self.store = store
        self.draftStore = draftStore
        self.openThread = openThread
        self.openDraft = openDraft
        _draftModel = State(
            initialValue: DraftPromptModel(
                store: store,
                draftStore: draftStore,
                initialWorkingDirectory: initialWorkingDirectory
            )
        )
        _chatModel = State(
            initialValue: store.selectedThreadID.map {
                ChatPromptModel(
                    store: store,
                    draftStore: draftStore,
                    threadID: $0
                )
            }
        )
    }

    var body: some View {
        let promptText = currentPromptText
        let promptCompletion = currentPromptCompletion

        Group {
            if let errorMessage = store.selectedThreadLoadErrorMessage, store.selectedThread == nil {
                ThreadLoadErrorView(store: store, errorMessage: errorMessage)
            } else if let threadID = store.selectedThread?.id {
                TranscriptChatView(
                    store: store, threadID: threadID, scrollState: scrollState, annotationModel: annotationModel,
                    forkAction: forkAction)
                    .id(threadID)
            } else if store.selectedThreadID != nil {
                ProgressView("Loading Chat…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DraftPromptView(model: draftModel)
            }
        }
        .overlay(alignment: .bottom) {
            if store.selectedThread != nil {
                ViewThatFits(in: .vertical) {
                    ChatScrollToBottomButton(scrollState: scrollState) {
                        scrollState.requestScrollToBottom(animated: true)
                    }
                    .safeAreaPadding(.vertical)

                    // A landscape keyboard can leave no transcript space
                    // between the navigation bar and composer.
                    Color.clear
                        .frame(height: 0)
                        .allowsHitTesting(false)
                }
            }
        }
        .overlay(alignment: .bottom) {
            // This overlay belongs to the full chat surface. Rendering it
            // outside the safe-area bar's bounds would make its visible rows
            // miss taps and scrolling gestures.
            ChatPromptCompletionOverlay(
                text: promptText,
                model: promptCompletion
            )
            .safeAreaPadding(.bottom)
        }
        .modifier(
            ChatBenchmarkChrome(
                chrome: ChatComposerSafeAreaBar(
                    composer: ChatComposerStack(
                        store: store,
                        draftModel: draftModel,
                        chatModel: chatModel,
                        annotationModel: annotationModel,
                        scrollState: scrollState,
                        promptText: promptText,
                        promptCompletion: promptCompletion,
                        openThread: openThread
                    )
                )
            )
        )
        .navigationTitle(selectedThreadTitle)
        .inlineNavigationBarTitle()
        .toolbar {
            if let chatModel, let forkAction, ChatBenchmarkChrome<EmptyModifier>.isShown {
                ToolbarItem(placement: .primaryAction) {
                    Menu("Fork Chat", systemImage: "arrow.triangle.branch") {
                        ForEach(forkAction.otherAgents) { agent in
                            Button("Continue in \(agent.title)") {
                                forkAction(.latest, into: agent.id)
                            }
                        }
                    } primaryAction: {
                        forkAction(.latest)
                    }
                    .disabled(!chatModel.canFork)
                    .accessibilityHint("Creates a new chat from this conversation’s finished turns")
                }
            }
        }
        .onChange(of: store.selectedThreadID, initial: true) {
            previousThreadID,
            threadID in
            if previousThreadID != threadID {
                currentPromptCompletion.dismiss()
            }
            annotationModel.show(threadID: threadID, draftStore: draftStore)
            if previousThreadID != threadID, previousThreadID != nil {
                scrollState.reset()
            }
            if let threadID {
                if chatModel?.threadID != threadID {
                    chatModel = ChatPromptModel(
                        store: store,
                        draftStore: draftStore,
                        threadID: threadID
                    )
                }
            } else {
                chatModel = nil
            }
        }
        .sheet(
            isPresented: Binding(
                get: { annotationModel.editorDraft != nil },
                set: { isPresented in
                    if !isPresented {
                        annotationModel.cancelEditor()
                    }
                }
            )
        ) {
            ChatAnnotationEditor(model: annotationModel)
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { chatModel?.isErrorPresented ?? false },
                set: { chatModel?.isErrorPresented = $0 }
            )
        ) {
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(chatModel?.errorMessage ?? "An unknown error occurred.")
        }
    }

    /// Opens a new-chat draft that forks the open chat.
    private var forkAction: ChatForkAction? {
        guard let chatModel, let openDraft else { return nil }
        let agentID = store.selectedThread?.addressee?.instance
        return ChatForkAction(otherAgents: store.availableProviders.filter { $0.id != agentID }) { point, agent, prompt in
            Task {
                if await chatModel.fork(at: point, into: agent, editing: prompt) {
                    openDraft()
                }
            }
        }
    }

    private var selectedThreadTitle: String {
        if let title = store.selectedThread?.summary.title {
            return title
        }
        return store.selectedThreadTitle ?? ""
    }

    private var currentPromptText: Binding<String> {
        if let chatModel {
            @Bindable var chatModel = chatModel
            return $chatModel.text
        }
        @Bindable var draftModel = draftModel
        return $draftModel.prompt
    }

    private var currentPromptCompletion: PromptCompletionModel {
        chatModel?.promptCompletion ?? draftModel.promptCompletion
    }
}

private struct ThreadLoadErrorView: View {
    let store: ThreadStore
    let errorMessage: String

    var body: some View {
        ContentUnavailableView {
            Label("Unable to Load Thread", systemImage: "exclamationmark.triangle")
        } description: {
            Text(errorMessage)
        } actions: {
            Button("Retry") {
                store.retry()
            }
        }
    }
}

#if DEBUG
    #Preview("Selected Chat") {
        NavigationStack {
            ChatView(
                store: PreviewData.threadStore(),
                draftStore: ThreadDraftStore()
            )
        }
    }

    #Preview("Draft Chat") {
        ChatView(
            store: ThreadStore(previewThreads: PreviewData.threads),
            draftStore: ThreadDraftStore()
        )
    }
#endif
