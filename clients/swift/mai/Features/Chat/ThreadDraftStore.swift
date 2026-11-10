import Foundation
import Observation

/// Persistent per-chat drafts keyed independently from thread subscriptions
/// and UI state: text, pending annotations, and (for this app session) pending
/// attachments. `activeDraftThreadID` identifies the one provisional new chat,
/// and `activeFork` the chat it continues, if it is a fork; the draft's ID
/// keys the command that starts it, so a retried Start opens the chat the
/// first one made.
@Observable
final class ThreadDraftStore {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    let preferences: DraftPreferencesStore

    private struct StoredDrafts: Codable {
        var activeDraftThreadID: String?
        var activeFork: ForkDraft?
        var textByThreadID: [String: String]
        var annotationsByThreadID: [String: [ChatPendingAnnotation]]
    }

    private static let storageKey = "thread-drafts"
    private static let persistenceDelay = Duration.milliseconds(300)

    private(set) var activeDraftThreadID: String?
    /// The chat the new chat continues; it belongs to `activeDraftThreadID`.
    private(set) var activeFork: ForkDraft?

    private var textByThreadID: [String: String]
    private var annotationsByThreadID: [String: [ChatPendingAnnotation]] = [:]
    /// Attachment imports are file/photo data, so they are kept only in
    /// memory; the model outlives a chat's composer so imports finish into it.
    @ObservationIgnored private var attachmentsByThreadID: [String: ComposerAttachmentsModel] = [:]
    private let defaults: UserDefaults
    @ObservationIgnored private var pendingSaveTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = DraftPreferencesStore(defaults: defaults)

        guard let data = defaults.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode(StoredDrafts.self, from: data)
        else {
            activeDraftThreadID = nil
            textByThreadID = [:]
            return
        }
        activeDraftThreadID = stored.activeDraftThreadID
        activeFork = stored.activeFork
        textByThreadID = stored.textByThreadID.filter { !$0.value.isEmpty }
        annotationsByThreadID = stored.annotationsByThreadID.filter { !$0.value.isEmpty }
    }

    func text(for threadID: String) -> String {
        textByThreadID[threadID] ?? ""
    }

    func setText(_ text: String, for threadID: String) {
        guard self.text(for: threadID) != text else { return }
        if text.isEmpty {
            textByThreadID[threadID] = nil
        } else {
            textByThreadID[threadID] = text
        }
        scheduleSave()
    }

    func annotations(for threadID: String) -> [ChatPendingAnnotation] {
        annotationsByThreadID[threadID] ?? []
    }

    func setAnnotations(_ annotations: [ChatPendingAnnotation], for threadID: String) {
        guard self.annotations(for: threadID) != annotations else { return }
        annotationsByThreadID[threadID] = annotations.isEmpty ? nil : annotations
        scheduleSave()
    }

    /// Removes only the annotations a send submitted, keeping any added while
    /// the send was in flight.
    func removeAnnotations(ids: Set<String>, for threadID: String) {
        setAnnotations(annotations(for: threadID).filter { !ids.contains($0.id) }, for: threadID)
    }

    func attachmentsModel(for threadID: String) -> ComposerAttachmentsModel {
        if let model = attachmentsByThreadID[threadID] { return model }
        let model = ComposerAttachmentsModel()
        attachmentsByThreadID[threadID] = model
        return model
    }

    func setActiveDraftThreadID(_ threadID: String?) {
        guard activeDraftThreadID != threadID else { return }
        if let activeDraftThreadID {
            textByThreadID[activeDraftThreadID] = nil
            annotationsByThreadID[activeDraftThreadID] = nil
            attachmentsByThreadID[activeDraftThreadID] = nil
        }
        activeDraftThreadID = threadID
        activeFork = nil
        saveImmediately()
    }

    /// Replaces the new chat with a fork of another chat, and names it.
    func startForkDraft(_ fork: ForkDraft) -> String {
        let draftID = UUID().uuidString
        setActiveDraftThreadID(draftID)
        activeFork = fork
        saveImmediately()
        return draftID
    }

    /// Keeps the new chat, no longer a fork.
    func discardActiveFork() {
        activeFork = nil
        saveImmediately()
    }

    func removeDraft(for threadID: String) {
        textByThreadID[threadID] = nil
        annotationsByThreadID[threadID] = nil
        attachmentsByThreadID[threadID] = nil
        if activeDraftThreadID == threadID {
            activeDraftThreadID = nil
            activeFork = nil
        }
        saveImmediately()
    }

    func flushPendingSave() {
        guard pendingSaveTask != nil else { return }
        saveImmediately()
    }

    private func scheduleSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.persistenceDelay)
            } catch {
                return
            }
            self?.pendingSaveTask = nil
            self?.save()
        }
    }

    private func saveImmediately() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        save()
    }

    private func save() {
        let stored = StoredDrafts(
            activeDraftThreadID: activeDraftThreadID,
            activeFork: activeFork,
            textByThreadID: textByThreadID,
            annotationsByThreadID: annotationsByThreadID
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
