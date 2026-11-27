import Foundation

/// One row of the agent registry page, read from the daemon's list.
struct ACPRegistryEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String?
    let iconURL: URL?
    let source: MaidACPAgentSource
    /// Nil when a newer daemon sends a state this client doesn't know.
    let state: MaidACPAgentState?
    /// What is on disk; nil when not installed.
    let installedVersion: String?
    /// What installing would bring; nil when that is already installed or the
    /// registry no longer lists this agent.
    let availableVersion: String?
    let availableReleasedAt: Date?
    let blocker: MaidACPAgentBlocker?
    let errorMessage: String?
    let repositoryURL: URL?
    let websiteURL: URL?
    let licenseURL: URL?

    init(_ agent: ACPRegistryAgent) {
        id = agent.id
        name = agent.name
        description = agent.description
        iconURL = agent.icon.flatMap { URL(string: $0) }
        source = MaidACPAgentSource(rawValue: agent.source) ?? .registry
        state = MaidACPAgentState(rawValue: agent.state)
        installedVersion = agent.installedVersion
        availableVersion = agent.availableVersion
        availableReleasedAt = agent.availableReleasedAt
        blocker = agent.blocker.flatMap(MaidACPAgentBlocker.init(rawValue:))
        errorMessage = agent.error
        repositoryURL = Self.webURL(agent.repository)
        websiteURL = Self.webURL(agent.website)
        licenseURL = Self.webURL(agent.licenseURL)
    }

    /// These links come from a remote index, and opening one hands it to the
    /// system: only the web.
    private static func webURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme == "https" || url.scheme == "http" else {
            return nil
        }
        return url
    }

    var isInstalled: Bool {
        source == .custom || installedVersion != nil
    }

    var hasUpdate: Bool {
        isInstalled && availableVersion != nil
    }

    /// The daemon is installing or updating it.
    var isWorking: Bool {
        state == .installing || state == .updating
    }

    var versionLabel: String {
        if source == .custom {
            return String(localized: "Custom")
        }
        guard let installedVersion else {
            return availableVersion ?? ""
        }
        guard let availableVersion else {
            return installedVersion
        }
        guard let availableReleasedAt else {
            return String(localized: "\(installedVersion) · \(availableVersion) available")
        }
        let released = availableReleasedAt.formatted(.relative(presentation: .named))
        return String(localized: "\(installedVersion) · \(availableVersion) available, released \(released)")
    }

    var blockerMessage: String? {
        switch blocker {
        case .platform: String(localized: "Not supported on this platform")
        case .node: String(localized: "Needs Node.js on the computer running maiD")
        case .uv: String(localized: "Needs uv on the computer running maiD")
        case nil: nil
        }
    }
}

#if DEBUG
    extension ACPRegistryAgent {
        static func preview(
            id: String,
            instanceID: String? = nil,
            name: String,
            source: MaidACPAgentSource = .registry,
            state: MaidACPAgentState = .installed,
            description: String? = nil,
            icon: String? = nil,
            installedVersion: String? = nil,
            availableVersion: String? = nil,
            availableReleasedAt: Date? = nil,
            blocker: MaidACPAgentBlocker? = nil,
            error: String? = nil
        ) -> ACPRegistryAgent {
            ACPRegistryAgent(
                args: nil,
                availableReleasedAt: availableReleasedAt,
                availableVersion: availableVersion,
                blocker: blocker?.rawValue,
                command: nil,
                description: description,
                envNames: nil,
                error: error,
                icon: icon,
                id: id,
                installedVersion: installedVersion,
                instanceID: instanceID ?? "\(source.rawValue)-\(id)",
                licenseURL: source == .custom ? nil : "https://example.com/license",
                name: name,
                repository: source == .custom ? nil : "https://example.com/repository",
                source: source.rawValue,
                state: state.rawValue,
                website: source == .custom ? nil : "https://example.com"
            )
        }
    }
#endif
