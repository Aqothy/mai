import CoreGraphics
import Foundation

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Whether the reader asked for less motion: streamed text then shows at
/// once, without pacing (PLAN D2).
@MainActor
enum TranscriptMotion {
    static var isReduced: Bool {
        #if os(macOS)
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
            UIAccessibility.isReduceMotionEnabled
        #endif
    }
}
