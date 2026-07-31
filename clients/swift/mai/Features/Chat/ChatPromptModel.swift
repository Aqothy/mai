import Foundation
import Observation
import PhotosUI
import SwiftUI

@Observable
final class ChatPromptModel {
    let store: ThreadStore
    let threadID: String

    var text = ""
    private(set) var isSending = false
    private(set) var isInterrupting = false
    private(set) var settingConfigOptionIDs: Set<String> = []
    private(set) var errorMessage: String?

    private let attachmentsModel = ComposerAttachmentsModel()

    init(store: ThreadStore, threadID: String) {
        self.store = store
        self.threadID = threadID
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
        store.connectionState == .connected
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty)
            && attachments.allSatisfy { !$0.isProcessing }
            && !isSending
    }

    var isPromptEnabled: Bool {
        store.connectionState == .connected && !isSending
    }

    var isErrorPresented: Bool {
        get { errorMessage != nil }
        set {
            if !newValue {
                errorMessage = nil
            }
        }
    }

    func send() async {
        let submittedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedAttachments = attachments
        let submittedAttachmentIDs = Set(submittedAttachments.map(\.id))
        guard canSend,
              !submittedText.isEmpty || !submittedAttachments.isEmpty else { return }

        isSending = true
        defer { isSending = false }

        do {
            try await store.submitTurn(
                threadID: threadID,
                text: submittedText,
                attachments: submittedAttachments.compactMap(\.attachment)
            )
            if text.trimmingCharacters(in: .whitespacesAndNewlines) == submittedText {
                text = ""
            }
            attachmentsModel.remove(ids: submittedAttachmentIDs)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
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
