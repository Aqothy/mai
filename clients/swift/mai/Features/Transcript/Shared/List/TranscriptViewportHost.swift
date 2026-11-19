import CoreGraphics
import Foundation

/// The platform scroll view as `TranscriptController` drives it. The host
/// reports every viewport move and resize to the controller synchronously
/// (`viewportDidChange()`) and moves the viewport only when the controller
/// asks. Coordinates are the document's, top down; a viewport top is the
/// document y at the top of the uncovered area.
@MainActor
protocol TranscriptViewportHost: AnyObject {
    /// Nil until layout gives the viewport a size.
    var viewport: TranscriptViewport? { get }
    var viewportTop: CGFloat { get }
    /// Pixels per point of the display the transcript is on.
    var scale: CGFloat { get }
    /// May move the viewport to keep it inside the content (UIKit does, in
    /// the setter).
    func setDocumentHeight(_ height: CGFloat)
    /// Moves the uncovered top to `top`, kept inside the content.
    func setViewportTop(_ top: CGFloat)
    /// The transcript stays invisible until its first rows land on the end.
    func setContentVisible(_ visible: Bool)
    /// Rows moved, appeared, left or got new layouts: place and mount them
    /// before the frame commits.
    func setNeedsRowPlacement()
    /// Calls `TranscriptController.frameDidTick()` once per display frame
    /// while needed (a reply streams), from the platform's frame driver.
    func setNeedsFrameUpdates(_ needed: Bool)
    /// The selection changed: redraw its highlight on the mounted rows.
    func setNeedsSelectionDisplay()
    /// Whether a jump to the end animates (iOS) or lands at once (Mac).
    var animatesJumps: Bool { get }
    /// Ends a fling where it is, before an animated jump takes over.
    func stopDeceleration()
}

extension TranscriptViewportHost {
    func setNeedsSelectionDisplay() {}
    var animatesJumps: Bool { false }
    func stopDeceleration() {}
}
