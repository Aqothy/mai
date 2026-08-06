import Foundation

/// Equatable so identical daemon reports do not replace row state or
/// invalidate terminal rows.
extension TerminalSummary: Equatable {
    public static func == (lhs: TerminalSummary, rhs: TerminalSummary) -> Bool {
        lhs.terminalID == rhs.terminalID
            && lhs.title == rhs.title
            && lhs.cwd == rhs.cwd
            && lhs.status == rhs.status
            && lhs.columns == rhs.columns
            && lhs.rows == rhs.rows
            && lhs.exitCode == rhs.exitCode
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
    }
}

/// Presentation values for terminal rows and detail chrome. Rows receive only
/// these derived values, never live output or store objects.
extension TerminalSummary {
    var terminalStatus: MaidTerminalStatus? {
        MaidTerminalStatus(rawValue: status)
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

    /// Compact lifecycle label for list rows. Unknown future statuses render
    /// as a neutral absent label rather than crashing or guessing.
    var statusLabel: String? {
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
