import Foundation

/// Display-ready projection of a listed session: the title fallback and
/// timestamp parse happen once at load time instead of in every row body.
/// The original summary is kept because an import sends its folders and
/// title back to the daemon.
struct SessionImportEntry: Identifiable, Equatable {
    let summary: SessionSummary
    let title: String
    let updatedAt: Date?

    var id: String { summary.sessionID }
    var cwd: String? { summary.cwd }
    /// The chat the session is part of, when it is one: it is opened, not
    /// imported.
    var threadID: String? { summary.thread }

    init(summary: SessionSummary) {
        self.summary = summary
        let trimmedTitle = summary.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = trimmedTitle.isEmpty ? summary.sessionID : trimmedTitle
        updatedAt = Self.parseTimestamp(summary.updatedAt)
    }

    /// `updatedAt` arrives as an RFC 3339 string whose fractional seconds are
    /// optional, so parsing tries both forms.
    private static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return WireJSON.parseDate(raw)
    }
}

extension SessionSummary: Equatable {
    public static func == (lhs: SessionSummary, rhs: SessionSummary) -> Bool {
        lhs.sessionID == rhs.sessionID
            && lhs.additionalDirectories == rhs.additionalDirectories
            && lhs.title == rhs.title
            && lhs.cwd == rhs.cwd
            && lhs.thread == rhs.thread
            && lhs.updatedAt == rhs.updatedAt
    }
}
