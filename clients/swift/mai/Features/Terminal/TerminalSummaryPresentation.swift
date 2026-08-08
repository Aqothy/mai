import Foundation

/// Equatable so identical daemon reports do not replace row state or
/// invalidate terminal rows.
extension TerminalSummary: Equatable {
    public static func == (lhs: TerminalSummary, rhs: TerminalSummary) -> Bool {
        lhs.terminalID == rhs.terminalID
            && lhs.title == rhs.title
            && lhs.cwd == rhs.cwd
            && lhs.status == rhs.status
            && lhs.exitCode == rhs.exitCode
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
            && lhs.observedTitle == rhs.observedTitle
            && lhs.agentKind == rhs.agentKind
            && lhs.agentActivity == rhs.agentActivity
            && lhs.agentActivityUpdatedAt == rhs.agentActivityUpdatedAt
    }
}

/// Presentation values for terminal rows and detail chrome. Rows receive only
/// these derived values, never live output or store objects.
extension TerminalSummary {
    var terminalStatus: MaidTerminalStatus? {
        MaidTerminalStatus(rawValue: status)
    }

    /// The detected agent activity; nil when absent or a future unknown
    /// value, which must render neutrally.
    var terminalAgentActivity: MaidTerminalAgentActivity? {
        guard let agentActivity, !agentActivity.isEmpty else { return nil }
        return MaidTerminalAgentActivity(rawValue: agentActivity)
    }

    /// The persisted title, falling back to the working directory name.
    var displayTitle: String {
        if !title.isEmpty { return title }
        return workingDirectoryName ?? String(localized: "Terminal")
    }

    var workingDirectoryName: String? {
        guard !cwd.isEmpty else { return nil }
        return URL(filePath: cwd).lastPathComponent
    }

    /// Row subtitle: the normalized observed terminal title when the daemon
    /// has one, otherwise the working directory name.
    var displaySubtitle: String? {
        if let observedTitle, !observedTitle.isEmpty, observedTitle != displayTitle {
            return observedTitle
        }
        return workingDirectoryName
    }

    /// Compact status for list rows: the highest-value signal wins. Lifecycle
    /// state wins when the terminal is not running; for a running terminal,
    /// agent activity takes priority in the order blocked, done, working,
    /// idle. Unknown activity and unknown future values render as the plain
    /// lifecycle label.
    var statusLabel: String? {
        if isRunning, let activityLabel = agentActivityLabel {
            return activityLabel
        }
        return lifecycleLabel
    }

    /// Shared thread-list indicator. Running and idle shells stay quiet;
    /// actionable and active agent states use the same visuals as agent rows.
    var rowIndicatorStatus: ThreadRowIndicatorStatus? {
        guard isRunning else {
            return switch terminalStatus {
            case .error: .failed
            case .stopped: .interrupted
            case .starting, .running, .exited, nil: nil
            }
        }
        guard let terminalAgentActivity else { return nil }
        return switch terminalAgentActivity {
        case .blocked: .needsInput
        case .working: .working
        case .done: .done
        case MaidTerminalAgentActivity.none, .idle, .unknown: nil
        }
    }

    private var agentActivityLabel: String? {
        guard let terminalAgentActivity else { return nil }
        return switch terminalAgentActivity {
        case .blocked: String(localized: "Needs input")
        case .done: String(localized: "Done")
        case .working: String(localized: "Working")
        case .idle: String(localized: "Agent ready")
        case MaidTerminalAgentActivity.none, .unknown: nil
        }
    }

    private var lifecycleLabel: String? {
        switch terminalStatus {
        case .starting, .running: String(localized: "Running")
        case .exited: String(localized: "Exited")
        case .stopped: String(localized: "Stopped")
        case .error: String(localized: "Error")
        case nil: nil
        }
    }

    /// Whether a live shell can accept input right now.
    var isRunning: Bool {
        terminalStatus == .running || terminalStatus == .starting
    }

    /// Stopped and error rows need a fresh run rather than an attach.
    var needsRelaunchToOpen: Bool {
        switch terminalStatus {
        case .stopped, .error: true
        case .starting, .running, .exited, nil: false
        }
    }
}
