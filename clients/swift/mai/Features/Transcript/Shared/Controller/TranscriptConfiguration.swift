import CoreGraphics
import Foundation

/// How a transcript runs. A DEBUG launch argument switches the lever the
/// benchmarks compare: `-ChatTranscriptRaster main` (bands drawn on the
/// main thread).
nonisolated struct TranscriptConfiguration: Sendable {
    /// Off in unit tests, which give rows their heights directly.
    var laysOutRows = true
    /// Bands draw on background tasks; the main thread only assigns bitmaps.
    var drawsOffMain = true
    /// Layout tasks running at once.
    var concurrency = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount - 2))
    /// Per-frame time budget (seconds) for synchronously preparing visible
    /// blank rows of normal size when fast scrolling or scrollbar scrubbing
    /// outruns off-main prefetch. Giant blocks always stay off-main; 0 disables
    /// synchronous fallback.
    var syncFallbackBudget: CFTimeInterval = 0.004

    static let testing = TranscriptConfiguration(laysOutRows: false, syncFallbackBudget: 0)

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
