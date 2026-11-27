import CoreGraphics
import Foundation

/// How much of a row's top a new layout draws identically to the old one, so a
/// growing streamed block redraws only the bands below that (`REDESIGN.md §8`).
/// Operates directly on fitted `TextLine` geometry and `PreparedText` metadata
/// (no glyph-buffer comparison; O(log lines) `memcmp` for code blocks).
nonisolated enum RowContentDiff {
    static func unchangedHeight(_ old: RowContentLayout, _ new: RowContentLayout) -> CGFloat {
        switch (old, new) {
        case (.text(let before, let oldOrigin), .text(let after, let newOrigin)) where oldOrigin == newOrigin:
            return oldOrigin.y + unchangedHeight(before, after)
        case (.code(let before, let oldFrame), .code(let after, let newFrame))
        where oldFrame.origin == newFrame.origin
            && before.bodyOrigin == after.bodyOrigin
            && (oldFrame.width == newFrame.width
                || (before.bodyOrigin.x + before.bodySize.width <= min(oldFrame.width, newFrame.width)
                    && before.bodyOrigin.x + before.label.size.width <= min(oldFrame.width, newFrame.width)))
            && before.colorsAreDark == after.colorsAreDark && before.headerHeight == after.headerHeight
            && before.labelTop == after.labelTop && unchangedHeight(before.label, after.label) == .infinity:
            let bodyY = oldFrame.minY + before.bodyOrigin.y + before.unchangedBodyHeight(comparedTo: after)
            return oldFrame.height == newFrame.height ? bodyY : min(bodyY, min(oldFrame.maxY, newFrame.maxY))
        case (.codeBody(let before), .codeBody(let after))
        where before.bodyOrigin == after.bodyOrigin && before.colorsAreDark == after.colorsAreDark:
            return before.unchangedBodyHeight(comparedTo: after)
        case (.table(let before, let oldFrame), .table(let after, let newFrame))
        where oldFrame.origin == newFrame.origin
            && (oldFrame.width == newFrame.width || before.gridSize.width <= min(oldFrame.width, newFrame.width))
            && before.toolbarHeight == after.toolbarHeight:
            return oldFrame.minY + before.toolbarHeight + unchangedTableHeight(before, after)
        case (.tableBody(let before), .tableBody(let after)):
            return unchangedTableHeight(before, after)
        default:
            return 0
        }
    }

    static func unchangedHeight(_ before: TextLayout, _ after: TextLayout) -> CGFloat {
        if before.prepared === after.prepared && before.availableWidth == after.availableWidth {
            return .infinity
        }
        guard before.prepared.options == after.prepared.options else { return 0 }

        let oldText = before.prepared.text
        let newText = after.prepared.text
        let firstDiffUTF16 = firstDifferingUTF16(oldText, newText, oldRuns: before.prepared.runs, newRuns: after.prepared.runs)
        let shared = min(before.lines.count, after.lines.count)
        let margin: CGFloat = 2  // accounts for inline-code background / quote-bar protrusion above line.top
        for index in 0..<shared {
            let old = before.lines[index]
            let new = after.lines[index]
            guard old == new, old.range.upperBound <= firstDiffUTF16 else {
                return max(0, min(old.top, new.top) - margin)
            }
            if before.prepared.hasParagraphDecorations || after.prepared.hasParagraphDecorations {
                let oldPara = before.prepared.paragraphs.indices.contains(old.paragraphIndex)
                    ? before.prepared.paragraphs[old.paragraphIndex].styled : nil
                let newPara = after.prepared.paragraphs.indices.contains(new.paragraphIndex)
                    ? after.prepared.paragraphs[new.paragraphIndex].styled : nil
                if oldPara?.quoteBars != newPara?.quoteBars || oldPara?.isRule != newPara?.isRule
                    || oldPara?.taskMarker?.x != newPara?.taskMarker?.x
                    || oldPara?.taskMarker?.checked != newPara?.taskMarker?.checked
                    || (oldPara?.isRule == true && before.availableWidth != after.availableWidth)
                {
                    return max(0, min(old.top, new.top) - max(margin, max(old.gapAbove, new.gapAbove)))
                }
            }
        }
        if before.lines.count == after.lines.count {
            return firstDiffUTF16 == Int.max ? .infinity : max(0, min(before.size.height, after.size.height) - margin)
        }
        let extra = shared < before.lines.count ? before.lines[shared] : after.lines[shared]
        let extraGap = (before.prepared.hasParagraphDecorations || after.prepared.hasParagraphDecorations) ? extra.gapAbove : 0
        return max(0, extra.top - max(margin, extraGap))
    }

    /// Returns the first UTF-16 offset where either the string content or styled
    /// runs diverge (`Int.max` if identical end-to-end).
    private static func firstDifferingUTF16(
        _ a: String, _ b: String, oldRuns: [StyledRun], newRuns: [StyledRun]
    ) -> Int {
        var textDiff = Int.max
        if a != b {
            let aUTF16 = a.utf16
            let bUTF16 = b.utf16
            var aIdx = aUTF16.startIndex
            var bIdx = bUTF16.startIndex
            var off = 0
            while aIdx < aUTF16.endIndex, bIdx < bUTF16.endIndex, aUTF16[aIdx] == bUTF16[bIdx] {
                aUTF16.formIndex(after: &aIdx)
                bUTF16.formIndex(after: &bIdx)
                off += 1
            }
            textDiff = off
        }
        var runDiff = Int.max
        let sharedRuns = min(oldRuns.count, newRuns.count)
        for i in 0..<sharedRuns {
            let x = oldRuns[i]
            let y = newRuns[i]
            if x != y {
                if x.style == y.style && x.tabInterval == y.tabInterval && CFEqual(x.font.font, y.font.font)
                    && x.range.lowerBound == y.range.lowerBound
                {
                    runDiff = min(x.range.upperBound, y.range.upperBound)
                } else {
                    runDiff = min(x.range.lowerBound, y.range.lowerBound)
                }
                break
            }
        }
        if runDiff == Int.max && oldRuns.count != newRuns.count {
            let extra = sharedRuns < oldRuns.count ? oldRuns[sharedRuns] : newRuns[sharedRuns]
            runDiff = extra.range.lowerBound
        }
        return min(textDiff, runDiff)
    }

    private static func unchangedTableHeight(_ before: TableLayout, _ after: TableLayout) -> CGFloat {
        guard before.gridSize.width == after.gridSize.width else { return 0 }
        var lowest = CGFloat.infinity
        let shared = min(before.cells.count, after.cells.count)
        for index in 0..<shared {
            let old = before.cells[index]
            let new = after.cells[index]
            if old.row != new.row || old.column != new.column || old.origin != new.origin || old.box != new.box
                || unchangedHeight(old.layout, new.layout) != .infinity
            {
                lowest = min(lowest, min(old.box.minY, new.box.minY))
                break
            }
        }
        if lowest == .infinity {
            if shared < before.cells.count { lowest = min(lowest, before.cells[shared].box.minY) }
            if shared < after.cells.count { lowest = min(lowest, after.cells[shared].box.minY) }
        }
        let sharedDividers = min(before.dividers.count, after.dividers.count)
        var dividerDiff = sharedDividers
        for index in 0..<sharedDividers where before.dividers[index] != after.dividers[index] {
            dividerDiff = index
            break
        }
        if dividerDiff < sharedDividers || before.dividers.count != after.dividers.count {
            for index in dividerDiff..<before.dividers.count { lowest = min(lowest, before.dividers[index].minY - 1) }
            for index in dividerDiff..<after.dividers.count { lowest = min(lowest, after.dividers[index].minY - 1) }
        }
        if before.gridSize.height != after.gridSize.height {
            lowest = min(lowest, min(before.gridSize.height, after.gridSize.height))
        }
        return lowest == .infinity ? .infinity : max(0, lowest)
    }
}
