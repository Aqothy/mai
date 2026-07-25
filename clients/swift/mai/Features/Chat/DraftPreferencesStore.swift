import Foundation
import Observation

@Observable
final class DraftPreferencesStore {
    private struct StoredPreferences: Codable {
        var providerID: String?
        var workingDirectory: String?
        var configByProviderID: [String: [String: JSONAny]]
    }

    private static let storageKey = "draft-preferences"

    private(set) var providerID: String?
    private(set) var workingDirectory: String?
    private(set) var configByProviderID: [String: [String: JSONAny]]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.storageKey).flatMap {
            try? JSONDecoder().decode(StoredPreferences.self, from: $0)
        }
        providerID = stored?.providerID
        workingDirectory = stored?.workingDirectory
        configByProviderID = stored?.configByProviderID ?? [:]
    }

    func rememberProvider(_ providerID: String) {
        guard self.providerID != providerID else { return }
        self.providerID = providerID
        save()
    }

    func rememberWorkingDirectory(_ workingDirectory: String?) {
        let trimmed = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed?.isEmpty == false ? trimmed : nil
        guard self.workingDirectory != value else { return }
        self.workingDirectory = value
        save()
    }

    func configValue(providerID: String, optionID: String) -> JSONAny? {
        configByProviderID[providerID]?[optionID]
    }

    func configValues(providerID: String) -> [String: JSONAny] {
        configByProviderID[providerID] ?? [:]
    }

    func rememberConfigValue(_ value: JSONAny, providerID: String, optionID: String) {
        configByProviderID[providerID, default: [:]][optionID] = value
        save()
    }

    private func save() {
        let stored = StoredPreferences(
            providerID: providerID,
            workingDirectory: workingDirectory,
            configByProviderID: configByProviderID
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
