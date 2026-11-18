import CoreGraphics
import Foundation

/// Everything one row's layout needs, as values, so it runs on any thread.
nonisolated struct RowLayoutRequest: Sendable {
    let rowID: String
    let kind: TranscriptRowKind
    let key: RowLayoutKey
    let style: TextStyle
    /// Syntax colors for a code block, made for its code.
    var codeColors: CodeColors?
    /// The code block's current layout at the same text size and colors:
    /// a new width reuses its text instead of laying the code out again.
    var previousCode: CodeLayout?
}
