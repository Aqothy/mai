import CoreGraphics
import Foundation

/// Text laid out once, off the main thread, as plain values: what drawing,
/// measuring, hit testing, selection and accessibility all read (PLAN 3.1
/// rule 8). Core Text's layout objects never outlive the task that made
/// them; this is what they leave behind.
nonisolated struct TextLayout: Sendable {
    /// The drawn text, for copy and selection offsets (UTF-16).
    let string: String
    let size: CGSize
    let lines: [TextLine]
    let runs: [TextGlyphRun]
    let decorations: [TextDecoration]
    let links: [URL]
    /// True if any line had right-to-left or non-monotonic runs (incremental
    /// suffix layout falls back to full layout so BiDi reordering stays exact).
    let hasComplexBiDi: Bool

    init(
        string: String, size: CGSize, lines: [TextLine], runs: [TextGlyphRun], decorations: [TextDecoration],
        links: [URL], hasComplexBiDi: Bool = false
    ) {
        self.string = string
        self.size = size
        self.lines = lines
        self.runs = runs
        self.decorations = decorations
        self.links = links
        self.hasComplexBiDi = hasComplexBiDi
    }

    /// About how much memory the layout holds: per UTF-16 unit a caret
    /// (8 B), a glyph and its position (18 B) and the text (~2 B); per line
    /// its record and caret array (~144 B).
    var retainedBytes: Int { 28 * (lines.last?.range.upperBound ?? 0) + 144 * lines.count }

    static let empty = TextLayout(string: "", size: .zero, lines: [], runs: [], decorations: [], links: [])

    /// The lines overlapping `minY..<maxY`, for drawing one band.
    func lines(overlapping minY: CGFloat, _ maxY: CGFloat) -> ArraySlice<TextLine> {
        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].bottom <= minY { low = middle + 1 } else { high = middle }
        }
        var end = low
        while end < lines.count, lines[end].top < maxY { end += 1 }
        return lines[low..<end]
    }
}
