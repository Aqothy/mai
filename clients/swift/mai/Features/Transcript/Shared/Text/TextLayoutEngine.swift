import CoreGraphics
import CoreText
import Foundation

/// Text measurement, cluster rules, BiDi direction, and on-demand line carets
/// (`REDESIGN.md §4, §9`).
///
/// Layout now prepares segment widths via `PreparedText` (`FontWidthTable` +
/// `CFStringTokenizer`, falling back to in-context Core Text shaping for
/// complex scripts) and fits lines with pure arithmetic; Core Text shapes and
/// draws only visible lines (`TextRenderer`) and computes carets only for
/// queried lines (`TextLayout.shapedLine(at:)`).
nonisolated enum TextLayoutEngine {
    struct Options: Equatable, Sendable {
        var lineSpacing: CGFloat
        /// Code never wraps; each source line is one line.
        var wraps = true
        /// Every line this tall instead of its own metrics (code).
        var fixedLineHeight: CGFloat?
        var quoteBarWidth: CGFloat = 3
        /// Right-align RTL paragraphs (`dir="auto"`) to `availableWidth`;
        /// disabled for shrink-wrapped user bubbles so short Arabic prompts
        /// stay compact.
        var alignsRTLToWidth = true
    }

    static func layout(
        _ text: StyledText, width: CGFloat, options: Options, previous: PreparedText? = nil
    ) -> TextLayout {
        guard text.length > 0 else { return .empty }
        let prepared = PreparedText(text, options: options, previous: previous)
        return prepared.fit(width: width)
    }

    // MARK: - Clusters & Line Terminators (`PLAN §4.4`)

    /// Whether `index` starts a cluster, as carets, hit tests and selection
    /// edges take them: Apple's composed character sequence there starts at
    /// `index` (asked per offset, as `NSTextView` does), or a control/line
    /// break ends just before it (UAX #29 GB4).
    static func startsCluster(_ string: NSString, at index: Int) -> Bool {
        index == 0 || endsCluster(string.character(at: index - 1))
            || CFStringGetRangeOfComposedCharactersAtIndex(string, index).location == index
    }

    /// The cluster containing `index` (Apple's composed character sequence,
    /// clipped at GB4 cluster-ending controls so it agrees with `startsCluster`).
    static func clusterRange(in string: NSString, at index: Int) -> NSRange {
        guard index >= 0, index < string.length else { return NSRange(location: index, length: 0) }
        if endsCluster(string.character(at: index)) { return NSRange(location: index, length: 1) }
        var range = string.rangeOfComposedCharacterSequence(at: index)
        while range.location < index, endsCluster(string.character(at: range.location)) {
            range.location += 1
            range.length -= 1
        }
        return range
    }

    /// The smallest cluster-aligned range covering `range`.
    static func clusterRange(in string: NSString, for range: NSRange) -> NSRange {
        guard range.length > 0 else { return range }
        let start = clusterRange(in: string, at: range.location).location
        let end = NSMaxRange(clusterRange(in: string, at: NSMaxRange(range) - 1))
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Mandatory line breaks (UAX #14 BK, CR, LF, NL).
    static func endsLine(_ unit: unichar) -> Bool {
        switch unit {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: true
        default: false
        }
    }

    /// UAX #9 Class B paragraph separators that reset Core Text's BiDi base
    /// writing direction (`LF`, `CR`, `NEL`, `PS`; unlike `VT`/`FF`/`LS`).
    @inline(__always)
    static func isBiDiParagraphSeparator(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x85 || unit == 0x2029
    }

    /// Characters that always end a grapheme cluster (UAX #29 GB4: C0/C1
    /// controls including `\t`, CR, LF, and line/paragraph separators).
    static func endsCluster(_ unit: unichar) -> Bool {
        unit < 0x20 || (unit >= 0x7F && unit <= 0x9F) || unit == 0x2028 || unit == 0x2029
    }

    // MARK: - Paragraph Direction (`dir="auto"`, UAX #9 P2/P3)

    /// Conservative UTF-16 check covering Hebrew, Arabic, Syriac, Thaana, NKo,
    /// Samaritan, Mandaic, BiDi control marks, Arabic Presentation Forms, and
    /// astral RTL script high surrogates.
    static func isBiDiCodeUnit(_ u: unichar) -> Bool {
        if u >= 0x0590 && u <= 0x08FF { return true }
        if u >= 0x200E && u <= 0x200F { return true }
        if u >= 0x202A && u <= 0x202E { return true }
        if u >= 0x2066 && u <= 0x2069 { return true }
        if u >= 0xD802 && u <= 0xD803 { return true }
        if u >= 0xD83A && u <= 0xD83B { return true }
        if u >= 0xFB1D && u <= 0xFDFF { return true }
        if u >= 0xFE70 && u <= 0xFEFC { return true }
        return false
    }

    private enum StrongDirection { case ltr, rtl }

    @inline(__always)
    private static func strongDirection(of unit: unichar) -> StrongDirection? {
        if endsLine(unit) { return .ltr }
        if (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) { return .ltr }
        if unit >= 0x0590 {
            if unit == 0x061C || unit == 0x200F
                || unit == 0xD802 || unit == 0xD803 || unit == 0xD83A || unit == 0xD83B
                || (unit >= 0xFB1D && unit <= 0xFDFF) || (unit >= 0xFE70 && unit <= 0xFEFC)
            {
                return .rtl
            }
            if unit <= 0x08FF {
                if let scalar = UnicodeScalar(unit), scalar.properties.isAlphabetic { return .rtl }
            } else if unit == 0x200E {
                return .ltr
            } else if let scalar = UnicodeScalar(unit), scalar.properties.isAlphabetic {
                return .ltr
            }
        } else if unit >= 0x00C0, let scalar = UnicodeScalar(unit), scalar.properties.isAlphabetic {
            return .ltr
        }
        return nil
    }

    /// UAX #9 P2/P3 (`dir="auto"`): true when the paragraph starting at
    /// `start` has a strong right-to-left character before any strong
    /// left-to-right character.
    static func paragraphIsRTL(_ string: NSString, startingAt start: Int) -> Bool {
        let length = string.length
        var index = max(0, start)
        while index < length {
            if let direction = strongDirection(of: string.character(at: index)) {
                return direction == .rtl
            }
            index += 1
        }
        return false
    }

    /// Core Text's UAX #9 BiDi paragraph base direction starting at `start`,
    /// scanning until a Class B paragraph separator (`LF`/`CR`/`NEL`/`PS`).
    static func bidiParagraphIsRTL(_ string: NSString, startingAt start: Int) -> Bool {
        let length = string.length
        var index = max(0, start)
        while index < length {
            let u = string.character(at: index)
            if isBiDiParagraphSeparator(u) { return false }
            if endsLine(u) {
                index += 1
                continue
            }
            // Decode astral surrogate pairs so mathematical/CJK-ExtB/hieroglyph
            // LTR letters count as strong LTR rather than being skipped.
            if u >= 0xD800 && u <= 0xDBFF, index + 1 < length {
                let lo = string.character(at: index + 1)
                if lo >= 0xDC00 && lo <= 0xDFFF {
                    let cp = 0x10000 + ((UInt32(u - 0xD800) << 10) | UInt32(lo - 0xDC00))
                    if (cp >= 0x10800 && cp <= 0x10FFF) || (cp >= 0x1E800 && cp <= 0x1EFFF) {
                        return true
                    }
                    if let scalar = UnicodeScalar(cp), scalar.properties.isAlphabetic {
                        return false
                    }
                    index += 2
                    continue
                }
            }
            if let direction = strongDirection(of: u) {
                return direction == .rtl
            }
            index += 1
        }
        return false
    }

    /// Leading x for a line (`dir="auto"` flush-right alignment for RTL
    /// paragraphs within `[indent, availableWidth]`).
    static func lineOriginX(indent: CGFloat, lineWidth: CGFloat, availableWidth: CGFloat, isRTL: Bool) -> CGFloat {
        guard isRTL, availableWidth.isFinite else { return indent }
        return max(indent, availableWidth - lineWidth)
    }

    // MARK: - On-Demand Carets (`REDESIGN.md §9`)

    static func needsCoreTextCarets(_ run: CTRun) -> Bool {
        !CTRunGetStatus(run).isDisjoint(with: [.rightToLeft, .nonMonotonic])
    }

    /// Caret x before each UTF-16 offset of `line`, and after its last,
    /// computed natively via `CTLineEnumerateCaretOffsets` (called only on
    /// queried lines, never eagerly during layout).
    static func caretOffsets(
        of line: CTLine, range: Range<Int>, string: NSString, indent: CGFloat, width: CGFloat
    ) -> [CGFloat] {
        enumeratedCaretOffsets(of: line, range: range, string: string, indent: indent, width: width)
    }

    /// Core Text's caret offsets, filtered to composed-sequence cluster starts
    /// so hit tests never land inside Myanmar/Devanagari/emoji clusters.
    static func enumeratedCaretOffsets(
        of line: CTLine, range: Range<Int>, string: NSString? = nil, indent: CGFloat, width: CGFloat
    ) -> [CGFloat] {
        var offsets = [CGFloat](repeating: .nan, count: range.count + 1)
        let start = range.lowerBound
        CTLineEnumerateCaretOffsets(line) { offset, index, leadingEdge, _ in
            let position: Int
            if leadingEdge {
                if let string, !startsCluster(string, at: index) { return }
                position = index - start
            } else {
                let next = index + 1
                if let string, next < string.length, !startsCluster(string, at: next) { return }
                position = next - start
            }
            guard offsets.indices.contains(position) else { return }
            if leadingEdge || offsets[position].isNaN { offsets[position] = indent + CGFloat(offset) }
        }
        return filled(offsets, indent: indent, width: width)
    }

    private static func filled(_ offsets: [CGFloat], indent: CGFloat, width: CGFloat) -> [CGFloat] {
        var offsets = offsets
        var last = indent
        for index in offsets.indices {
            if offsets[index].isNaN { offsets[index] = index == offsets.count - 1 ? max(last, indent + width) : last }
            last = offsets[index]
        }
        return offsets
    }
}
