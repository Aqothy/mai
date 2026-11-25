import CoreGraphics
import CoreText
import Foundation
import IOSurface

@testable import mai

/// SplitMix64: every fuzz case is reproducible from its seed on any machine.
nonisolated struct FuzzRNG {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(in range: Range<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    mutating func chance(_ percent: Int) -> Bool { int(in: 0..<100) < percent }

    mutating func pick<T>(_ items: [T]) -> T { items[int(in: 0..<items.count)] }
}

/// Inputs and oracles shared by the transcript fuzzers.
nonisolated enum TranscriptFuzz {
    /// Iterations multiply by `MAI_FUZZ_SCALE` (`TEST_RUNNER_MAI_FUZZ_SCALE=50`
    /// with `xcodebuild test`) for long local runs; the default keeps the
    /// suite fast and deterministic.
    static let scale = max(1, Int(ProcessInfo.processInfo.environment["MAI_FUZZ_SCALE"] ?? "") ?? 1)

    /// Text that breaks text engines (Ghostty's and Blink's line-breaking and
    /// shaping corpora): combining marks, ZWJ and modifier emoji, flags,
    /// variation selectors, keycaps, CJK, Hangul, Indic and Southeast Asian
    /// reordering scripts, soft hyphens, no-break and zero-width spaces,
    /// tabs, CR, ligature-forming ASCII and long unbreakable tokens.
    static let adversarialTokens: [String] = [
        "word", "transcript", "a", " ", "  ", "\t", "\u{00A0}", "\u{00AD}", "\u{200B}", "\u{2060}", "-", "—", ".",
        ",", "()", "\"quoted\"", "café", "cafe\u{0301}", "n\u{0308}\u{0308}a", "漢字", "かな", "。", "한글",
        "Привет", "Ελληνικά", "👍", "👍🏼", "👩🏽‍💻", "👩‍👩‍👧‍👦", "🏴‍☠️", "#️⃣", "✌️", "✌︎", "🇦🇧🇨", "\u{1FB70}",
        "===", "!==", "->", "fi", "ffl", "अपार्टमेंट", "রাষ্ট্র্রে", "\u{0F00}", "\u{1A2F}\u{1A70}", "ไทย", "ສະບາຍດີ",
        "https://example.com/a/very/long/path?query=value&other=thing", "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
        "1,234.56", "$100", "e=mc²", "\u{1D400}\u{1D401}",
    ]

    /// What a model can emit past `adversarialTokens` (kept apart so its
    /// seeds still replay): C0 and C1 controls, NUL, ANSI escapes, a lone CR,
    /// vertical tab, form feed, line and paragraph separators, BiDi marks,
    /// overrides and isolates, BOM, noncharacters, private use, unassigned
    /// and tag code points, tag-sequence and keycap emoji, text-presentation
    /// emoji, CJK Extension B, mathematical letters, hieroglyphs, Tibetan,
    /// Myanmar, Khmer, Mongolian, Thai, Tamil, Sinhala and Devanagari
    /// conjuncts with ZWJ and ZWNJ, Hebrew and Arabic with marks, Hangul
    /// jamo and fillers, wide and zero-width spaces, and an orphan combining
    /// mark. (U+FDD0 is built at run time: Swift rejects it in a literal.)
    static let unicodeEdgeTokens: [String] = [
        "\u{0000}", "\u{0001}", "\u{001B}[31m", "\u{007F}", "\u{0085}", "\u{009B}", "\r", "\u{000B}", "\u{000C}",
        "\u{2028}", "\u{2029}", "\u{200E}", "\u{200F}", "\u{061C}", "\u{202E}abc\u{202C}", "\u{2067}x\u{2069}",
        "\u{FEFF}", "\u{FFFE}", "\u{FFFF}", String(Unicode.Scalar(0xFDD0 as UInt16) ?? "?"), "\u{10FFFF}", "\u{E000}", "\u{F8FF}", "\u{F0000}", "\u{0378}",
        "\u{E0001}", "🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}", "1\u{FE0F}\u{20E3}", "😀\u{FE0E}",
        "🧑🏿‍🤝‍🧑🏻", "🫨", "🇺🇳", "𠜎𠜱𡃁", "𝕏𝔸𝓩", "𓀀𓁐", "བོད་ཡིག", "ཀྵྐྵ", "မြန်မာ", "ភាសាខ្មែរ", "ᠮᠣᠩᠭᠣᠯ",
        "ᠠ\u{180E}ᠡ", "ก่ก้ำ", "ஸ்ரீ", "ශ්\u{200D}රී", "क्ष", "क्\u{200D}ष", "क्\u{200C}ष", "שָׁלוֹם", "مَرْحَبًا", "١٢٣",
        "\u{FDFA}", "\u{1100}\u{1161}\u{11A8}", "\u{115F}\u{1160}", "\u{3164}", "\u{2003}", "\u{3000}", "\u{200C}",
        "\u{200D}", "\u{2062}", "\u{FFFD}", "\u{FFFC}", "\u{0301}", "ß", "İ", "ﬃ", "\u{212B}", "ǅ",
    ]

    /// Random text of about `utf16Length` units from `tokens`; with
    /// `newlines`, some hard line breaks.
    static func adversarialText(
        _ rng: inout FuzzRNG, utf16Length: Int, newlines: Bool = false, tokens: [String] = adversarialTokens
    ) -> String {
        var text = ""
        var count = 0
        while count < utf16Length {
            let token = newlines && rng.chance(2) ? "\n" : rng.pick(tokens)
            text += token
            count += token.utf16.count
        }
        return text
    }

    static let words = [
        "stream", "layout", "the", "band", "of", "and", "frame", "text", "glyph", "scroll", "café", "漢字", "👍🏼",
        "Привет", "naïve", "https://example.com/path", "x",
    ]

    /// A random Markdown reply: paragraphs long enough to wrap many lines
    /// (incremental layout keeps at least two), fences (closed, open, wide,
    /// tabbed), tables, lists, quotes, headings and rules, with inline
    /// emphasis, code, links and strikethrough.
    static func markdownDocument(_ rng: inout FuzzRNG, blocks: Int, vocabulary: [String] = words) -> String {
        func paragraph(_ rng: inout FuzzRNG, words count: Int) -> String {
            Self.paragraph(&rng, words: count, vocabulary: vocabulary)
        }
        var parts: [String] = []
        for _ in 0..<blocks {
            switch rng.int(in: 0..<10) {
            case 0, 1, 2, 3:
                parts.append(paragraph(&rng, words: rng.int(in: 5..<(rng.chance(15) ? 1_600 : 160))))
            case 4:
                parts.append(String(repeating: "#", count: rng.int(in: 1..<4)) + " " + paragraph(&rng, words: 6))
            case 5:
                parts.append(fence(&rng))
            case 6:
                let columns = rng.int(in: 1..<5)
                var table = "|" + (0..<columns).map { " H\($0) |" }.joined() + "\n|"
                table += (0..<columns).map { _ in rng.pick([" --- |", " :-: |", " --: |"]) }.joined()
                for _ in 0..<rng.int(in: 0..<8) {
                    table += "\n|" + (0..<columns).map { _ in " " + paragraph(&rng, words: rng.int(in: 1..<5)) + " |" }.joined()
                }
                parts.append(table)
            case 7:
                let ordered = rng.chance(40)
                parts.append(
                    (0..<rng.int(in: 1..<6)).map { index in
                        let marker = ordered ? "\(index + 1)." : rng.pick(["-", "*", "- [ ]", "- [x]"])
                        return marker + " " + paragraph(&rng, words: rng.int(in: 1..<30))
                    }.joined(separator: "\n"))
            case 8:
                parts.append("> " + paragraph(&rng, words: rng.int(in: 3..<60)))
            default:
                parts.append(rng.pick(["---", "***", "___"]))
            }
        }
        // The last block is often left open: streaming ends mid-fence too.
        return parts.joined(separator: "\n\n")
    }

    private static func paragraph(_ rng: inout FuzzRNG, words count: Int, vocabulary: [String]) -> String {
        (0..<count).map { _ in
            let word = rng.pick(vocabulary)
            switch rng.int(in: 0..<14) {
            case 0: return "**\(word)**"
            case 1: return "*\(word)*"
            case 2: return "`\(word)`"
            case 3: return "[\(word)](https://example.com/\(word.utf8.count))"
            case 4: return "~~\(word)~~"
            default: return word
            }
        }.joined(separator: " ")
    }

    private static func fence(_ rng: inout FuzzRNG) -> String {
        let wide = rng.chance(30)
        let lines = (0..<rng.int(in: 1..<(rng.chance(10) ? 400 : 40))).map { index -> String in
            var line = (rng.chance(30) ? "\t" : "    ") + "let value\(index) = compute(\(index))"
            if wide { line += " // " + String(repeating: "wide-payload-", count: rng.int(in: 4..<20)) }
            if rng.chance(10) { line += " " + rng.pick(adversarialTokens) }
            return line
        }
        return "```" + rng.pick(["swift", "go", "", "json"]) + "\n" + lines.joined(separator: "\n") + "\n```"
    }

    /// Character-aligned cuts of `text` in random steps up to `maxStep`
    /// UTF-8 bytes, ending with the whole text.
    static func prefixes(of text: String, _ rng: inout FuzzRNG, maxStep: Int) -> [String] {
        let utf8 = text.utf8
        var end = utf8.startIndex
        var result: [String] = []
        while end < utf8.endIndex {
            end = utf8.index(end, offsetBy: rng.int(in: 1..<(maxStep + 1)), limitedBy: utf8.endIndex) ?? utf8.endIndex
            while end < utf8.endIndex, end.samePosition(in: text) == nil { utf8.formIndex(after: &end) }
            result.append(String(text[..<end]))
        }
        return result
    }

    // MARK: Oracles

    /// The first difference between two layouts, nil when they draw, hit
    /// test and select identically.
    static func difference(_ a: TextLayout, _ b: TextLayout) -> String? {
        if a.string != b.string { return "string" }
        if a.size != b.size { return "size \(a.size) vs \(b.size)" }
        if a.links != b.links { return "links" }
        if a.lines.count != b.lines.count { return "line count \(a.lines.count) vs \(b.lines.count)" }
        for (index, (x, y)) in zip(a.lines, b.lines).enumerated() {
            guard x.range == y.range else { return "line \(index) range \(x.range) vs \(y.range)" }
            guard x.top == y.top, x.baseline == y.baseline, x.height == y.height else {
                return "line \(index) metrics \(x.top)/\(x.baseline)/\(x.height) vs \(y.top)/\(y.baseline)/\(y.height)"
            }
            guard x.x == y.x, x.width == y.width else { return "line \(index) x/width" }
            guard x.caretOffsets == y.caretOffsets else {
                let at = x.caretOffsets.indices.first { $0 < y.caretOffsets.count && x.caretOffsets[$0] != y.caretOffsets[$0] } ?? 0
                let units = Array(a.string.utf16)[x.range]
                return "line \(index) caret \(at): \(x.caretOffsets[at]) vs \(y.caretOffsets[at]) in "
                    + "\(units.map { String($0, radix: 16) })"
            }
            guard x.endsWithNewline == y.endsWithNewline else { return "line \(index) newline" }
            guard x.runs.count == y.runs.count else { return "line \(index) run count" }
            guard x.decorations.count == y.decorations.count else { return "line \(index) decoration count" }
        }
        if a.runs.count != b.runs.count { return "run count" }
        for (index, (x, y)) in zip(a.runs, b.runs).enumerated() {
            guard x.glyphs == y.glyphs, x.positions == y.positions else {
                func describe(_ run: TextGlyphRun) -> String {
                    "\(CTFontCopyPostScriptName(run.font.font)) \(run.range) \(run.glyphs) \(run.positions.map(\.x))"
                }
                return "run \(index) glyphs: \(describe(x)) vs \(describe(y))"
            }
            guard x.range == y.range, x.color == y.color, x.linkIndex == y.linkIndex, CFEqual(x.font.font, y.font.font)
            else { return "run \(index) attributes" }
        }
        if a.decorations.count != b.decorations.count { return "decoration count" }
        for (index, (x, y)) in zip(a.decorations, b.decorations).enumerated() {
            guard x.kind == y.kind, x.rect == y.rect, x.color == y.color else { return "decoration \(index)" }
        }
        return nil
    }

    static func difference(_ a: RowContentLayout, _ b: RowContentLayout) -> String? {
        switch (a, b) {
        case (.text(let x, let xo), .text(let y, let yo)):
            return xo != yo ? "origin" : difference(x, y)
        case (.code(let x, let xf), .code(let y, let yf)):
            guard xf == yf, x.size == y.size, x.contentWidth == y.contentWidth, x.headerHeight == y.headerHeight,
                x.code == y.code
            else { return "code frame" }
            return difference(x.label, y.label).map { "label: \($0)" } ?? difference(x.body, y.body).map { "body: \($0)" }
        case (.table(let x, let xf), .table(let y, let yf)):
            guard xf == yf, x.size == y.size, x.gridSize == y.gridSize, x.cells.count == y.cells.count,
                x.dividers == y.dividers
            else { return "table frame" }
            for (index, (p, q)) in zip(x.cells, y.cells).enumerated() {
                guard p.origin == q.origin, p.box == q.box else { return "cell \(index) box" }
                if let diff = difference(p.layout, q.layout) { return "cell \(index): \(diff)" }
            }
            return nil
        default:
            return "case \(a) vs \(b)"
        }
    }

    /// The first offset inside a grapheme cluster whose caret is not the
    /// caret before it (Blink places carets only at cluster boundaries), nil
    /// when every line keeps that rule. Clusters are the engine's
    /// (`TextLayoutEngine.startsCluster`): Apple's sequences answer per
    /// offset (after a stray ZWJ, the sequence at the ZWJ's base runs on
    /// through the next letter, while the letter's own starts at the
    /// letter, as UAX #29 has it).
    static func caretInsideCluster(_ layout: TextLayout) -> String? {
        let ns = layout.string as NSString
        for (index, line) in layout.lines.enumerated() {
            for offset in (line.range.lowerBound + 1)..<max(line.range.lowerBound + 1, line.range.upperBound) {
                let local = offset - line.range.lowerBound
                guard !TextLayoutEngine.startsCluster(ns, at: offset), line.caretOffsets[local] != line.caretOffsets[local - 1]
                else { continue }
                let cluster = ns.rangeOfComposedCharacterSequence(at: offset)
                let scalars = ns.substring(with: cluster).unicodeScalars.map { String($0.value, radix: 16) }
                return "line \(index) \(line.range) offset \(offset) inside cluster \(cluster) \(scalars)"
            }
        }
        return nil
    }

    /// `content` rasterized at `rect` the way a band is, as bytes.
    static func pixels(_ content: RowContentLayout, rect: CGRect, drawsWideBody: Bool, palette: TextPalette) -> [UInt8]? {
        guard
            let bitmap = BandRasterizer.bitmap(
                BandRaster(
                    content: content, palette: palette, drawsWideBody: drawsWideBody, rect: rect, scale: 1,
                    colorSpace: RowLayer.colorSpace))
        else { return nil }
        let surface = bitmap.surface
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let rowBytes = surface.width * 4
        var bytes: [UInt8] = []
        bytes.reserveCapacity(rowBytes * surface.height)
        let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        for row in 0..<surface.height {
            bytes.append(contentsOf: UnsafeBufferPointer(start: base + row * surface.bytesPerRow, count: rowBytes))
        }
        return bytes
    }
}
