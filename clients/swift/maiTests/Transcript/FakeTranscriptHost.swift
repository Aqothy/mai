import CoreGraphics
import Foundation

@testable import mai

/// A viewport with UIKit's semantics: an offset kept in range by the
/// document-height, size and inset setters, which move it synchronously and
/// report the move, as `UIScrollView` does (PLAN 3.9 rule 2). Reader moves
/// may overscroll.
@MainActor
final class FakeTranscriptHost: TranscriptViewportHost {
    weak var controller: TranscriptController?
    var size = CGSize(width: 300, height: 200)
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    private(set) var documentHeight: CGFloat = 0
    /// The platform offset: the document y at the viewport's top edge,
    /// under the top inset.
    private(set) var offset: CGFloat = 0
    private(set) var isContentVisible = false
    private(set) var rowPlacements = 0

    var animatesJumps = false

    var viewport: TranscriptViewport? {
        guard size.width > 0, size.height > 0 else { return nil }
        return TranscriptViewport(size: size, topInset: topInset, bottomInset: bottomInset)
    }

    var viewportTop: CGFloat { offset + topInset }
    var scale: CGFloat { 2 }

    private var maximumOffset: CGFloat {
        max(-topInset, documentHeight + bottomInset - size.height)
    }

    private func clampOffset() {
        offset = min(max(offset, -topInset), maximumOffset)
    }

    func setDocumentHeight(_ height: CGFloat) {
        documentHeight = height
        moved { clampOffset() }
    }

    func setViewportTop(_ top: CGFloat) {
        moved {
            offset = top - topInset
            clampOffset()
        }
    }

    func setContentVisible(_ visible: Bool) { isContentVisible = visible }

    func setNeedsRowPlacement() { rowPlacements += 1 }

    func setNeedsFrameUpdates(_ needed: Bool) {}

    // MARK: What the reader and the platform do

    /// The reader drags or flings the content to `offset`, past an edge if
    /// they hold it there.
    func readerScroll(toOffset offset: CGFloat) {
        moved { self.offset = offset }
    }

    func readerScroll(toTop top: CGFloat) { readerScroll(toOffset: top - topInset) }

    func setInsets(top: CGFloat, bottom: CGFloat) {
        moved {
            topInset = top
            bottomInset = bottom
            clampOffset()
        }
    }

    func resize(to size: CGSize) {
        moved {
            self.size = size
            clampOffset()
        }
    }

    private func moved(_ change: () -> Void) {
        let before = (offset, size, topInset, bottomInset)
        change()
        if before != (offset, size, topInset, bottomInset) {
            controller?.viewportDidChange()
        }
    }
}
