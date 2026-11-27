import CoreGraphics
import CoreText
import Foundation

/// A styled span inside `StyledText` and `PreparedText`: plain values so
/// preparing and resizing text never allocates an `NSAttributedString` unless
/// a paragraph needs in-context shaping or a line is actually drawn on screen.
nonisolated struct StyledRun: Equatable, Sendable {
    var range: Range<Int>  // UTF-16 range
    var font: TranscriptFont
    var style: TextRunStyle
    /// Non-zero for code spans (4-column tab stops, `TextStyle.codeTabInterval`).
    var tabInterval: CGFloat = 0

    static func == (lhs: StyledRun, rhs: StyledRun) -> Bool {
        lhs.range == rhs.range && lhs.style == rhs.style && lhs.tabInterval == rhs.tabInterval
            && CFEqual(lhs.font.font, rhs.font.font)
    }
}

/// Text ready for `PreparedText` / `TextLayoutEngine`: plain Swift `String` +
/// styled value spans + paragraph descriptors, zero `NSAttributedString`
/// allocation on the width-table path (`REDESIGN.md §4`).
nonisolated struct StyledText: Sendable {
    static let styleKey = NSAttributedString.Key("TranscriptStyleIndex")

    var text = ""
    private(set) var length = 0
    var runs: [StyledRun] = []
    var paragraphs: [StyledParagraph] = []
    private(set) var links: [URL] = []
    private var linkIndices: [URL: Int] = [:]

    init(existingLinks: [URL] = []) {
        guard !existingLinks.isEmpty else { return }
        links = existingLinks
        linkIndices.reserveCapacity(existingLinks.count)
        for (index, url) in existingLinks.enumerated() where linkIndices[url] == nil {
            linkIndices[url] = index
        }
    }

    /// Appends `string` with one font and style, coalescing adjacent identical
    /// runs so plain paragraphs stay a single span.
    mutating func append(_ string: String, font: TranscriptFont, style: TextRunStyle, tabInterval: CGFloat = 0) {
        guard !string.isEmpty else { return }
        let start = length
        let count = string.utf16.count
        text += string
        length += count
        if let lastIndex = runs.indices.last,
            runs[lastIndex].range.upperBound == start,
            runs[lastIndex].style == style,
            runs[lastIndex].tabInterval == tabInterval,
            CFEqual(runs[lastIndex].font.font, font.font)
        {
            runs[lastIndex].range = runs[lastIndex].range.lowerBound..<length
        } else {
            runs.append(StyledRun(range: start..<length, font: font, style: style, tabInterval: tabInterval))
        }
    }

    /// Sets tab stops every `interval` points across UTF-16 `range` (for code
    /// blocks and nested code in lists, `PLAN §4.4`).
    mutating func setTabInterval(_ interval: CGFloat, in range: NSRange) {
        guard range.length > 0 else { return }
        let lo = range.location
        let hi = NSMaxRange(range)
        for index in runs.indices where runs[index].range.lowerBound >= lo && runs[index].range.upperBound <= hi {
            runs[index].tabInterval = interval
        }
    }

    mutating func link(_ url: URL) -> Int {
        if let existing = linkIndices[url] { return existing }
        let index = links.count
        links.append(url)
        linkIndices[url] = index
        return index
    }

    /// Builds an `NSAttributedString` for a UTF-16 slice (used only for visible
    /// drawn lines and in-context Core Text shaping windows).
    static func attributedSlice(
        of text: NSString,
        range: Range<Int>,
        runs: [StyledRun],
        palette: TextPalette? = nil,
        includeStyleIndex: Bool = false,
        baseWritingDirection: CTWritingDirection? = nil
    ) -> NSAttributedString {
        guard !range.isEmpty else { return NSAttributedString() }
        let sub = text.substring(with: NSRange(location: range.lowerBound, length: range.count))
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let paraKey = NSAttributedString.Key(kCTParagraphStyleAttributeName as String)

        // Binary search for the first run overlapping `range.lowerBound`.
        var low = 0
        var high = runs.count
        while low < high {
            let mid = (low + high) / 2
            if runs[mid].range.upperBound <= range.lowerBound { low = mid + 1 } else { high = mid }
        }
        guard low < runs.count else { return NSAttributedString(string: sub) }

        // Fast path: entire slice covered by a single run (95% of drawn lines).
        let first = runs[low]
        if first.range.lowerBound <= range.lowerBound && first.range.upperBound >= range.upperBound {
            var attrs: [NSAttributedString.Key: Any] = [fontKey: first.font.font]
            if let palette, let cgColor = palette.color(first.style.color) {
                attrs[colorKey] = cgColor
            }
            if includeStyleIndex {
                attrs[Self.styleKey] = NSNumber(value: low)
            }
            if let pStyle = paragraphStyle(tabInterval: first.tabInterval, baseWritingDirection: baseWritingDirection) {
                attrs[paraKey] = pStyle
            }
            return NSAttributedString(string: sub, attributes: attrs)
        }

        let attributed = NSMutableAttributedString(string: sub)
        var idx = low
        while idx < runs.count, runs[idx].range.lowerBound < range.upperBound {
            let run = runs[idx]
            let segLo = max(run.range.lowerBound, range.lowerBound)
            let segHi = min(run.range.upperBound, range.upperBound)
            if segLo < segHi {
                var attrs: [NSAttributedString.Key: Any] = [fontKey: run.font.font]
                if let palette, let cgColor = palette.color(run.style.color) {
                    attrs[colorKey] = cgColor
                }
                if includeStyleIndex {
                    attrs[Self.styleKey] = NSNumber(value: idx)
                }
                if let pStyle = paragraphStyle(tabInterval: run.tabInterval, baseWritingDirection: baseWritingDirection) {
                    attrs[paraKey] = pStyle
                }
                attributed.addAttributes(attrs, range: NSRange(location: segLo - range.lowerBound, length: segHi - segLo))
            }
            idx += 1
        }
        return attributed
    }

    private nonisolated(unsafe) static let ltrParagraphStyle: CTParagraphStyle = makeParagraphStyle(
        tabInterval: 0, baseWritingDirection: .leftToRight)
    private nonisolated(unsafe) static let rtlParagraphStyle: CTParagraphStyle = makeParagraphStyle(
        tabInterval: 0, baseWritingDirection: .rightToLeft)

    private static func paragraphStyle(
        tabInterval: CGFloat, baseWritingDirection: CTWritingDirection?
    ) -> CTParagraphStyle? {
        if tabInterval <= 0 {
            guard let dir = baseWritingDirection else { return nil }
            switch dir {
            case .leftToRight: return ltrParagraphStyle
            case .rightToLeft: return rtlParagraphStyle
            default: return makeParagraphStyle(tabInterval: 0, baseWritingDirection: dir)
            }
        }
        return makeParagraphStyle(tabInterval: tabInterval, baseWritingDirection: baseWritingDirection)
    }

    static func tabParagraphStyle(interval: CGFloat) -> CTParagraphStyle {
        makeParagraphStyle(tabInterval: interval, baseWritingDirection: nil)
    }

    private static func makeParagraphStyle(
        tabInterval: CGFloat, baseWritingDirection: CTWritingDirection?
    ) -> CTParagraphStyle {
        let stops = [] as CFArray
        let dir = baseWritingDirection ?? .natural
        return withUnsafePointer(to: stops) { stopsPtr in
            withUnsafePointer(to: tabInterval) { intervalPtr in
                withUnsafePointer(to: dir) { dirPtr in
                    var settings: [CTParagraphStyleSetting] = []
                    if tabInterval > 0 {
                        settings.append(
                            CTParagraphStyleSetting(
                                spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: stopsPtr))
                        settings.append(
                            CTParagraphStyleSetting(
                                spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size, value: intervalPtr))
                    }
                    if baseWritingDirection != nil {
                        settings.append(
                            CTParagraphStyleSetting(
                                spec: .baseWritingDirection, valueSize: MemoryLayout<CTWritingDirection>.size,
                                value: dirPtr))
                    }
                    _ = dir
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
    }
}
