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
    /// Thread whose initial page has been Markdown-primed off the main actor.
    /// The timeline mounts only after this, so a cold open never parses
    /// synchronously inside view construction.
    @State private var warmedThreadID: String?
    @State private var annotationModel = ChatAnnotationModel()

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
            } else if TranscriptEngine.isNewEngineEnabled, let threadID = store.selectedThread?.id {
                TranscriptChatView(
                    store: store, threadID: threadID, scrollState: scrollState, annotationModel: annotationModel,
                    forkAction: forkAction)
                    .id(threadID)
            } else if let thread = store.selectedThread,
                let segmentCache = store.selectedThreadMarkdownSegmentCache
            {
                if let textLayoutStore = store.selectedThreadTextLayoutStore {
                    // A thread whose initial page is already parsed (a recent
                    // back-navigation, or a small thread the store primed)
                    // mounts immediately instead of flashing a spinner.
                    if warmedThreadID == thread.id
                        || Self.isInitialPagePrimed(
                            thread: thread,
                            segmentCache: segmentCache
                        )
                    {
                        chatTimeline(
                            thread: thread,
                            segmentCache: segmentCache,
                            textLayoutStore: textLayoutStore
                        )
                        .environment(
                            \.attachmentLoader,
                            ChatTranscriptAttachmentLoader(threadID: thread.id) { [store] attachmentID in
                                try await store.attachmentData(attachmentID: attachmentID)
                            }
                        )
                    } else {
                        ProgressView("Loading Chat…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .task(id: thread.id) {
                                await warmInitialPage(
                                    thread: thread,
                                    segmentCache: segmentCache
                                )
                                guard !Task.isCancelled else { return }
                                warmedThreadID = thread.id
                            }
                    }
                }
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
        .onChange(of: dynamicTypeSize) { _, _ in
            // Fonts are baked into each layout. Drop layouts built at
            // the previous Dynamic Type size.
            store.resetSelectedThreadTextLayoutStore()
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

    /// Projects the timeline incrementally: the session invalidates the
    /// projection per event, so steady-state streaming reprojects only the
    /// changed suffix instead of re-walking the whole transcript.
    private func projectedSections(for thread: ThreadDetail)
        -> [ChatTimelineLayout.Section]
    {
        guard let projection = store.selectedThreadTimelineProjection else {
            return ChatTimelineLayout.sections(turns: thread.turns)
        }
        return projection.project(thread.turns)
    }

    /// The rows of the first mounted page, from a full walk of `thread`.
    /// Pre-mount work deliberately bypasses the shared projection: it runs
    /// on a captured thread value that live events may have outdated, and
    /// consuming the projection's watermark against a stale timeline would
    /// leave the mounted timeline showing stale sections.
    private static func initialPageRows(
        of thread: ThreadDetail
    ) -> [ChatTimelineRowModel] {
        ChatTimelineLayout.rows(
            sections: ChatTimeline.initialSections(
                in: ChatTimelineLayout.sections(turns: thread.turns)
            ),
            requests: thread.requests.map(ChatRequest.init(open:)),
            expandedSectionIDs: []
        )
    }

    /// Whether every Markdown parse the initial page's first body would
    /// perform is already cached, so the timeline can mount without a warm
    /// pass. Only cache lookups run here; nothing parses.
    private static func isInitialPagePrimed(
        thread: ThreadDetail,
        segmentCache: ChatMarkdownSegmentCache
    ) -> Bool {
        let pageRows = initialPageRows(of: thread)
        let streamingTurnID = streamingTurnID(of: thread)
        let segmentRequests = ChatMarkdownSegmentCache.primeRequests(
            rows: pageRows,
            streamingTurnID: streamingTurnID
        )
        guard segmentRequests.allSatisfy({
            segmentCache.contains(messageID: $0.messageID, source: $0.source)
        }) else { return false }

        // Segmentation is cached, so planning and row rendering below only
        // read the cache.
        let wholeDocumentRequests = ChatTimeline.wholeDocumentMarkdownRenderRequests(
            in: pageRows,
            streamingTurnID: streamingTurnID,
            segmentCache: segmentCache
        )
        guard wholeDocumentRequests.allSatisfy({
            ChatMarkdownRenderCache.shared.cachedPlan(
                messageID: $0.messageID,
                source: $0.source
            ) != nil
        }) else { return false }

        let renderRequests = ChatTimeline.markdownRenderRequests(
            in: ChatTimeline.renderRows(
                pageRows,
                streamingTurnID: streamingTurnID,
                segmentCache: segmentCache
            ),
            streamingTurnID: streamingTurnID
        )
        return renderRequests.allSatisfy {
            ChatMarkdownRenderCache.shared.cachedPlan(
                messageID: $0.messageID,
                source: $0.source
            ) != nil
        }
    }

    /// Parses the initial page's Markdown off the main actor before the
    /// timeline's first body runs. Without this, every settled message on a
    /// cold open would parse synchronously during view construction.
    private func warmInitialPage(
        thread: ThreadDetail,
        segmentCache: ChatMarkdownSegmentCache
    ) async {
        // The rendered rows are only needed by `prepare`'s layout pass; the
        // pre-mount warm stops at Markdown parsing.
        _ = await ChatTimeline.primeMarkdownCaches(
            timelineRows: Self.initialPageRows(of: thread),
            streamingTurnID: Self.streamingTurnID(of: thread),
            segmentCache: segmentCache
        )
    }

    private func chatTimeline(
        thread: ThreadDetail,
        segmentCache: ChatMarkdownSegmentCache,
        textLayoutStore: ChatTextLayoutStore
    ) -> some View {
        ChatTimeline(
            threadID: thread.id,
            sections: projectedSections(for: thread),
            requests: thread.requests.map(ChatRequest.init(open:)),
            timelineEntryCount: thread.turns.reduce(thread.turns.count) { $0 + $1.entries.count },
            hasOlderTurns: thread.older != nil,
            plan: thread.plan,
            streamingTurnID: Self.streamingTurnID(of: thread),
            segmentCache: segmentCache,
            store: store,
            scrollState: scrollState,
            annotationModel: annotationModel,
            textLayoutStore: textLayoutStore
        )
        .environment(\.chatFork, forkAction)
        .id(thread.id)
        .onAppear {
            // Whether mounted through the warm pass or the primed fast
            // path, later bodies skip the cache probe.
            warmedThreadID = thread.id
        }
    }

    private static func streamingTurnID(of thread: ThreadDetail) -> String? {
        thread.runningTurn?.id
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
