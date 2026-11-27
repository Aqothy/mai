#if os(macOS)
    import AppKit

    /// One transcript row for VoiceOver: its text, or a disclosure button
    /// for a finished turn's header.
    nonisolated final class TranscriptAccessibilityElement: NSAccessibilityElement {
        var onPress: (@MainActor () -> Void)?

        override func accessibilityPerformPress() -> Bool {
            guard let onPress else { return false }
            // AppKit performs accessibility actions on the main thread.
            MainActor.assumeIsolated { onPress() }
            return true
        }
    }
#endif
