import Foundation
import Observation
import PhotosUI
import SwiftUI

@Observable
final class DraftPromptModel {
    enum OptionsPhase: Equatable {
        case unavailable
        case loading
        case live
        case failed(String)
    }

    let store: ThreadStore
    let draftStore: ThreadDraftStore

    var selectedProviderID: String? {
        didSet {
            if selectedProviderID != oldValue { selectionDidChange() }
        }
    }
    var workingDirectory = "" {
        didSet {
            if workingDirectory != oldValue { selectionDidChange() }
        }
    }
    var directoryInput = ""
    var isEnteringDirectory = false

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

    private let attachmentsModel = ComposerAttachmentsModel()

    init(store: ThreadStore, draftStore: ThreadDraftStore) {
        self.store = store
        self.draftStore = draftStore
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
        attachmentsModel.canAttachImages = { [weak self] in
            self?.supportsImageAttachments == true
        }
        attachmentsModel.reportError = { [weak self] message in
            self?.errorMessage = message
        }
    }

    var attachments: [ChatPendingAttachment] {
        attachmentsModel.attachments
    }

    var providerChoices: [ProviderChoice] {
        store.availableProviders
    }

    var selectedProvider: ProviderChoice? {
        providerChoices.first { $0.id == selectedProviderID }
    }

    var recentWorkingDirectories: [String] {
        store.recentWorkingDirectories
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
        selectedProvider?.name ?? "Provider"
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
            && effectiveProviderID != nil
            && !workingDirectory.isEmpty
            && (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty)
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
        store.promptContentCapabilities(for: effectiveProviderID)?.image == true
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

    var catalogSelectionKey: String {
        providerChoices.map(\.id).joined(separator: ",")
    }

    var optionsSelectionKey: String {
        "\(connectionState)|\(effectiveProviderID ?? "")|\(workingDirectory)|\(optionsLoadAttempt)"
    }

    func ensureLocalDraft() {
        if draftStore.activeDraftThreadID == nil {
            draftStore.setActiveDraftThreadID(UUID().uuidString)
        }
    }

    func configureInitialSelection() {
        if reconcileAcceptedDraft() { return }
        ensureLocalDraft()
        isConfiguringInitialSelection = true
        defer {
            isConfiguringInitialSelection = false
            persistSelection()
        }
        if selectedProviderID.map({ providerIsAvailable($0) }) != true {
            if let providerID = draftStore.preferences.providerID,
               providerIsAvailable(providerID) {
                selectProvider(providerID)
            } else if let provider = providerChoices.first {
                selectProvider(provider)
            } else {
                selectedProviderID = nil
            }
        }
        if workingDirectory.isEmpty {
            workingDirectory = draftStore.preferences.workingDirectory
                ?? recentWorkingDirectories.first
                ?? ""
        }
    }

    func beginEnteringDirectory() {
        directoryInput = workingDirectory
        isEnteringDirectory = true
    }

    func selectProvider(_ choice: ProviderChoice) {
        selectedProviderID = choice.id
    }

    func commitDirectoryInput() {
        workingDirectory = directoryInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func retryOptions() {
        optionsLoadAttempt += 1
    }

    func loadOptions() async {
        if reconcileAcceptedDraft() { return }
        optionsSessionID = nil
        configOptions = []
        guard connectionState == .connected,
              let requestedProviderID = effectiveProviderID,
              !workingDirectory.isEmpty else {
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

            guard store.providerSupportsConfigOptions(providerID) else {
                optionsPhase = .live
                return
            }

            let result = try await store.getProviderOptions(providerID: providerID, cwd: requestedCwd)
            try Task.checkCancellation()
            guard selectionMatches(providerID: requestedProviderID, cwd: requestedCwd) else {
                return
            }
            optionsSessionID = result.optionsSessionID
            configOptions = result.configOptions
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
        guard let providerID = effectiveProviderID else { return }
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

    func send() async {
        // An earlier ambiguous Start may have already created this thread; open
        // it instead of silently colliding with the idempotent thread ID.
        if reconcileAcceptedDraft() { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend,
              let requestedProviderID = effectiveProviderID,
              let threadID = draftStore.activeDraftThreadID else { return }

        let requestedCwd = workingDirectory
        let selections = currentSelections(providerID: requestedProviderID)
        isSending = true
        defer { isSending = false }

        let providerID: String
        do {
            providerID = try await store.ensureProviderAvailable(requestedProviderID)
        } catch {
            showError(error)
            return
        }

        do {
            try await store.startThread(
                threadID: threadID,
                providerInstanceID: providerID,
                cwd: requestedCwd,
                message: CommandMessage(
                    attachments: attachments.compactMap(\.attachment),
                    messageID: UUID().uuidString,
                    text: text
                ),
                configSelections: selections
            )
            draftStore.removeDraft(for: threadID)
            store.selectThread(threadID)
        } catch is CancellationError {
            return
        } catch {
            showError(error)
        }
    }

    private var effectiveProviderID: String? {
        selectedProviderID
    }

    private func selectionMatches(providerID: String, cwd: String) -> Bool {
        effectiveProviderID == providerID && workingDirectory == cwd
    }

    private func providerIsAvailable(_ providerID: String) -> Bool {
        providerChoices.contains { $0.id == providerID }
    }

    private func selectProvider(_ providerID: String) {
        selectedProviderID = providerID
    }

    private func receiveOptions(_ update: ProviderOptionsResult) {
        // While our own config updates are queued or in flight, a pushed
        // options list may predate them; the queue applies the authoritative
        // result when it drains.
        guard optionsSessionID == update.optionsSessionID, configUpdateTask == nil else { return }
        configOptions = update.configOptions
        if optionsPhase != .loading {
            optionsPhase = .live
        }
    }

    private func selectionDidChange() {
        optionsSessionID = nil
        configOptions = []
        configUpdates.removeAll()
        optionsPhase = effectiveProviderID == nil || workingDirectory.isEmpty
            ? .unavailable
            : .loading
        if !isConfiguringInitialSelection {
            persistSelection()
        }
    }

    private func reconcileAcceptedDraft() -> Bool {
        guard let threadID = draftStore.activeDraftThreadID,
              store.threads.contains(where: { $0.id == threadID }) else {
            return false
        }
        draftStore.removeDraft(for: threadID)
        store.selectThread(threadID)
        return true
    }

    private func receiveInvalidation(_ invalidation: ProviderOptionsInvalidated) {
        guard optionsSessionID == invalidation.optionsSessionID else { return }
        optionsSessionID = nil
        configOptions = []
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
                configOptions = result.configOptions
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
            configOptions = latestSuccessfulResult.configOptions
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
        if let providerID = effectiveProviderID {
            draftStore.preferences.rememberProvider(providerID)
        }
        draftStore.preferences.rememberWorkingDirectory(workingDirectory)
    }

    private func currentSelections(providerID: String) -> [ConfigOptionSelection] {
        let values = draftStore.preferences.configValues(providerID: providerID)
        let optionsByID = Dictionary(
            configOptions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return values.keys.sorted().compactMap { optionID in
            guard let value = values[optionID] else { return nil }
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
        guard let value = draftStore.preferences.configValue(
            providerID: providerID,
            optionID: option.id
        ) else { return nil }
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
