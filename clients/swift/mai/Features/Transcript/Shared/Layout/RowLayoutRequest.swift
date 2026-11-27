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
    /// Previous row content and layout at the same text size: reused on resize
    /// (code, tables) and extended incrementally while streaming open blocks.
    var previous: (kind: TranscriptRowKind, layout: RowLayout)?
}
