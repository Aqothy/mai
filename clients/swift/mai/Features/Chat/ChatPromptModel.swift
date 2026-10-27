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
    private(set) var settingConfigOptionIDs: Set<String> = []
    private(set) var errorMessage: String?

    /// A send that failed without an answer, which may have reached the
    /// daemon: sending the same message again reuses its key, so it lands
    /// once.
    private var unansweredSend: (attempt: SendAttempt, key: String)?

    private struct SendAttempt: Equatable {
        let text: String
        let attachmentIDs: Set<UUID>
        let annotationIDs: Set<String>
        let mode: PromptSendMode
    }

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

    /// Messages waiting for the running turn, and those that didn't get
    /// through.
    var queue: [DeliveryView] {
        store.queue(for: threadID)
    }

    /// Waiting messages steer into a running turn, or send as the next turn.
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

    /// A fork chooses from the chat's turns and asks the daemon how it
    /// starts; it needs no idle chat.
    var canFork: Bool {
        forkSource != nil && !isForking
    }

    private var forkSource: ThreadDetail? {
        store.selectedThreadID == threadID ? store.selectedThread : nil
    }

    var isErrorPresented: Bool {
        get { errorMessage != nil }
        set {
            if !newValue {
                errorMessage = nil
            }
        }
    }

    /// Runs a queue action, reporting its failure.
    private func perform(_ action: () async throws -> Void) async {
        do {
            try await action()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Takes back a waiting message: the agent never gets it, and a prompt of
    /// the person's returns to the composer, ahead of what they've typed since.
    func cancel(_ delivery: DeliveryView) async {
        await perform {
            try await store.cancel(delivery: delivery.id)
            guard delivery.kind == MaidDeliveryKind.prompt.rawValue else { return }
            text = [delivery.text ?? "", text].filter { !$0.isEmpty }.joined(separator: "\n\n")
            draftStore.setAnnotations(
                (delivery.annotations ?? []).map(ChatPendingAnnotation.init) + draftStore.annotations(for: threadID),
                for: threadID
            )
            addSentImages(delivery.attachments ?? [], to: attachmentsModel)
        }
    }

    func sendNow(_ delivery: DeliveryView) async {
        await perform { try await store.sendNow(delivery: delivery.id) }
    }

    /// Sends again a message that didn't get through.
    func retry(_ delivery: DeliveryView) async {
        await perform { try await store.retry(delivery: delivery.id) }
    }

    /// Moves a waiting message before another, or last.
    func move(_ delivery: DeliveryView, before: DeliveryView?) async {
        await perform { try await store.move(delivery: delivery.id, before: before?.id) }
    }

    /// Lets the chat's held queue go on.
    func continueThread() async {
        await perform { try await store.continueThread(threadID: threadID) }
    }

    /// Stops this chat and every chat it started.
    func stopTree() async {
        await perform { try await store.stopThread(threadID: threadID) }
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

        let attempt = SendAttempt(text: submittedText, attachmentIDs: submittedAttachmentIDs, annotationIDs: submittedAnnotationIDs, mode: mode)
        let key = unansweredSend?.attempt == attempt ? unansweredSend!.key : UUID().uuidString
        let fileLinks = store.workingDirectory(forThread: threadID).map {
            promptCompletion.fileMentionLinks(in: submittedText, directory: $0)
        } ?? []

        do {
            try await store.submitTurn(
                threadID: threadID,
                text: submittedText,
                attachments: submittedAttachments.compactMap(\.attachment) + fileLinks,
                annotations: submittedAnnotations.map(\.promptAnnotation),
                mode: mode,
                key: key
            )
            unansweredSend = nil
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
            unansweredSend = (attempt, key)
        } catch {
            unansweredSend = (attempt, key)
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

    func interrupt() async {
        guard !isInterrupting, store.connectionState == .connected else { return }

        isInterrupting = true
        defer { isInterrupting = false }

        do {
            try await store.interruptTurn(threadID: threadID)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Starts a new-chat draft that forks this chat at `point`, into another
    /// agent when `agentID` names one. Its composer holds the conversation's
    /// summary where the agent can't fork its own session, then `prompt` when
    /// editing an earlier one. Nothing exists on the daemon until it is sent.
    func fork(at point: ChatForkPoint, into agentID: String? = nil, editing prompt: ChatMessage? = nil) async -> Bool {
        guard let source = forkSource else { return false }
        let turns = source.turns
        let throughTurnID: String?
        switch point {
        case .latest:
            throughTurnID = turns.last { $0.state != MaidTurnState.running.rawValue }?.id
        case .through(let turnID):
            throughTurnID = turnID
        case .before(let turnID):
            let index = turns.firstIndex { $0.id == turnID }
            throughTurnID = index.flatMap { $0 > 0 ? turns[$0 - 1].id : nil }
        }
        var preview = ForkPreview(native: false, summary: nil)
        if throughTurnID != nil {
            isForking = true
            defer { isForking = false }
            do {
                preview = try await store.forkPreview(threadID, throughTurnID: throughTurnID, agentID: agentID)
            } catch is CancellationError {
                return false
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
        let draftID = draftStore.startForkDraft(ForkDraft(
            sourceThreadID: threadID,
            sourceTitle: source.summary.title,
            throughTurnID: throughTurnID,
            native: preview.native,
            agentID: agentID ?? source.addressee?.instance,
            cwd: source.summary.workspace.cwd,
            additionalDirectories: source.summary.workspace.additionalDirectories ?? []
        ))
        if let prompt {
            compose(prompt, in: draftID)
        }
        if let summary = preview.summary, !summary.isEmpty {
            draftStore.setText(summary + draftStore.text(for: draftID), for: draftID)
        }
        return true
    }

    /// Puts a sent prompt in another chat's composer to edit: its text, its
    /// comments, and its images, which load from this chat.
    private func compose(_ prompt: ChatMessage, in composerID: String) {
        draftStore.setText(prompt.text, for: composerID)
        draftStore.setAnnotations((prompt.annotations ?? []).map(ChatPendingAnnotation.init), for: composerID)
        addSentImages(prompt.attachments ?? [], to: draftStore.attachmentsModel(for: composerID))
    }

    /// Adds a sent message's images to a composer, loading them from this chat.
    private func addSentImages(_ attachments: [Attachment], to composer: ComposerAttachmentsModel) {
        let images = attachments.filter { $0.kind == MaidAttachmentKind.image.rawValue }
        composer.addSentImages(images) { [store] image in
            if let data = image.data, !data.isEmpty { return data }
            guard let attachmentID = image.id else { throw RPCError("“\(image.name ?? "Image")” has no data") }
            return try await store.attachmentData(attachmentID: attachmentID)
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
