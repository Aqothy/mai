import Foundation

/// The reading-position rules both platforms' transcript documents follow.
/// A document owns its row geometry and its scroll position together: a
/// geometry change keeps the row being read where it is, or lands on the
/// end while following, before the frame is drawn. A platform document
/// only says where its viewport is and how to move it.
@MainActor
protocol ChatReadingPositionDocument: AnyObject {
    var geometry: ChatVirtualTranscriptGeometry { get set }
    /// Whether a geometry change should land on the transcript's end.
    var isBottomFollowingEnabled: () -> Bool { get set }
    /// Set from asking for the first rows to land on the transcript's end
    /// until they have.
    var initialBottomAlignmentCompletion: (() -> Void)? { get set }
    /// Where the uncovered top of the viewport is in the document, or nil
    /// without a viewport.
    var viewportTop: CGFloat? { get }
    /// The `viewportTop` that shows the content's end, or nil until there
    /// are rows and a viewport.
    var bottomViewportTop: CGFloat? { get }
    /// Moves the uncovered top of the viewport to `top`, kept inside the
    /// content unless the reader is holding it past an end.
    func setViewportTop(_ top: CGFloat)
    /// Applies the current geometry to the mounted rows and the
    /// scrollable extent.
    func applyGeometryToViews()
}

extension ChatReadingPositionDocument {
    var isFollowingBottom: Bool {
        initialBottomAlignmentCompletion != nil || isBottomFollowingEnabled()
    }

    /// The only way row geometry changes. While following, the viewport
    /// lands on the new end; otherwise the row being read stays where it
    /// is, whatever happened above it.
    ///
    /// A row being read can leave: a finished reply's live row becomes its
    /// settled blocks, and its turn's work folds behind a header above it.
    /// What follows such a row is the same content as before, so the
    /// reader then keeps their distance from the end.
    func updateGeometry(_ change: () -> Void) {
        let follows = isFollowingBottom
        let top = follows ? nil : viewportTop
        let anchor = top.flatMap {
            geometry.readingAnchor(
                atViewportTop: $0, markerHeight: ChatTimelineMetrics.historyMarkerHeight)
        }
        let distanceFromEnd = top.map { geometry.totalHeight - $0 }
        change()
        applyGeometryToViews()
        if follows {
            scrollToBottom()
        } else if let anchor, let distanceFromEnd {
            setViewportTop(
                geometry.offset(for: anchor) ?? geometry.totalHeight - distanceFromEnd)
        }
    }

    /// Moves to the exact end of the content. Returns false until there
    /// are rows and a viewport.
    @discardableResult
    func scrollToBottom() -> Bool {
        guard let top = bottomViewportTop else { return false }
        setViewportTop(top)
        return true
    }

    func beginInitialBottomAlignment(completion: @escaping () -> Void) {
        initialBottomAlignmentCompletion = completion
        alignInitialBottomIfPossible()
    }

    /// Ends a pending alignment where the viewport is; the reader took over
    /// before the first rows arrived.
    func completeInitialBottomAlignment() {
        guard let completion = initialBottomAlignmentCompletion else { return }
        initialBottomAlignmentCompletion = nil
        // This can run inside a layout pass, where the completion's SwiftUI
        // state change must not land.
        Task { @MainActor in completion() }
    }

    func alignInitialBottomIfPossible() {
        guard initialBottomAlignmentCompletion != nil, scrollToBottom() else { return }
        completeInitialBottomAlignment()
    }
}
