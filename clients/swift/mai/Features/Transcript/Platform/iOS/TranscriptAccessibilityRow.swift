#if os(iOS)
    import UIKit

    /// One transcript row for VoiceOver: its text, or a button for a
    /// finished turn's header that expands or collapses its work.
    final class TranscriptAccessibilityRow: UIAccessibilityElement {
        var onActivate: (() -> Void)?

        override func accessibilityActivate() -> Bool {
            guard let onActivate else { return false }
            onActivate()
            return true
        }
    }
#endif
