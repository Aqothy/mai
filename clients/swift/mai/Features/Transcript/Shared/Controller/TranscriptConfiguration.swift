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
    /// Explicit per-frame time budget (seconds) for synchronously preparing
    /// visible blank rows of normal size when fast scrolling or scrollbar
    /// scrubbing outruns off-main prefetch. `nil` adapts to half of the host
    /// display's current frame interval (~4.2 ms at 120 Hz ProMotion, ~8.3 ms
    /// at 60 Hz or in Low Power Mode); `0` disables synchronous fallback.
    var syncFallbackBudget: CFTimeInterval?

    static let testing = TranscriptConfiguration(laysOutRows: false, syncFallbackBudget: 0)

    /// Resolves the per-frame synchronous fallback budget for a display running
    /// at `maximumFramesPerSecond`. Low Power Mode caps ProMotion displays to
    /// 60 Hz on iOS and macOS, doubling the safe frame interval.
    func effectiveSyncFallbackBudget(
        maximumFramesPerSecond: Int,
        isLowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    ) -> CFTimeInterval {
        if let explicit = syncFallbackBudget {
            return max(0, explicit)
        }
        let fps = isLowPowerMode ? 60 : max(60, maximumFramesPerSecond)
        return min(0.0085, max(0.004, 0.5 / Double(fps)))
    }

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
