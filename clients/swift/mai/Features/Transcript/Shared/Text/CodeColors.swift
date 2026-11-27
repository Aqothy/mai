import Foundation

/// Syntax colors made for one code block's text, in one theme (colors are
/// concrete per theme). Kept with the block's layout so a new width or text
/// size lays it out colored again instead of plain then colored.
nonisolated struct CodeColors: Equatable, Sendable {
    /// A run of syntax color over UTF-16 offsets of the code.
    struct Run: Equatable, Sendable {
        let range: Range<Int>
        let color: TextColor
    }

    /// The text the runs were made for.
    let code: String
    let runs: [Run]
    let isDark: Bool

    func matches(code: String, isDark: Bool) -> Bool {
        self.isDark == isDark && self.code == code
    }
}
