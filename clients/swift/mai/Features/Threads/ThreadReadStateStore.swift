import Foundation
import Observation

/// Client-local sidebar read state. It is intentionally independent from
/// conversation snapshots and live subscriptions.
@Observable
final class ThreadReadStateStore {
    private static let storageKey = "unread-thread-ids-v1"

    private(set) var unreadThreadIDs: Set<String>

    @ObservationIgnored private let defaults: UserDefaults?

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        unreadThreadIDs = Set(defaults?.stringArray(forKey: Self.storageKey) ?? [])
    }

    func isUnread(_ threadID: String) -> Bool {
        unreadThreadIDs.contains(threadID)
    }

    func markUnread(_ threadID: String) {
        guard unreadThreadIDs.insert(threadID).inserted else { return }
        save()
    }

    func markRead(_ threadID: String) {
        guard unreadThreadIDs.remove(threadID) != nil else { return }
        save()
    }

    func retainThreadIDs(_ threadIDs: Set<String>) {
        let retained = unreadThreadIDs.intersection(threadIDs)
        guard retained != unreadThreadIDs else { return }
        unreadThreadIDs = retained
        save()
    }

    private func save() {
        defaults?.set(unreadThreadIDs.sorted(), forKey: Self.storageKey)
    }
}
