import Foundation

/// One row of the agent registry page: a registry agent, an installed agent,
/// or both merged by id.
struct ACPRegistryEntry: Identifiable, Equatable {
    enum Source: String, Equatable {
        case registry
        case custom
    }

    let id: String
    let name: String
    let description: String?
    let source: Source
    /// Version currently published by the registry; nil when the registry no
    /// longer lists this installed agent.
    let availableVersion: String?
    /// Registry version ceiling selected by the user; nil when not installed.
    let installedVersion: String?

    var isInstalled: Bool {
        source == .custom || installedVersion != nil
    }

    var hasUpdate: Bool {
        guard let availableVersion, let installedVersion else { return false }
        return availableVersion != installedVersion
    }

    var versionLabel: String {
        if source == .custom {
            return String(localized: "Custom")
        }
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
