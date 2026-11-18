import Foundation

/// Syntax colors made for one version of a code block's text, in one theme
/// (colors are concrete per theme). They still color a block that grew past
/// that text, as a streamed block does: the part they cover stays colored
/// instead of flashing plain until highlighted again (PLAN 6.7).
nonisolated struct CodeColors: Sendable {
    /// A run of syntax color over UTF-16 offsets of the code.
    struct Run: Sendable {
        let range: Range<Int>
        let color: TextColor
    }

    /// The text the runs were made for.
    let code: String
    let runs: [Run]
    let isDark: Bool

    /// Whether these colors apply to `code`: made for it or for a prefix.
    func apply(to code: String, isDark: Bool) -> Bool {
        self.isDark == isDark && code.hasPrefix(self.code)
    }
}
