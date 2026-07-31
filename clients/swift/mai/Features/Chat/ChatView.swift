import SwiftUI

struct ChatView: View {
    let store: ThreadStore

    @State private var draftModel: DraftPromptModel
    @State private var chatModel: ChatPromptModel?

    init(store: ThreadStore, draftStore: ThreadDraftStore) {
        self.store = store
        _draftModel = State(initialValue: DraftPromptModel(store: store, draftStore: draftStore))
    }

    var body: some View {
        content
            .safeAreaInset(edge: .bottom) {
                composerStack
            }
            .onChange(of: store.selectedThreadID, initial: true) { _, threadID in
                if let threadID {
                    if chatModel?.threadID != threadID {
                        chatModel = ChatPromptModel(store: store, threadID: threadID)
                    }
                } else {
                    chatModel = nil
                }
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

    @ViewBuilder
    private var content: some View {
        if let errorMessage = store.selectedThreadLoadErrorMessage {
            ThreadLoadErrorView(store: store, errorMessage: errorMessage)
        } else if let thread = store.selectedThread {
            VStack(alignment: .leading) {
                Text(thread.title)
                    .font(.largeTitle.bold())
                    .accessibilityHeading(.h1)

                if thread.latestTurn?.turnState == .error {
                    FailedTurnView(store: store, thread: thread)
                        .id(thread.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "No Messages Yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("The chat timeline is the next feature to implement.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding()
        } else if store.selectedThreadID != nil {
            ProgressView("Loading Chat…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DraftPromptView(model: draftModel)
        }
    }

    /// One composer for both the draft and thread phases. Its structural
    /// identity never changes across the transition, so the text field (and
    /// keyboard focus) survives sending the first message; only the bindings
    /// and controls around it swap.
    private var composerStack: some View {
        let thread = store.selectedThread

        return VStack(alignment: .leading) {
            if chatModel == nil {
                HStack(spacing: 16) {
                    DraftSessionControlsView(model: draftModel)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 10)
            } else if let chatModel, !chatModel.queuedPrompts.isEmpty {
                ChatPromptQueueView(model: chatModel)
            }

            PromptComposer(
                text: promptText,
                isEnabled: chatModel == nil
                    ? draftModel.isPromptEnabled
                    : thread != nil && chatModel?.isPromptEnabled == true,
                focusID: chatModel == nil ? draftModel.promptFocusID : nil,
                canSend: chatModel == nil
                    ? draftModel.canSend
                    : thread != nil && chatModel?.canSend == true,
                isSending: isSendingNow,
                isRunning: thread?.latestTurn?.turnState == .running,
                isStopping: chatModel?.isInterrupting == true,
                attachments: currentAttachments,
                submitLabel: chatModel == nil ? "Start chat" : "Send"
            ) {
                if let chatModel {
                    Task { await chatModel.send() }
                } else {
                    Task { await draftModel.send() }
                }
            } stop: {
                if let chatModel, let turnID = thread?.latestTurn?.turnID {
                    Task { await chatModel.interrupt(turnID: turnID) }
                }
            } removeAttachment: { id in
                if let chatModel {
                    chatModel.removeAttachment(id: id)
                } else {
                    draftModel.removeAttachment(id: id)
                }
            } leadingControls: {
                ComposerAddMenu(
                    isImageAttachmentAvailable: supportsImageAttachments,
                    isImageAttachmentDisabled: isSendingNow
                        || currentAttachments.count
                            >= ChatAttachmentLoader.maximumAttachmentCount,
                    maximumImageSelectionCount: max(
                        1,
                        ChatAttachmentLoader.maximumAttachmentCount - currentAttachments.count
                    ),
                    commands: thread?.session?.slashCommands ?? [],
                    addImages: chatModel?.addImages ?? draftModel.addImages,
                    addPhotos: chatModel?.addPhotos ?? draftModel.addPhotos,
                    addCameraImage: chatModel?.addCameraImage ?? draftModel.addCameraImage,
                    insertCommand: chatModel?.insertSlashCommand ?? { _ in },
                    showError: chatModel?.showError ?? draftModel.showError
                )
            } trailingControls: {
                if let chatModel, let thread {
                    ChatComposerControlsView(thread: thread, model: chatModel)
                } else if chatModel == nil {
                    DraftComposerControlsView(model: draftModel)
                }
            }
        }
    }

    private var promptText: Binding<String> {
        Binding(
            get: {
                if let chatModel {
                    chatModel.text
                } else {
                    draftModel.prompt
                }
            },
            set: { newValue in
                if let chatModel {
                    chatModel.text = newValue
                } else {
                    draftModel.prompt = newValue
                }
            }
        )
    }

    private var currentAttachments: [ChatPendingAttachment] {
        chatModel?.attachments ?? draftModel.attachments
    }

    private var isSendingNow: Bool {
        chatModel?.isSending ?? draftModel.isSending
    }

    private var supportsImageAttachments: Bool {
        if chatModel != nil {
            return store.promptContentCapabilities(
                for: store.selectedThread?.providerInstanceID
            )?.image == true
        }
        return draftModel.supportsImageAttachments
    }
}

/// A panel of queued prompts whose bottom edge tucks behind the composer so
/// the two read as one connected surface.
private struct ChatPromptQueueView: View {
    let model: ChatPromptModel

    /// Matches the composer's corner radius; the panel extends this far
    /// beneath the composer to close the gap left by its rounded corners.
    private let composerOverlap: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            ForEach(model.queuedPrompts) { prompt in
                QueuedPromptRow(model: model, prompt: prompt)
            }
        }
        .padding(.bottom, composerOverlap)
        .background(
            .regularMaterial,
            in: .rect(topLeadingRadius: 20, topTrailingRadius: 20)
        )
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.bottom, -composerOverlap)
    }
}

private struct QueuedPromptRow: View {
    let model: ChatPromptModel
    let prompt: QueuedChatPrompt

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.turn.down.right")
                .foregroundStyle(.secondary)

            Text(prompt.text.isEmpty
                ? "\(prompt.attachments.count) attachment(s)"
                : prompt.text)
                .lineLimit(1)

            Spacer()

            Button("Steer", systemImage: "arrow.triangle.branch") {
                Task { await model.steerQueuedPrompt(prompt.id) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button("Remove queued prompt", systemImage: "trash") {
                model.removeQueuedPrompt(prompt.id)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
            Button("Retry", action: store.retry)
        }
    }
}

private struct FailedTurnView: View {
    let store: ThreadStore
    let thread: Thread

    @State private var isRetrying = false
    @State private var retryError: String?

    var body: some View {
        ContentUnavailableView {
            Label("Couldn’t Start Chat", systemImage: "exclamationmark.triangle")
        } description: {
            VStack {
                Text(thread.latestTurn?.error ?? "The provider could not start the turn.")
                if let retryError {
                    Text(retryError)
                        .foregroundStyle(.red)
                }
            }
        } actions: {
            Button(isRetrying ? "Retrying…" : "Retry") {
                retry()
            }
            .disabled(isRetrying || store.connectionState != .connected)
        }
    }

    private func retry() {
        guard !isRetrying, store.connectionState == .connected else { return }
        isRetrying = true
        retryError = nil
        Task {
            defer { isRetrying = false }
            do {
                try await store.retryFailedTurn(threadID: thread.id)
            } catch {
                retryError = error.localizedDescription
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
