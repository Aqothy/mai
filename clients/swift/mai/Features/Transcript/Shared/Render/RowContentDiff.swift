import CoreGraphics
import Foundation

/// How much of a row's top a new layout draws exactly as the old one did,
/// so a growing streamed block redraws only the bands below that (PLAN 6.5):
/// a reply's tail adds lines at its bottom, a code block appends lines. A
/// new width whose line breaks fall where they did redraws nothing.
nonisolated enum RowContentDiff {
    /// The height, from the row's top, that draws the same; 0 when the row
    /// changed shape or style, infinity when nothing changed.
    static func unchangedHeight(_ old: RowContentLayout, _ new: RowContentLayout) -> CGFloat {
        switch (old, new) {
        case (.text(let before, let oldOrigin), .text(let after, let newOrigin)) where oldOrigin == newOrigin:
            return oldOrigin.y + unchangedHeight(before, after)
        case (.code(let before, let oldFrame), .code(let after, let newFrame))
        // The block's width is its shape layer's: the label and an unclipped
        // body (a clipped one scrolls in its own view) draw the same.
        where oldFrame.origin == newFrame.origin
            && before.colorsAreDark == after.colorsAreDark && before.label.string == after.label.string:
            return oldFrame.minY + before.bodyOrigin.y + unchangedHeight(before.body, after.body)
        default:
            return 0
        }
    }

    static func unchangedHeight(_ before: TextLayout, _ after: TextLayout) -> CGFloat {
        let shared = min(before.lines.count, after.lines.count)
        for index in 0..<shared {
            let old = before.lines[index]
            let new = after.lines[index]
            guard old.top == new.top, old.height == new.height, old.range == new.range, old.x == new.x,
                old.width == new.width, sameRuns(before, old.runs, after, new.runs)
            else { return min(old.top, new.top) }
        }
        if before.lines.count == after.lines.count { return .infinity }
        return (shared < before.lines.count ? before.lines[shared] : after.lines[shared]).top
    }

    private static func sameRuns(_ a: TextLayout, _ aRuns: Range<Int>, _ b: TextLayout, _ bRuns: Range<Int>) -> Bool {
        guard aRuns.count == bRuns.count else { return false }
        for (left, right) in zip(aRuns, bRuns) {
            let x = a.runs[left]
            let y = b.runs[right]
            guard x.color == y.color, x.linkIndex == y.linkIndex, x.glyphs == y.glyphs, x.positions == y.positions
            else { return false }
        }
        return true
    }
}
