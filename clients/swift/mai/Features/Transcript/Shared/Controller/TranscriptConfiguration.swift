import Foundation

/// How a transcript runs.
nonisolated struct TranscriptConfiguration: Sendable {
    /// Off in unit tests, which give rows their heights directly.
    var laysOutRows = true
    /// Layout tasks running at once.
    var concurrency = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))

    static let testing = TranscriptConfiguration(laysOutRows: false)
}
