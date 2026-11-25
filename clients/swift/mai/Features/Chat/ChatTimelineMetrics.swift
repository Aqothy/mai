import SwiftUI

nonisolated enum ChatContentMetrics {
    /// Keeps the transcript aligned with the composer and avoids reflowing
    /// readable text whenever surrounding navigation columns animate.
    static let maximumWidth: CGFloat = 760
}
