import CoreText
import CoreGraphics
import Foundation

/// A Core Text font that crosses threads. Apple's Core Text overview: font
/// objects (`CTFont`, `CTFontDescriptor`) can be used simultaneously by
/// multiple operations, work queues or threads, unlike layout objects.
nonisolated struct TranscriptFont: @unchecked Sendable {
    let font: CTFont

    var pointSize: CGFloat { CTFontGetSize(font) }
    var ascent: CGFloat { CTFontGetAscent(font) }
    var descent: CGFloat { CTFontGetDescent(font) }
    var leading: CGFloat { CTFontGetLeading(font) }
    var lineHeight: CGFloat { ceil(ascent + descent + leading) }

    /// The bold and/or italic face of this font, or the font itself when the
    /// family has none.
    func with(bold: Bool, italic: Bool) -> TranscriptFont {
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty,
            let styled = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, traits, traits)
        else { return self }
        return TranscriptFont(font: styled)
    }
}
