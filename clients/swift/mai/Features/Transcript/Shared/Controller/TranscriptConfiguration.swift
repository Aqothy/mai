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
    /// Fixed per-frame time budget (seconds) for synchronously preparing
    /// small visible blank rows when fast scrolling or scrollbar scrubbing
    /// outruns off-main prefetch (`0` disables synchronous fallback).
    var syncFallbackBudget: CFTimeInterval = 0.004

    static let testing = TranscriptConfiguration(laysOutRows: false, syncFallbackBudget: 0)

    static var launch: TranscriptConfiguration {
        var configuration = TranscriptConfiguration()
        #if DEBUG
            if UserDefaults.standard.string(forKey: "ChatTranscriptRaster")?.lowercased() == "main" {
                configuration.drawsOffMain = false
            }
            if UserDefaults.standard.object(forKey: "ChatTranscriptSyncBudgetMs") != nil {
                let ms = UserDefaults.standard.double(forKey: "ChatTranscriptSyncBudgetMs")
                configuration.syncFallbackBudget = max(0, ms / 1_000)
            }
        #endif
        return configuration
    }
}
