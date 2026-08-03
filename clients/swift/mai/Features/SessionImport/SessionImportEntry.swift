import Foundation

/// Display-ready projection of an importable session: the title fallback and
/// timestamp parse happen once at load time instead of in every row body.
/// The original summary is kept because `provider.importSession` echoes it
/// back to the daemon.
struct SessionImportEntry: Identifiable, Equatable {
    let summary: SessionSummary
    let title: String
    let updatedAt: Date?

    var id: String { summary.sessionID }
    var cwd: String? { summary.cwd }

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
        return (try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(raw, strategy: .iso8601))
    }
}

extension SessionSummary: Equatable {
    public static func == (lhs: SessionSummary, rhs: SessionSummary) -> Bool {
        lhs.sessionID == rhs.sessionID
            && lhs.title == rhs.title
            && lhs.cwd == rhs.cwd
            && lhs.updatedAt == rhs.updatedAt
    }
}
