#if DEBUG && os(macOS)
    import Foundation

    /// `-ChatTranscriptBlockMainThread <ms>` stalls the main thread that long
    /// every frame. Scrolling with a trackpad stays smooth under it only if
    /// AppKit's responsive scrolling is on, which moves already-drawn content
    /// without waiting for the main thread (PLAN 3.7). Trackpad input cannot
    /// be synthesized, so a person checks it.
    enum TranscriptMainThreadBlocker {
        static let milliseconds = UserDefaults.standard.integer(forKey: "ChatTranscriptBlockMainThread")

        static func blockIfRequested() {
            guard milliseconds > 0 else { return }
            Thread.sleep(forTimeInterval: Double(milliseconds) / 1_000)
        }
    }
#endif
