import Foundation

/// One row of the agent registry page: a registry agent, an installed agent,
/// or both merged by id.
struct ACPRegistryEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String?
    /// Version currently published by the registry; nil when the registry no
    /// longer lists this installed agent.
    let availableVersion: String?
    /// Registry version ceiling selected by the user; nil when not installed.
    let installedVersion: String?

    var isInstalled: Bool {
        installedVersion != nil
    }

    var hasUpdate: Bool {
        guard let availableVersion, let installedVersion else { return false }
        return availableVersion != installedVersion
    }

    var versionLabel: String {
        if let installedVersion {
            if let availableVersion, availableVersion != installedVersion {
                return "\(installedVersion) installed · \(availableVersion) available"
            }
            return "\(installedVersion) installed"
        }
        if let availableVersion {
            return availableVersion
        }
        return ""
    }
}
