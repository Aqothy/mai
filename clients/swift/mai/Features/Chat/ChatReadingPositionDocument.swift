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
    /// Whether the viewport shows the content's end, or nearly.
    var isNearBottom: Bool { get }
    /// Called with the viewport top a move began at when the viewport moves
    /// and neither the document nor a viewport change moved it: the reader
    /// did, by whatever input. Small steps add up until they count.
    var onReaderScroll: ((_ fromTop: CGFloat) -> Void)? { get set }
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
    /// is, whatever happened above it, or the reader keeps their place in
    /// its content when the row itself left.
    func updateGeometry(_ change: () -> Void) {
        let follows = isFollowingBottom
        let top = follows ? nil : viewportTop
        let place = top.flatMap {
            geometry.readingPlace(
                atViewportTop: $0, markerHeight: ChatTimelineMetrics.historyMarkerHeight)
        }
        change()
        applyGeometryToViews()
        if follows {
            scrollToBottom()
        } else if let top {
            // Without a place to keep, the viewport still moves back inside
            // content that may have shrunk under it.
            setViewportTop(place.flatMap(geometry.offset(for:)) ?? top)
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

    func alignInitialBottomIfPossible() {
        guard let completion = initialBottomAlignmentCompletion, scrollToBottom() else { return }
        initialBottomAlignmentCompletion = nil
        // This can run inside a layout pass, where the completion's SwiftUI
        // state change must not land.
        Task { @MainActor in completion() }
    }
}
