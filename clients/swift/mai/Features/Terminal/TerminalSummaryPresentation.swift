import Foundation

/// Equatable so identical daemon reports do not replace row state or
/// invalidate terminal rows.
extension TerminalSummary: Equatable {
    public static func == (lhs: TerminalSummary, rhs: TerminalSummary) -> Bool {
        lhs.terminalID == rhs.terminalID
            && lhs.title == rhs.title
            && lhs.cwd == rhs.cwd
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
            && lhs.programTitle == rhs.programTitle
            && lhs.pwd == rhs.pwd
            && lhs.programStatus == rhs.programStatus
    }
}

extension TerminalProgramStatus: Equatable {
    public static func == (lhs: TerminalProgramStatus, rhs: TerminalProgramStatus) -> Bool {
        lhs.state == rhs.state
            && lhs.need == rhs.need
            && lhs.progress == rhs.progress
            && lhs.app == rhs.app
            && lhs.title == rhs.title
            && lhs.message == rhs.message
            && lhs.updatedAt == rhs.updatedAt
    }
}

/// Presentation values for terminal rows and detail chrome. Rows receive only
/// these derived values, never live output or store objects. Program text
/// comes from the program, sanitized by the daemon.
extension TerminalSummary {
    /// What the program reports doing; nil when it reports nothing, or a
    /// future state, which renders neutrally.
    var programState: MaidTerminalProgramState? {
        programStatus.flatMap { MaidTerminalProgramState(rawValue: $0.state) }
    }

    /// The persisted title, falling back to the working directory name.
    var displayTitle: String {
        if !title.isEmpty { return title }
        return workingDirectoryName ?? String(localized: "Terminal")
    }

    /// The directory the shell last reported (OSC 7), else the one it
    /// started in.
    var workingDirectoryName: String? {
        if let pwd, !pwd.isEmpty {
            let path = URL(string: pwd).flatMap { $0.scheme == "file" ? $0.path() : nil } ?? pwd
            return URL(filePath: path).lastPathComponent
        }
        guard !cwd.isEmpty else { return nil }
        return URL(filePath: cwd).lastPathComponent
    }

    /// Row subtitle: the title the program set, when it adds something,
    /// otherwise the working directory name.
    var displaySubtitle: String? {
        if let programTitle, !programTitle.isEmpty, programTitle != displayTitle {
            return programTitle
        }
        return workingDirectoryName
    }

    /// Shared thread-list indicator. A terminal without a report stays quiet;
    /// reports use the same visuals as agent rows.
    var rowIndicatorStatus: ThreadRowIndicatorStatus? {
        switch programState {
        case .blocked: .needsInput
        case .working: .working
        case .done: .done
        case .error: .failed
        case .idle, nil: nil
        }
    }

    /// Compact status for list rows: what the program reports, if anything.
    var statusLabel: String? {
        switch programState {
        case .blocked:
            switch programStatus?.need.flatMap(MaidTerminalProgramNeed.init(rawValue:)) {
            case .permission: String(localized: "Needs permission")
            case .answer: String(localized: "Needs an answer")
            case .auth: String(localized: "Needs sign-in")
            case nil: String(localized: "Needs input")
            }
        case .working:
            if let progress = programStatus?.progress {
                String(localized: "Working \(progress)%")
            } else {
                String(localized: "Working")
            }
        case .done: String(localized: "Done")
        case .error: String(localized: "Failed")
        case .idle: String(localized: "Ready")
        case nil: nil
        }
    }
}
