import Foundation
import Observation

@Observable
final class ThreadDraftStore {
    let preferences: DraftPreferencesStore

    private struct StoredDraft: Codable {
        var threadID: String?
        var text: String
    }

    private static let storageKey = "thread-drafts"

    private(set) var activeDraftThreadID: String?
    private(set) var draftText: String

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = DraftPreferencesStore(defaults: defaults)

        guard let data = defaults.data(forKey: Self.storageKey) else {
            activeDraftThreadID = nil
            draftText = ""
            return
        }

        if let stored = try? JSONDecoder().decode(StoredDraft.self, from: data) {
            activeDraftThreadID = stored.threadID
            draftText = stored.text
        } else {
            activeDraftThreadID = nil
            draftText = ""
        }
    }

    func text(for threadID: String) -> String {
        activeDraftThreadID == threadID ? draftText : ""
    }

    func setText(_ text: String, for threadID: String) {
        guard activeDraftThreadID == threadID else { return }
        draftText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
        save()
    }

    func setActiveDraftThreadID(_ threadID: String?) {
        guard activeDraftThreadID != threadID else { return }
        activeDraftThreadID = threadID
        draftText = ""
        save()
    }

    func removeDraft(for threadID: String) {
        guard activeDraftThreadID == threadID else { return }
        activeDraftThreadID = nil
        draftText = ""
        save()
    }

    private func save() {
        let stored = StoredDraft(
            threadID: activeDraftThreadID,
            text: draftText
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
