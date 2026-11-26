import SwiftUI

/// Keeps one composer identity across draft-to-thread transitions.
struct ChatComposerStack: View {
    let store: ThreadStore
    let draftModel: DraftPromptModel
    let chatModel: ChatPromptModel?
    let annotationModel: ChatAnnotationModel
    let scrollState: ChatScrollState
    let promptText: Binding<String>
    let promptCompletion: PromptCompletionModel
    let openThread: ((String) -> Void)?

    var body: some View {
        let state = ChatComposerThreadState(thread: store.selectedThread)

        VStack(alignment: .leading) {
            if chatModel != nil, let openThread, let thread = store.selectedThread {
                let origin = thread.summary.origin
                let parent = origin.parent.flatMap { id in store.threads.first { $0.id == id } }
                let forkedFrom = origin.forkedFrom.flatMap { fork in store.threads.first { $0.id == fork.thread } }
                if parent != nil || forkedFrom != nil || !thread.children.isEmpty {
                    ChatThreadTreeBar(parent: parent, forkedFrom: forkedFrom, children: thread.children, openThread: openThread)
                }
            }

            if let chatModel, chatModel.failedTurnID != nil {
                ChatFailedTurnView(model: chatModel)
            } else if let reason = chatModel?.stopReason {
                ChatTurnStopNoticeView(reason: reason)
            }

            if let chatModel, let hold = state.hold {
                ChatHoldView(model: chatModel, hold: hold)
            }

            if let threadID = state.threadID, !state.openRequests.isEmpty {
                ChatOpenRequestsView(requests: state.openRequests, threadID: threadID, store: store)
            }

            if chatModel != nil, state.exists, !state.acceptsInput {
                Label("The agent that started this subagent directs it.", systemImage: "person.2")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: ChatContentMetrics.maximumWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            if chatModel != nil, let goal = state.participant?.goal {
                ChatGoalStatusView(goal: goal)
            }

            if chatModel == nil {
                HStack(spacing: 16) {
                    DraftSessionControlsView(model: draftModel)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(
                    maxWidth: ChatContentMetrics.maximumWidth,
                    alignment: .leading
                )
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .padding(.bottom, 10)
            } else if let chatModel, state.hasQueue {
                ChatPromptQueueView(model: chatModel)
            }

            PromptComposer(
                text: promptText,
                isEnabled: chatModel == nil
                    ? draftModel.isPromptEnabled
                    : state.acceptsInput && chatModel?.isPromptEnabled == true,
                focusID: chatModel == nil ? draftModel.promptFocusID : nil,
                canSend: chatModel == nil
                    ? draftModel.canSend
                    : state.acceptsInput && chatModel?.canSend == true,
                isSending: isSendingNow,
                isRunning: state.isRunning,
                isStopping: chatModel?.isInterrupting == true,
                attachments: currentAttachments,
                annotations: chatModel?.annotations ?? draftModel.annotations,
                promptCompletion: promptCompletion,
                commands: state.slashCommands,
                skills: state.skills,
                submitLabel: chatModel == nil ? "Start chat" : "Send"
            ) { mode in
                if let chatModel {
                    // Sending is explicit intent to see the new turn, even
                    // after the reader scrolled away or expanded content.
                    scrollState.requestScrollToBottom(animated: true)
                    Task { await chatModel.send(mode) }
                } else {
                    Task { await draftModel.send() }
                }
            } stop: {
                if let chatModel, state.isRunning {
                    Task { await chatModel.interrupt() }
                }
            } removeAttachment: { id in
                if let chatModel {
                    chatModel.removeAttachment(id: id)
                } else {
                    draftModel.removeAttachment(id: id)
                }
            } removeAnnotation: { id in
                if chatModel == nil {
                    draftModel.removeAnnotation(id: id)
                } else {
                    annotationModel.remove(id: id)
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
                    commands: state.slashCommands,
                    addWorkspaceFile: promptCompletion.isFileCompletionAvailable && !isSendingNow
                        ? {
                            presentWorkspaceFileCompletionAtPromptEnd()
                        }
                        : nil,
                    addImages: chatModel?.addImages ?? draftModel.addImages,
                    addPhotos: chatModel?.addPhotos ?? draftModel.addPhotos,
                    addCameraImage: chatModel?.addCameraImage ?? draftModel.addCameraImage,
                    insertCommand: chatModel?.insertSlashCommand ?? { _ in },
                    showError: chatModel?.showError ?? draftModel.showError
                )
            } trailingControls: {
                if let chatModel, state.exists {
                    ChatComposerControlsView(
                        participant: state.participant,
                        model: chatModel
                    )
                } else if chatModel == nil {
                    DraftComposerControlsView(model: draftModel)
                }
            }
        }
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
                for: store.selectedThread?.addressee?.instance
            )?.image == true
        }
        return draftModel.supportsImageAttachments
    }

    private func presentWorkspaceFileCompletionAtPromptEnd() {
        promptText.wrappedValue = promptCompletion.textByPresentingFileCompletion(
            in: promptText.wrappedValue
        )
    }
}

private struct ChatOpenRequestsView: View {
    private static let maximumHeight: CGFloat = 280

    let requests: [ChatRequest]
    let threadID: String
    let store: ThreadStore

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(requests) { request in
                    ChatRequestRow(request: request, threadID: threadID, store: store)
                        .id("\(threadID)|\(request.id)")
                        .frame(maxWidth: ChatContentMetrics.maximumWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: contentHeight > 0 ? min(contentHeight, Self.maximumHeight) : Self.maximumHeight)
    }
}

/// The composer needs a handful of thread fields, not the thread's turns.
/// Capturing this projection in its view-builder closures keeps the store's
/// turns uniquely owned while text streams into the running one.
private struct ChatComposerThreadState {
    let exists: Bool
    let threadID: String?
    /// A native subagent its provider gives no input to only shows what its
    /// parent agent has it do.
    let acceptsInput: Bool
    let isRunning: Bool
    let hold: MaidHold?
    let participant: ParticipantView?
    let slashCommands: [SlashCommand]
    let skills: [Skill]
    let hasQueue: Bool
    let openRequests: [ChatRequest]

    init(thread: ThreadDetail?) {
        exists = thread != nil
        threadID = thread?.id
        acceptsInput = thread?.summary.origin.acceptsInput == true
        isRunning = thread?.status == .running
        hold = thread?.summary.holdReason
        participant = thread?.addressee
        slashCommands = participant?.commands ?? []
        skills = participant?.skills ?? []
        hasQueue = thread?.queue.isEmpty == false
        openRequests = (thread?.requests ?? []).map(ChatRequest.init(open:))
    }
}

struct ChatPromptCompletionOverlay: View {
    private static let composerSpacing: CGFloat = 8

    @Binding var text: String
    let model: PromptCompletionModel

    var body: some View {
        if model.isPresented {
            PromptCompletionView(model: model) { match in
                insertCompletion(match)
            }
            .frame(maxWidth: ChatContentMetrics.maximumWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.bottom, Self.composerSpacing)
        }
    }

    private func insertCompletion(_ match: PromptCompletionMatch) {
        guard let edit = model.edit(selecting: match, in: text) else { return }
        text = edit.text
    }
}

struct ChatComposerSafeAreaBar<Composer: View>: ViewModifier {
    let composer: Composer

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    composer
                }
        } else {
            content
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    composer
                }
        }
    }
}
