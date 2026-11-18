import CoreGraphics
import CoreText
import Foundation

/// Text ready for Core Text: the attributed string carries fonts and a style
/// index per run; paragraphs and styles carry the rest. Lives only inside one
/// layout call (`NSMutableAttributedString` is not Sendable).
nonisolated struct StyledText {
    static let styleKey = NSAttributedString.Key("TranscriptStyleIndex")

    let string = NSMutableAttributedString()
    var paragraphs: [StyledParagraph] = []
    var styles: [TextRunStyle] = []
    var links: [URL] = []
    private var styleIndices: [TextRunStyle: Int] = [:]

    var length: Int { string.length }

    /// Appends `text` with one font and style.
    mutating func append(_ text: String, font: TranscriptFont, style: TextRunStyle) {
        guard !text.isEmpty else { return }
        let index: Int
        if let existing = styleIndices[style] {
            index = existing
        } else {
            index = styles.count
            styles.append(style)
            styleIndices[style] = index
        }
        string.append(
            NSAttributedString(
                string: text,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font.font,
                    Self.styleKey: NSNumber(value: index),
                ]))
    }

    mutating func link(_ url: URL) -> Int {
        links.append(url)
        return links.count - 1
    }
}
