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

    func rememberSelection(providerID: String?, workingDirectory: String) {
        var didChange = false
        if let providerID, !providerID.isEmpty, self.providerID != providerID {
            self.providerID = providerID
            didChange = true
        }

        let workingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !workingDirectory.isEmpty, self.workingDirectory != workingDirectory {
            self.workingDirectory = workingDirectory
            didChange = true
        }

        if didChange {
            save()
        }
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
