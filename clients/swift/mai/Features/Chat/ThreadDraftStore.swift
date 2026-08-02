import Foundation
import Observation

/// Persistent text drafts keyed independently from thread subscriptions and UI
/// state. `activeDraftThreadID` identifies the one provisional new chat.
@Observable
final class ThreadDraftStore {
    let preferences: DraftPreferencesStore

    private struct StoredDrafts: Codable {
        var activeDraftThreadID: String?
        var textByThreadID: [String: String]
    }

    private struct LegacyStoredDraft: Codable {
        var threadID: String?
        var text: String
    }

    private static let storageKey = "thread-drafts"
    private static let persistenceDelay = Duration.milliseconds(300)

    private(set) var activeDraftThreadID: String?

    private var textByThreadID: [String: String]
    private let defaults: UserDefaults
    @ObservationIgnored private var pendingSaveTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = DraftPreferencesStore(defaults: defaults)

        guard let data = defaults.data(forKey: Self.storageKey) else {
            activeDraftThreadID = nil
            textByThreadID = [:]
            return
        }

        if let stored = try? JSONDecoder().decode(StoredDrafts.self, from: data) {
            activeDraftThreadID = stored.activeDraftThreadID
            textByThreadID = stored.textByThreadID.filter { !$0.value.isEmpty }
        } else if let legacy = try? JSONDecoder().decode(LegacyStoredDraft.self, from: data) {
            activeDraftThreadID = legacy.threadID
            textByThreadID = legacy.threadID.map {
                legacy.text.isEmpty ? [:] : [$0: legacy.text]
            } ?? [:]
        } else {
            activeDraftThreadID = nil
            textByThreadID = [:]
        }
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
            textByThreadID: textByThreadID
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
