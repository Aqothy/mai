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

    var queuedPrompts: [QueuedChatPrompt] {
        store.queuedPrompts(for: threadID)
    }

    var canSend: Bool {
        canSend(annotations: [])
    }

    func canSend(annotations: [ChatPendingAnnotation]) -> Bool {
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

    var canForkThread: Bool {
        store.connectionState == .connected
            && store.threadSupportsFork(threadID)
            && !store.threadIsRunning(threadID)
            && !isSending
            && !isForking
            && !isRetryingFailedTurn
    }

    var isErrorPresented: Bool {
        get { errorMessage != nil }
        set {
            if !newValue {
                errorMessage = nil
            }
        }
    }

    func removeQueuedPrompt(_ promptID: String) {
        store.removeQueuedPrompt(threadID: threadID, promptID: promptID)
    }

    func steerQueuedPrompt(_ promptID: String) async {
        do {
            try await store.steerQueuedPrompt(threadID: threadID, promptID: promptID)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func send(annotations annotationModel: ChatAnnotationModel? = nil) async {
        let submittedDraft = text
        let submittedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedAttachments = attachments
        let submittedAttachmentIDs = Set(submittedAttachments.map(\.id))
        let submittedAnnotations = annotationModel?.annotations ?? []
        let submittedAnnotationIDs = Set(submittedAnnotations.map(\.id))
        guard canSend(annotations: submittedAnnotations) else { return }

        isSending = true
        defer { isSending = false }

        do {
            try await store.submitTurn(
                threadID: threadID,
                text: submittedText,
                attachments: submittedAttachments.compactMap(\.attachment),
                annotations: submittedAnnotations.map(\.promptAnnotation)
            )
            if text == submittedDraft,
               draftStore.text(for: threadID) == submittedDraft {
                text = ""
            }
            attachmentsModel.remove(ids: submittedAttachmentIDs)
            // The annotation model may show another chat by now; the draft
            // store owns this chat's annotations either way.
            draftStore.removeAnnotations(ids: submittedAnnotationIDs, for: threadID)
            annotationModel?.removeSent(ids: submittedAnnotationIDs)
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

    func forkThread() async -> String? {
        guard canForkThread else { return nil }

        isForking = true
        defer { isForking = false }

        do {
            return try await store.forkThread(threadID)
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
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
