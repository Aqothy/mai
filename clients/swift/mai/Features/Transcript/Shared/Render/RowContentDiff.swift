import CoreGraphics
import Foundation

/// How much of a row's top a new layout draws exactly as the old one did,
/// so a growing streamed block redraws only the bands below that (PLAN 6.5):
/// a reply's tail adds lines at its bottom, a code block appends lines, a
/// table appends rows. A new width whose line breaks fall where they did
/// redraws nothing.
nonisolated enum RowContentDiff {
    /// The height, from the row's top, that draws the same; 0 when the row
    /// changed shape or style, infinity when nothing changed.
    static func unchangedHeight(_ old: RowContentLayout, _ new: RowContentLayout) -> CGFloat {
        switch (old, new) {
        case (.text(let before, let oldOrigin), .text(let after, let newOrigin)) where oldOrigin == newOrigin:
            return oldOrigin.y + unchangedHeight(before, after)
        case (.code(let before, let oldFrame), .code(let after, let newFrame))
        where oldFrame.origin == newFrame.origin
            && before.colorsAreDark == after.colorsAreDark && before.headerHeight == after.headerHeight
            && before.labelTop == after.labelTop && unchangedHeight(before.label, after.label) == .infinity:
            return oldFrame.minY + before.bodyOrigin.y + unchangedHeight(before.body, after.body)
        case (.codeBody(let before), .codeBody(let after))
        where before.bodyOrigin == after.bodyOrigin && before.colorsAreDark == after.colorsAreDark:
            return unchangedHeight(before.body, after.body)
        case (.table(let before, let oldFrame), .table(let after, let newFrame))
        where oldFrame.origin == newFrame.origin && before.toolbarHeight == after.toolbarHeight:
            return oldFrame.minY + before.toolbarHeight + unchangedTableHeight(before, after)
        case (.tableBody(let before), .tableBody(let after)):
            return unchangedTableHeight(before, after)
        default:
            return 0
        }
    }

    static func unchangedHeight(_ before: TextLayout, _ after: TextLayout) -> CGFloat {
        let linesY = unchangedLinesHeight(before, after)
        let decY = unchangedDecorationsHeight(before.decorations, after.decorations)
        return min(linesY, decY)
    }

    private static func unchangedLinesHeight(_ before: TextLayout, _ after: TextLayout) -> CGFloat {
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

    private static func unchangedDecorationsHeight(_ before: [TextDecoration], _ after: [TextDecoration]) -> CGFloat {
        let shared = min(before.count, after.count)
        for index in 0..<shared {
            let old = before[index]
            let new = after[index]
            guard old.kind == new.kind, old.rect == new.rect, old.color == new.color else {
                return max(0, min(old.rect.minY, new.rect.minY))
            }
        }
        if before.count == after.count { return .infinity }
        let extra = shared < before.count ? before[shared] : after[shared]
        return max(0, extra.rect.minY)
    }

    private static func unchangedTableHeight(_ before: TableLayout, _ after: TableLayout) -> CGFloat {
        guard before.gridSize.width == after.gridSize.width else { return 0 }
        let shared = min(before.cells.count, after.cells.count)
        for index in 0..<shared {
            let old = before.cells[index]
            let new = after.cells[index]
            guard old.row == new.row, old.column == new.column, old.origin == new.origin, old.box == new.box,
                unchangedHeight(old.layout, new.layout) == .infinity
            else { return min(old.box.minY, new.box.minY) }
        }
        if before.cells.count == after.cells.count, before.dividers == after.dividers { return .infinity }
        let dividerIndex = min(before.dividers.count, after.dividers.count)
        for index in 0..<dividerIndex where before.dividers[index] != after.dividers[index] {
            return min(before.dividers[index].minY, after.dividers[index].minY)
        }
        if shared < before.cells.count { return before.cells[shared].box.minY }
        if shared < after.cells.count { return after.cells[shared].box.minY }
        return min(before.gridSize.height, after.gridSize.height)
    }

    private static func sameRuns(_ a: TextLayout, _ aRuns: Range<Int>, _ b: TextLayout, _ bRuns: Range<Int>) -> Bool {
        guard aRuns.count == bRuns.count else { return false }
        for (left, right) in zip(aRuns, bRuns) {
            let x = a.runs[left]
            let y = b.runs[right]
            guard x.color == y.color, x.linkIndex == y.linkIndex, x.font.font == y.font.font,
                x.glyphs == y.glyphs, x.positions == y.positions
            else { return false }
        }
        return true
    }
}
