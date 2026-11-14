import Foundation

/// Rules both platforms use to decide whether a finished scroll resumes
/// following the transcript's end.
nonisolated enum ChatScrollFollowPolicy {
    /// Ignore subpixel frame noise while still noticing a one-pixel movement
    /// on Retina displays.
    static let minimumMovement: CGFloat = 0.5

    /// A scroll that ends at the transcript's end resumes following unless
    /// it moved toward older content: then the reader is leaving, and the
    /// end zone's hysteresis must not pull them back.
    static func shouldRestoreFollowingAfterUserScroll(
        startY: CGFloat?,
        endY: CGFloat?,
        isNearBottom: Bool
    ) -> Bool {
        guard isNearBottom else { return false }
        guard let startY, let endY else { return true }
        return endY >= startY - minimumMovement
    }
}
