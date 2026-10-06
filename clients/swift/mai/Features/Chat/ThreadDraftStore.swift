import Foundation
import Observation

/// Persistent per-chat drafts keyed independently from thread subscriptions
/// and UI state: text, pending annotations, and (for this app session) pending
/// attachments. `activeDraftThreadID` identifies the one provisional new chat.
@Observable
final class ThreadDraftStore {
    // Back-deployment: avoid the isolated-deinit runtime bug (swiftlang/swift#88036).
    nonisolated deinit {}

    let preferences: DraftPreferencesStore

    private struct StoredDrafts: Codable {
        var activeDraftThreadID: String?
        var textByThreadID: [String: String]
        var annotationsByThreadID: [String: [ChatPendingAnnotation]]
    }

    private static let storageKey = "thread-drafts"
    private static let persistenceDelay = Duration.milliseconds(300)

    private(set) var activeDraftThreadID: String?

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
        }
        activeDraftThreadID = threadID
        saveImmediately()
    }

    func removeDraft(for threadID: String) {
        textByThreadID[threadID] = nil
        annotationsByThreadID[threadID] = nil
        attachmentsByThreadID[threadID] = nil
        if activeDraftThreadID == threadID {
            activeDraftThreadID = nil
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
            textByThreadID: textByThreadID,
            annotationsByThreadID: annotationsByThreadID
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
