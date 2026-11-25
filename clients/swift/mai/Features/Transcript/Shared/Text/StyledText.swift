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
    private(set) var links: [URL] = []
    private var styleIndices: [TextRunStyle: Int] = [:]
    private var linkIndices: [URL: Int] = [:]

    init(existingLinks: [URL] = []) {
        guard !existingLinks.isEmpty else { return }
        links = existingLinks
        linkIndices.reserveCapacity(existingLinks.count)
        for (index, url) in existingLinks.enumerated() where linkIndices[url] == nil {
            linkIndices[url] = index
        }
    }

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

    /// Tab stops every `interval` points across `range`, in place of Core
    /// Text's default twelve stops 28 pt apart.
    mutating func setTabInterval(_ interval: CGFloat, in range: NSRange) {
        guard range.length > 0 else { return }
        let stops = [] as CFArray
        let paragraphStyle = withUnsafePointer(to: stops) { stops in
            withUnsafePointer(to: interval) { interval in
                let settings = [
                    CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: stops),
                    CTParagraphStyleSetting(
                        spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size, value: interval),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        string.addAttribute(
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String), value: paragraphStyle, range: range)
    }

    mutating func link(_ url: URL) -> Int {
        if let existing = linkIndices[url] { return existing }
        let index = links.count
        links.append(url)
        linkIndices[url] = index
        return index
    }
}
