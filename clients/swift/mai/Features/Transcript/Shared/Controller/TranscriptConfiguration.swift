import Foundation

/// How a transcript runs. A DEBUG launch argument switches the lever the
/// benchmarks compare: `-ChatTranscriptRaster main` (bands drawn on the
/// main thread).
nonisolated struct TranscriptConfiguration: Sendable {
    /// Off in unit tests, which give rows their heights directly.
    var laysOutRows = true
    /// Bands draw on background tasks for off-screen prefetch; visible non-current
    /// bands always draw in the frame (`REDESIGN.md §7 R3`).
    var drawsOffMain = true
    /// Layout tasks running at once.
    var concurrency = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))

    static let testing = TranscriptConfiguration(laysOutRows: false)

    static var launch: TranscriptConfiguration {
        var configuration = TranscriptConfiguration()
        #if DEBUG
            if UserDefaults.standard.string(forKey: "ChatTranscriptRaster")?.lowercased() == "main" {
                configuration.drawsOffMain = false
            }
        #endif
        return configuration
    }
}
