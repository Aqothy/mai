import CoreGraphics
import Foundation

/// How a transcript runs. DEBUG launch arguments switch the levers the
/// benchmarks compare: `-ChatTranscriptCaches off` (PLAN 3.1 rule 9) and
/// `-ChatTranscriptRaster main` (bands drawn on the main thread).
nonisolated struct TranscriptConfiguration: Sendable {
    /// Off in unit tests, which give rows their heights directly.
    var laysOutRows = true
    var cachesEnabled = true
    /// Bands draw on background tasks; the main thread only assigns bitmaps.
    var drawsOffMain = true
    /// Layout tasks running at once.
    var concurrency = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))

    static let testing = TranscriptConfiguration(laysOutRows: false, cachesEnabled: false)

    static var launch: TranscriptConfiguration {
        var configuration = TranscriptConfiguration()
        #if DEBUG
            let defaults = UserDefaults.standard
            if defaults.string(forKey: "ChatTranscriptCaches")?.lowercased() == "off" {
                configuration.cachesEnabled = false
            }
            if defaults.string(forKey: "ChatTranscriptRaster")?.lowercased() == "main" {
                configuration.drawsOffMain = false
            }
        #endif
        return configuration
    }
}
