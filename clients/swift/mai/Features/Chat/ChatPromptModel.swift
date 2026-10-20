import Foundation
import Observation
import PhotosUI
import SwiftUI

@Observable
final class ChatPromptModel {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    let store: ThreadStore
    let threadID: String
    let promptCompletion: PromptCompletionModel

    var text: String {
        didSet {
            draftStore.setText(text, for: threadID)
        }
    }
    private(set) var isSending = false
    private(set) var isInterrupting = false
    private(set) var isForking = false
    private(set) var isRetryingFailedTurn = false
    private(set) var settingConfigOptionIDs: Set<String> = []
    private(set) var errorMessage: String?

    private var retryRequestedTurnID: String?

    private let draftStore: ThreadDraftStore
    private let attachmentsModel: ComposerAttachmentsModel

    init(store: ThreadStore, draftStore: ThreadDraftStore, threadID: String) {
        self.store = store
        self.draftStore = draftStore
        self.threadID = threadID
        promptCompletion = PromptCompletionModel(
            store: store,
            scope: .thread(id: threadID)
        )
        text = draftStore.text(for: threadID)
        attachmentsModel = draftStore.attachmentsModel(for: threadID)
        attachmentsModel.reportError = { [weak self] message in
            self?.errorMessage = message
        }
    }

    var attachments: [ChatPendingAttachment] {
        attachmentsModel.attachments
    }

    var queuedPrompts: [QueuedPrompt] {
        store.queuedPrompts(for: threadID)
    }

    /// Queued prompts steer into a running turn, or send as the next turn.
    var isTurnRunning: Bool {
        store.threadIsRunning(threadID)
    }

    /// This chat's unsent annotations; the draft store owns them.
    var annotations: [ChatPendingAnnotation] {
        draftStore.annotations(for: threadID)
    }

    var canSend: Bool {
        store.connectionState == .connected
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty
                || !annotations.isEmpty)
            && attachments.allSatisfy { !$0.isProcessing }
            && !isSending
    }

    var isPromptEnabled: Bool {
        store.connectionState == .connected && !isSending
    }

    var showsFailedTurnRetry: Bool {
        store.failedTurnID(for: threadID) != nil
    }

    var canRetryFailedTurn: Bool {
        guard let failedTurnID = store.failedTurnID(for: threadID) else { return false }
        return store.connectionState == .connected
            && retryRequestedTurnID != failedTurnID
            && !isSending
            && !isRetryingFailedTurn
    }

    var failedTurnError: String? {
        store.failedTurnError(for: threadID)
    }

    /// Why the latest turn ended early, if it did.
    var stopReason: MaidStopReason? {
        store.completedTurnStopReason(for: threadID)
    }

    var failedTurnID: String? {
        store.failedTurnID(for: threadID)
    }

    /// Set when the failed turn's provider needs the user to sign in.
    var signInProviderID: String? {
        failedTurnID == nil ? nil : store.signedOutProviderID(for: threadID)
    }

    func refreshProviderAfterFailedTurn() async {
        await store.refreshProvidersAfterFailure()
    }

    /// A fork keeps the settled turns, so it needs no idle chat.
    var canFork: Bool {
        store.connectionState == .connected && !isForking
    }

    var isErrorPresented: Bool {
        get { errorMessage != nil }
        set {
            if !newValue {
                errorMessage = nil
            }
        }
    }

    func removeQueuedPrompt(_ messageID: String) async {
        do {
            try await store.removeQueuedPrompt(threadID: threadID, messageID: messageID)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendQueuedPrompt(_ messageID: String) async {
        do {
            try await store.sendQueuedPrompt(threadID: threadID, messageID: messageID)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func send(_ mode: PromptSendMode) async {
        let submittedDraft = text
        let submittedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedAttachments = attachments
        let submittedAttachmentIDs = Set(submittedAttachments.map(\.id))
        let submittedAnnotations = annotations
        let submittedAnnotationIDs = Set(submittedAnnotations.map(\.id))
        guard canSend else { return }

        isSending = true
        defer { isSending = false }

        let fileLinks = store.workingDirectory(forThread: threadID).map {
            promptCompletion.fileMentionLinks(in: submittedText, directory: $0)
        } ?? []

        do {
            try await store.submitTurn(
                threadID: threadID,
                text: submittedText,
                attachments: submittedAttachments.compactMap(\.attachment) + fileLinks,
                annotations: submittedAnnotations.map(\.promptAnnotation),
                mode: mode
            )
            promptCompletion.clearMentionedFiles()
            if text == submittedDraft,
               draftStore.text(for: threadID) == submittedDraft {
                text = ""
            }
            attachmentsModel.remove(ids: submittedAttachmentIDs)
            draftStore.removeAnnotations(ids: submittedAnnotationIDs, for: threadID)
            // The daemon accepted this prompt; persist the cleared draft now so
            // an exit within the save debounce cannot restore it as unsent.
            draftStore.flushPendingSave()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addImages(from urls: [URL]) async {
        await attachmentsModel.addImages(from: urls)
    }

    func addPhotos(_ photos: [PhotosPickerItem]) {
        attachmentsModel.addPhotos(photos)
    }

    func addCameraImage(_ thumbnail: ChatComposerThumbnail) {
        attachmentsModel.addCameraImage(thumbnail)
    }

    func removeAttachment(id: UUID) {
        attachmentsModel.remove(id: id)
    }

    func showError(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    func interrupt(turnID: String) async {
        guard !isInterrupting, store.connectionState == .connected else { return }

        isInterrupting = true
        defer { isInterrupting = false }

        do {
            try await store.interruptTurn(threadID: threadID, turnID: turnID)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Forks this chat at `point`, into another agent when `agentID` names
    /// one, with `prompt` waiting in the fork's composer when editing an
    /// earlier prompt.
    func fork(at point: ChatForkPoint, into agentID: String? = nil, editing prompt: Message? = nil) async -> ChatFork? {
        guard canFork else { return nil }

        isForking = true
        defer { isForking = false }

        do {
            let fork = try await store.forkThread(threadID, at: point, into: agentID)
            let composerID =
                switch fork {
                case .thread(let forkThreadID): forkThreadID
                case .draft(let draft): draftStore.startForkDraft(draft)
                }
            if let prompt {
                compose(prompt, in: composerID)
            }
            return fork
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Puts a sent prompt in another chat's composer to edit: its text, its
    /// comments, and its images, which load from this chat.
    private func compose(_ prompt: Message, in composerID: String) {
        draftStore.setText(prompt.text, for: composerID)
        draftStore.setAnnotations((prompt.annotations ?? []).map(ChatPendingAnnotation.init), for: composerID)
        let images = (prompt.attachments ?? []).filter { $0.kind == MaidAttachmentKind.image.rawValue }
        let sourceThreadID = threadID
        draftStore.attachmentsModel(for: composerID).addSentImages(images) { [store] image in
            if let data = image.data, !data.isEmpty { return data }
            guard let attachmentID = image.id else { throw RPCError("“\(image.name ?? "Image")” has no data") }
            return try await store.attachmentData(threadID: sourceThreadID, attachmentID: attachmentID)
        }
    }

    func retryFailedTurn() async {
        guard canRetryFailedTurn,
            let failedTurnID = store.failedTurnID(for: threadID)
        else { return }

        retryRequestedTurnID = failedTurnID
        isRetryingFailedTurn = true
        defer { isRetryingFailedTurn = false }

        do {
            try await store.retryFailedTurn(threadID: threadID)
        } catch is CancellationError {
            retryRequestedTurnID = nil
        } catch {
            retryRequestedTurnID = nil
            errorMessage = error.localizedDescription
        }
    }

    func setConfigOption(_ optionID: String, value: JSONAny) async {
        guard !settingConfigOptionIDs.contains(optionID),
              store.connectionState == .connected else { return }

        settingConfigOptionIDs.insert(optionID)
        defer { settingConfigOptionIDs.remove(optionID) }

        do {
            try await store.setThreadConfigOption(
                threadID: threadID,
                optionID: optionID,
                value: value
            )
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func isSettingConfigOption(_ optionID: String) -> Bool {
        settingConfigOptionIDs.contains(optionID)
    }

    func insertSlashCommand(_ command: SlashCommand) {
        let insertion = "/\(command.name)"
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = command.hasInput == true ? "\(insertion) " : insertion
        } else {
            text += text.last?.isWhitespace == true ? insertion : " \(insertion)"
            if command.hasInput == true {
                text += " "
            }
        }
    }
}
