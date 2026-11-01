import Foundation
import Observation
import PhotosUI
import SwiftUI

@Observable
final class DraftPromptModel {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    enum OptionsPhase: Equatable {
        case unavailable
        case loading
        case live
        case failed(String)
    }

    let store: ThreadStore
    let draftStore: ThreadDraftStore
    let promptCompletion: PromptCompletionModel

    var selectedProviderID: String? {
        didSet {
            if selectedProviderID != oldValue { selectionDidChange() }
        }
    }
    var workingDirectory = "" {
        didSet {
            if workingDirectory != oldValue {
                additionalDirectories.removeAll { $0 == workingDirectory }
                promptCompletion.updateScope(.workingDirectory(workingDirectory))
                selectionDidChange()
            }
        }
    }
    private(set) var additionalDirectories: [String] = []
    private(set) var configOptions: [ConfigOption] = []
    private(set) var optionsPhase: OptionsPhase = .unavailable
    private(set) var isSending = false
    private(set) var errorMessage: String?
    let errorTitle = "Couldn’t Start Chat"

    private var optionsSessionID: String?
    private var optionsLoadAttempt = 0
    private var configUpdates: [ConfigUpdate] = []
    private var configUpdateTask: Task<Void, Never>?
    private var isConfiguringInitialSelection = false
    /// The fork draft whose agent and folders were applied, so the user's
    /// later choice of agent stands.
    private var appliedForkDraftID: String?


    init(
        store: ThreadStore,
        draftStore: ThreadDraftStore,
        initialWorkingDirectory: String? = nil
    ) {
        self.store = store
        self.draftStore = draftStore

        let requestedWorkingDirectory = initialWorkingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rememberedWorkingDirectory = draftStore.preferences.workingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let initialWorkingDirectory = requestedWorkingDirectory.isEmpty
            ? rememberedWorkingDirectory
            : requestedWorkingDirectory
        selectedProviderID = draftStore.preferences.providerID.flatMap { providerID in
            store.availableProviders.contains { $0.id == providerID } ? providerID : nil
        }
        workingDirectory = initialWorkingDirectory
        promptCompletion = PromptCompletionModel(
            store: store,
            scope: .workingDirectory(initialWorkingDirectory)
        )
    }

    /// Wires the store's provider-option pushes and the attachment pipeline
    /// to this instance. Kept out of `init` because the view layer constructs
    /// throwaway instances (`State(initialValue:)` discards re-init copies);
    /// only the live model may own the store callbacks. Idempotent — re-run
    /// every time the draft UI appears.
    func activate() {
        store.onProviderOptionsUpdated = { [weak self] update in
            self?.receiveOptions(update)
        }
        store.onProviderOptionsInvalidated = { [weak self] invalidation in
            self?.receiveInvalidation(invalidation)
        }
    }

    var attachments: [ChatPendingAttachment] {
        draftStore.activeDraftThreadID.map { draftStore.attachmentsModel(for: $0).attachments } ?? []
    }

    /// Comments on another chat's text, which editing its prompt in this new
    /// chat carries.
    var annotations: [ChatPendingAnnotation] {
        draftStore.activeDraftThreadID.map(draftStore.annotations(for:)) ?? []
    }

    func removeAnnotation(id: String) {
        guard let draftID = draftStore.activeDraftThreadID else { return }
        draftStore.removeAnnotations(ids: [id], for: draftID)
    }

    /// The new chat's image pipeline, reporting to this model; the draft
    /// store owns its images, as it does a chat's.
    private func draftAttachments() -> ComposerAttachmentsModel {
        let model = draftStore.attachmentsModel(for: ensureLocalDraft())
        model.canAttachImages = { [weak self] in
            self?.supportsImageAttachments == true
        }
        model.reportError = { [weak self] message in
            self?.errorMessage = message
        }
        return model
    }

    /// The chat this new chat continues.
    var fork: ForkDraft? {
        draftStore.activeFork
    }

    /// The fork forks its agent's own session, with its settings: there are
    /// none to choose.
    var forksOwnAgent: Bool {
        fork?.native == true && fork?.throughTurnID != nil
    }

    /// Starts the new chat with the fork's agent and the forked chat's
    /// folders, which a fork keeps.
    private func applyFork() {
        guard let fork, let draftID = draftStore.activeDraftThreadID, appliedForkDraftID != draftID else { return }
        appliedForkDraftID = draftID
        workingDirectory = fork.cwd
        additionalDirectories = fork.additionalDirectories
        if let agentID = fork.agentID, providerIsAvailable(agentID) {
            selectedProviderID = agentID
        } else {
            errorMessage = "The agent of “\(fork.sourceTitle)” is not available"
        }
    }

    func discardFork() {
        draftStore.discardActiveFork()
    }

    var providerChoices: [ProviderChoice] {
        store.availableProviders
    }

    var selectedProvider: ProviderChoice? {
        providerChoices.first { $0.id == selectedProviderID }
    }

    var prompt: String {
        get {
            guard let threadID = draftStore.activeDraftThreadID else { return "" }
            return draftStore.text(for: threadID)
        }
        set {
            guard let threadID = draftStore.activeDraftThreadID else { return }
            draftStore.setText(newValue, for: threadID)
        }
    }

    var hasProviderChoices: Bool {
        !providerChoices.isEmpty
    }

    var hasWorkingDirectory: Bool {
        !workingDirectory.isEmpty
    }

    var providerLabel: String {
        selectedProvider?.title ?? "Provider"
    }

    var directoryLabel: String {
        guard !workingDirectory.isEmpty else { return "Folder" }
        return URL(fileURLWithPath: workingDirectory).lastPathComponent
    }

    var optionsLoadingLabel: String {
        guard !workingDirectory.isEmpty else { return "Choose a folder to load settings" }
        return "Loading settings for \(directoryLabel)…"
    }

    var canSend: Bool {
        connectionState == .connected
            && selectedProviderID != nil
            && !workingDirectory.isEmpty
            && (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty
                || !annotations.isEmpty)
            && (attachments.isEmpty || supportsImageAttachments)
            && attachments.allSatisfy { !$0.isProcessing }
            && !isSending
    }

    var isPromptEnabled: Bool {
        draftStore.activeDraftThreadID != nil && !isSending
    }

    var promptFocusID: String? {
        draftStore.activeDraftThreadID
    }

    var configControlsAreDisabled: Bool {
        optionsPhase != .live || isSending
    }

    var supportsImageAttachments: Bool {
        store.promptContentCapabilities(for: selectedProviderID)?.image == true
    }

    var supportsAdditionalDirectories: Bool {
        guard let selectedProviderID else { return false }
        return store.providerSupportsAdditionalDirectories(selectedProviderID)
    }

    var connectionState: ThreadStore.ConnectionState {
        store.connectionState
    }

    var isErrorPresented: Bool {
        get { errorMessage != nil }
        set {
            if !newValue {
                errorMessage = nil
            }
        }
    }

    /// Changes when the agents to choose from do, or a fork replaces the draft.
    var catalogSelectionKey: String {
        let providers = providerChoices.map(\.id).joined(separator: ",")
        return fork == nil ? providers : "\(providers)|\(draftStore.activeDraftThreadID ?? "")"
    }

    var optionsSelectionKey: String {
        "\(connectionState)|\(selectedProviderID ?? "")|\(workingDirectory)|\(optionsLoadAttempt)"
    }

    @discardableResult
    func ensureLocalDraft() -> String {
        if let draftID = draftStore.activeDraftThreadID { return draftID }
        let draftID = UUID().uuidString
        draftStore.setActiveDraftThreadID(draftID)
        return draftID
    }

    func configureInitialSelection() {
        // An edited prompt's images may still be loading into the draft.
        _ = draftAttachments()
        guard !providerChoices.isEmpty else { return }
        isConfiguringInitialSelection = true
        defer {
            isConfiguringInitialSelection = false
            persistSelection()
        }
        if selectedProviderID.map({ providerIsAvailable($0) }) != true {
            if let providerID = draftStore.preferences.providerID,
               providerIsAvailable(providerID) {
                selectedProviderID = providerID
            } else {
                selectedProviderID = providerChoices.first?.id
            }
        }
        applyFork()
    }

    func selectProvider(id: String) {
        guard providerIsAvailable(id) else { return }
        selectedProviderID = id
    }

    func selectWorkingDirectory(_ directory: String) {
        let directory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else { return }
        workingDirectory = directory
    }

    /// Adds a browsed folder as a project and works in it.
    func addProjectFolder(_ directory: String) async {
        guard let directory = await addProject(directory) else { return }
        workingDirectory = directory
    }

    func addAdditionalDirectory(_ directory: String) {
        let directory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty, directory != workingDirectory else { return }
        additionalDirectories.removeAll { $0 == directory }
        additionalDirectories.append(directory)
    }

    /// Adds a browsed folder as a project, since a chat's every folder must
    /// be in one, and adds it to the chat.
    func addAdditionalProjectFolder(_ directory: String) async {
        guard let directory = await addProject(directory) else { return }
        addAdditionalDirectory(directory)
    }

    private func addProject(_ directory: String) async -> String? {
        do {
            return try await store.addProject(directory)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func removeAdditionalDirectory(_ directory: String) {
        additionalDirectories.removeAll { $0 == directory }
    }

    func retryOptions() {
        optionsLoadAttempt += 1
    }

    func loadOptions() async {
        optionsSessionID = nil
        clearProviderOptions()
        guard connectionState == .connected,
              let requestedProviderID = selectedProviderID,
              !workingDirectory.isEmpty,
              !forksOwnAgent else {
            optionsPhase = .unavailable
            return
        }

        let requestedCwd = workingDirectory
        optionsPhase = .loading
        do {
            let providerID = try await store.ensureProviderAvailable(requestedProviderID)
            try Task.checkCancellation()
            guard selectionMatches(providerID: requestedProviderID, cwd: requestedCwd) else {
                return
            }

            let result = try await store.getProviderOptions(providerID: providerID, cwd: requestedCwd)
            try Task.checkCancellation()
            guard selectionMatches(providerID: requestedProviderID, cwd: requestedCwd) else {
                return
            }
            optionsSessionID = result.optionsSessionID
            applyProviderOptions(result)
            await sendRememberedValues(providerID: providerID)
            try Task.checkCancellation()
            guard selectionMatches(providerID: requestedProviderID, cwd: requestedCwd),
                  optionsSessionID == result.optionsSessionID else {
                return
            }
            optionsPhase = .live
        } catch is CancellationError {
            return
        } catch {
            guard selectionMatches(providerID: requestedProviderID, cwd: requestedCwd) else {
                return
            }
            optionsPhase = .failed(error.localizedDescription)
        }
    }

    func updateConfig(_ optionID: String, value: JSONAny) {
        guard let providerID = selectedProviderID else { return }
        updateLocalOption(optionID, value: value)
        draftStore.preferences.rememberConfigValue(
            value,
            providerID: providerID,
            optionID: optionID
        )

        guard let optionsSessionID else { return }
        configUpdates.append(
            ConfigUpdate(optionsSessionID: optionsSessionID, optionID: optionID, value: value)
        )
        if configUpdateTask == nil {
            configUpdateTask = Task { [weak self] in
                await self?.processConfigUpdates()
            }
        }
    }

    func addImages(from urls: [URL]) async {
        await draftAttachments().addImages(from: urls)
    }

    func addPhotos(_ photos: [PhotosPickerItem]) {
        draftAttachments().addPhotos(photos)
    }

    func addCameraImage(_ thumbnail: ChatComposerThumbnail) {
        draftAttachments().addCameraImage(thumbnail)
    }

    func removeAttachment(id: UUID) {
        draftAttachments().remove(id: id)
    }

    func showError(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    func send() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend,
              let requestedProviderID = selectedProviderID,
              let draftID = draftStore.activeDraftThreadID else { return }

        let requestedCwd = workingDirectory
        let requestedAdditionalDirectories = additionalDirectories
        let selections = currentSelections(providerID: requestedProviderID)
        let submittedAttachments = attachments
        let submittedAnnotations = annotations
        isSending = true
        defer { isSending = false }

        let providerID: String
        do {
            providerID = try await store.ensureProviderAvailable(requestedProviderID)
        } catch {
            showError(error)
            return
        }

        guard requestedAdditionalDirectories.isEmpty
            || store.providerSupportsAdditionalDirectories(providerID)
        else {
            showError(RPCError("This provider does not support additional project folders"))
            return
        }

        let fileLinks = promptCompletion.fileMentionLinks(in: text, directory: requestedCwd)

        do {
            let attachments = submittedAttachments.compactMap(\.attachment) + fileLinks
            let body = MessageBody(
                annotations: submittedAnnotations.isEmpty ? nil : submittedAnnotations.map(\.promptAnnotation),
                attachments: attachments.isEmpty ? nil : attachments,
                text: text.isEmpty ? nil : text
            )
            // The draft's ID keys the start, so retrying an ambiguous one
            // opens the chat it made.
            let threadID: String
            if let fork, let throughTurnID = fork.throughTurnID {
                let agent = forksOwnAgent
                    ? nil
                    : NewParticipant(instance: providerID, session: nil, settings: selections.isEmpty ? nil : selections)
                threadID = try await store.forkThread(
                    key: draftID,
                    sourceThreadID: fork.sourceThreadID,
                    throughTurnID: throughTurnID,
                    agent: agent,
                    body: body
                )
            } else {
                threadID = try await store.startThread(
                    key: draftID,
                    providerInstanceID: providerID,
                    cwd: requestedCwd,
                    additionalDirectories: requestedAdditionalDirectories,
                    body: body,
                    settings: selections
                )
            }
            promptCompletion.clearMentionedFiles()
            draftStore.removeDraft(for: draftID)
            store.selectThread(threadID)
        } catch is CancellationError {
            return
        } catch {
            showError(error)
        }
    }

    private func selectionMatches(providerID: String, cwd: String) -> Bool {
        selectedProviderID == providerID && workingDirectory == cwd
    }

    private func providerIsAvailable(_ providerID: String) -> Bool {
        providerChoices.contains { $0.id == providerID }
    }

    private func receiveOptions(_ update: ProviderOptionsResult) {
        // While our own config updates are queued or in flight, a pushed
        // options list may predate them; the queue applies the authoritative
        // result when it drains.
        guard optionsSessionID == update.optionsSessionID, configUpdateTask == nil else { return }
        applyProviderOptions(update)
        if optionsPhase != .loading {
            optionsPhase = .live
        }
    }

    private func selectionDidChange() {
        optionsSessionID = nil
        clearProviderOptions()
        configUpdates.removeAll()
        optionsPhase = selectedProviderID == nil || workingDirectory.isEmpty
            ? .unavailable
            : .loading
        if !isConfiguringInitialSelection {
            persistSelection()
        }
    }

    private func receiveInvalidation(_ invalidation: ProviderOptionsInvalidated) {
        guard optionsSessionID == invalidation.optionsSessionID else { return }
        optionsSessionID = nil
        clearProviderOptions()
        optionsPhase = .failed("The agent stopped. Retry settings when it is available.")
    }

    private func sendRememberedValues(providerID: String) async {
        guard let optionsSessionID else { return }
        let modelOptions = configOptions.filter { $0.optionCategory == .model }
        guard await sendRememberedValues(
            modelOptions,
            providerID: providerID,
            optionsSessionID: optionsSessionID
        ) else { return }
        let dependentOptions = configOptions.filter { $0.optionCategory != .model }
        _ = await sendRememberedValues(
            dependentOptions,
            providerID: providerID,
            optionsSessionID: optionsSessionID
        )
    }

    private func sendRememberedValues(
        _ options: [ConfigOption],
        providerID: String,
        optionsSessionID: String
    ) async -> Bool {
        for option in options {
            guard let value = validRememberedValue(for: option, providerID: providerID) else {
                continue
            }
            if configValuesMatch(value, option.currentValue) {
                continue
            }
            do {
                let result = try await store.setProviderOption(
                    optionsSessionID: optionsSessionID,
                    optionID: option.id,
                    value: value
                )
                try Task.checkCancellation()
                guard self.optionsSessionID == result.optionsSessionID else { return false }
                applyProviderOptions(result)
            } catch is CancellationError {
                return false
            } catch {
                continue
            }
        }
        return true
    }

    private func processConfigUpdates() async {
        var latestSuccessfulResult: ProviderOptionsResult?
        var failedUpdatesByOptionID: [String: ConfigUpdate] = [:]
        while !configUpdates.isEmpty {
            let update = configUpdates.removeFirst()
            guard optionsSessionID == update.optionsSessionID else { continue }

            do {
                let result = try await store.setProviderOption(
                    optionsSessionID: update.optionsSessionID,
                    optionID: update.optionID,
                    value: update.value
                )
                if optionsSessionID == result.optionsSessionID {
                    latestSuccessfulResult = result
                    failedUpdatesByOptionID[update.optionID] = nil
                }
            } catch {
                // The local selection remains valid draft data and is reconciled
                // again when the real thread session starts.
                if optionsSessionID == update.optionsSessionID {
                    failedUpdatesByOptionID[update.optionID] = update
                }
            }
        }
        configUpdateTask = nil
        if let latestSuccessfulResult,
           optionsSessionID == latestSuccessfulResult.optionsSessionID {
            applyProviderOptions(latestSuccessfulResult)
            for update in failedUpdatesByOptionID.values {
                guard let option = configOptions.first(where: { $0.id == update.optionID }),
                      configValueIsValid(update.value, for: option) else {
                    continue
                }
                updateLocalOption(update.optionID, value: update.value)
            }
        }
    }

    private func persistSelection() {
        // A fork's agent and folders are the forked chat's, not a choice to
        // remember for new chats.
        guard fork == nil else { return }
        draftStore.preferences.rememberSelection(
            providerID: selectedProviderID,
            workingDirectory: workingDirectory
        )
    }

    private func applyProviderOptions(_ result: ProviderOptionsResult) {
        configOptions = result.configOptions
        promptCompletion.updateCatalog(commands: [], skills: result.skills ?? [])
    }

    private func clearProviderOptions() {
        configOptions = []
        promptCompletion.updateCatalog(commands: [], skills: [])
    }

    private func rememberedValues(providerID: String) -> [String: JSONAny] {
        draftStore.preferences.configValues(providerID: providerID)
    }

    private func currentSelections(providerID: String) -> [ConfigOptionSelection] {
        let values = rememberedValues(providerID: providerID)
        let optionsByID = Dictionary(
            configOptions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return values.sorted { $0.key < $1.key }.compactMap { optionID, value in
            // With live options, drop remembered values the agent no longer
            // offers so every Send does not re-emit the same runtime warning.
            if optionsPhase == .live {
                guard let option = optionsByID[optionID],
                      configValueIsValid(value, for: option) else {
                    return nil
                }
            }
            return ConfigOptionSelection(
                category: optionsByID[optionID]?.category,
                optionID: optionID,
                value: value
            )
        }
    }

    private func updateLocalOption(_ optionID: String, value: JSONAny) {
        configOptions = configOptions.map { option in
            option.id == optionID ? option.with(currentValue: value) : option
        }
    }

    private func validRememberedValue(for option: ConfigOption, providerID: String) -> JSONAny? {
        guard let value = rememberedValues(providerID: providerID)[option.id] else { return nil }
        return configValueIsValid(value, for: option) ? value : nil
    }

    private func configValueIsValid(_ value: JSONAny, for option: ConfigOption) -> Bool {
        if option.optionType == .boolean {
            return value.value is Bool
        }
        guard let string = value.value as? String else { return false }
        return option.choices?.contains(where: { $0.value == string }) == true
    }

    private func configValuesMatch(_ left: JSONAny, _ right: JSONAny?) -> Bool {
        switch (left.value, right?.value) {
        case let (left as Bool, right as Bool):
            left == right
        case let (left as String, right as String):
            left == right
        default:
            false
        }
    }

    private struct ConfigUpdate {
        let optionsSessionID: String
        let optionID: String
        let value: JSONAny
    }
}
