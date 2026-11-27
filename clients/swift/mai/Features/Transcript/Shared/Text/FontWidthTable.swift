import CoreGraphics
import CoreText
import Foundation
import Synchronization

/// Typographic vertical metrics of a font (or a fallback font chosen by Core
/// Text for a cluster), combined per line as `ceil(max ascent + max descent +
/// max leading)` to match `CTLineGetTypographicBounds`.
nonisolated struct LineFontMetrics: Hashable, Sendable {
    var ascent: Float
    var descent: Float
    var leading: Float

    static let zero = LineFontMetrics(ascent: 0, descent: 0, leading: 0)

    init(ascent: Float, descent: Float, leading: Float) {
        self.ascent = ascent
        self.descent = descent
        self.leading = leading
    }

    init(font: CTFont) {
        self.ascent = Float(CTFontGetAscent(font))
        self.descent = Float(CTFontGetDescent(font))
        self.leading = Float(CTFontGetLeading(font))
    }

    @inline(__always)
    mutating func formMax(_ other: LineFontMetrics) {
        if other.ascent > ascent { ascent = other.ascent }
        if other.descent > descent { descent = other.descent }
        if other.leading > leading { leading = other.leading }
    }

    @inline(__always)
    var lineHeight: CGFloat {
        ceil(CGFloat(ascent) + CGFloat(descent) + CGFloat(leading))
    }

    @inline(__always)
    var isZero: Bool {
        ascent == 0 && descent == 0 && leading == 0
    }
}

/// Per-`CTFont` character width, pair kerning, and fallback-font metrics table.
/// Shared across prose, headings, lists, quotes, tables, and code blocks to
/// avoid Core Text per-line shaping on verified scripts (ASCII, Latin, Greek,
/// Cyrillic, CJK, Kana, Hangul, fullwidth punctuation, and emoji).
///
/// Built lazily once per distinct `(font, size, traits)` via batched `CTLine`s
/// (~11 ms for SF Pro, ~0.1 ms for SF Mono). Non-ASCII clusters and pairs fill
/// lazily under a lock.
nonisolated final class FontWidthTable: @unchecked Sendable {
    private struct CacheKey: Hashable {
        let name: String
        let sizeBits: UInt64
        let traits: UInt32
    }

    private struct NonASCIICache {
        var clusters: [String: (width: Float, metrics: LineFontMetrics)] = [:]
        var pairKern: [String: Float] = [:]
        var bmpClusters: [UInt16: (width: Float, metrics: LineFontMetrics)] = [:]
        var bmpPairKern: [UInt32: Float] = [:]
    }

    private static let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
    private static let tableCache = Mutex<[CacheKey: [FontWidthTable]]>([:])

    let font: CTFont
    let baseMetrics: LineFontMetrics
    let isMonospace: Bool
    /// Fixed horizontal advance of printable ASCII if uniform (monospace fonts), else 0.
    let uniformASCIIAdvance: CGFloat
    /// Nominal advances for ASCII `0..<128` (`0` for control chars).
    let asciiWidths: [Float]
    /// Pre-resolved glyph IDs for ASCII `0..<128` (`0` for control chars), used
    /// by `TextRenderer.drawSlicedASCIICodeLine` to draw pure-ASCII monospace
    /// code directly via `CTFontDrawGlyphs` without per-line `CTLine` creation.
    let asciiGlyphs: [CGGlyph]
    /// Flat `128 * 128` pair kerning adjustments for ASCII pairs `(a, b)`.
    let asciiKern: [Float]
    /// True when at least one ASCII pair kerns (false for SF Mono / Menlo).
    let hasASCIIKerning: Bool
    /// True when common ASCII pairs (fi/fl/ff/ffi/ffl) form ligature glyphs in
    /// this font (false for SF Pro / SF Mono). Fonts with ASCII ligatures fall
    /// back to `CTLineDraw` in `TextRenderer` so ligatures render identically.
    let hasASCIILigatures: Bool
    /// ASCII characters that exhibit 3-char contextual width shifts in this font
    /// (e.g. SF Pro `:` between digits `1:2`). Segments triggering one use
    /// in-context Core Text shaping so measured widths stay exact.
    let contextualASCIIChars: Set<UInt16>

    private let nonASCII = Mutex<NonASCIICache>(NonASCIICache())

    static func table(for font: TranscriptFont) -> FontWidthTable {
        table(for: font.font)
    }

    static func table(for font: CTFont) -> FontWidthTable {
        let name = CTFontCopyPostScriptName(font) as String
        let size = CTFontGetSize(font)
        let traits = CTFontGetSymbolicTraits(font).rawValue
        let key = CacheKey(name: name, sizeBits: Double(size).bitPattern, traits: traits)
        if let existing = tableCache.withLock({ entries -> FontWidthTable? in
            entries[key]?.first { CFEqual($0.font, font) }
        }) {
            return existing
        }
        let built = FontWidthTable(font: font)
        return tableCache.withLock { entries in
            if let existing = entries[key]?.first(where: { CFEqual($0.font, font) }) {
                return existing
            }
            entries[key, default: []].append(built)
            return built
        }
    }

    private init(font: CTFont) {
        self.font = font
        self.baseMetrics = LineFontMetrics(font: font)
        let traits = CTFontGetSymbolicTraits(font)
        self.isMonospace = traits.contains(.traitMonoSpace)

        let ascii: [UInt16] = Array(0x20..<0x7F)
        let count = ascii.count
        var widths = [Float](repeating: 0, count: 128)
        var glyphTable = [CGGlyph](repeating: 0, count: 128)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var advs = [CGSize](repeating: .zero, count: count)
        let allMapped = CTFontGetGlyphsForCharacters(font, ascii, &glyphs, count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advs, count)
        let firstAdv = advs.first?.width ?? 0
        var uniform = allMapped && firstAdv > 0
        for i in 0..<count {
            let adv = advs[i].width
            let code = Int(ascii[i])
            widths[code] = Float(adv)
            glyphTable[code] = glyphs[i]
            if abs(adv - firstAdv) > 0.01 { uniform = false }
        }
        self.asciiWidths = widths
        self.asciiGlyphs = glyphTable
        self.uniformASCIIAdvance = uniform ? firstAdv : 0

        var kern = [Float](repeating: 0, count: 128 * 128)
        var anyKern = false

        // Monospace fonts like SF Mono / Menlo have zero kerned pairs; verify
        // quickly on a probe containing common kern/contextual pairs before
        // running the full 95×95 table scan.
        if self.isMonospace {
            let probe = "AVToTaWaVeYoLT,.:\";'fi12:34"
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: probe, attributes: [Self.fontKey: font]))
            let expected = probe.utf16.reduce(0.0) { $0 + Double(widths[Int($1)]) }
            let actual = CTLineGetTypographicBounds(line, nil, nil, nil)
            if abs(actual - expected) < 1e-4 {
                self.asciiKern = kern
                self.hasASCIIKerning = false
                self.hasASCIILigatures = false
                self.contextualASCIIChars = []
                return
            }
        }

        // Batched CTLine scan: 6 rows (~1,710 UTF-16 units) per CTLine, keeping
        // every line well below Core Text's 10,240-unit long-mode threshold.
        let rowsPerBatch = 6
        var rowStart = 0
        while rowStart < count {
            let rowEnd = min(count, rowStart + rowsPerBatch)
            var units: [UInt16] = []
            units.reserveCapacity((rowEnd - rowStart) * count * 3)
            for ri in rowStart..<rowEnd {
                let a = ascii[ri]
                for b in ascii {
                    units.append(a)
                    units.append(b)
                    units.append(0xFFFC)
                }
            }
            let str = String(utf16CodeUnits: units, count: units.count)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: str, attributes: [Self.fontKey: font]))
            var unitAdv = [Double](repeating: 0, count: units.count)
            for run in (CTLineGetGlyphRuns(line) as? [CTRun] ?? []) {
                let gc = CTRunGetGlyphCount(run)
                guard gc > 0 else { continue }
                var ra = [CGSize](repeating: .zero, count: gc)
                var ridx = [CFIndex](repeating: 0, count: gc)
                CTRunGetAdvances(run, CFRange(), &ra)
                CTRunGetStringIndices(run, CFRange(), &ridx)
                for m in 0..<gc { unitAdv[ridx[m]] += Double(ra[m].width) }
            }
            var off = 0
            for ri in rowStart..<rowEnd {
                let a = Int(ascii[ri])
                for b in ascii {
                    let bi = Int(b)
                    let k = Float((unitAdv[off] + unitAdv[off + 1]) - Double(widths[a]) - Double(widths[bi]))
                    if abs(k) > 1e-5 {
                        kern[a * 128 + bi] = k
                        anyKern = true
                    }
                    off += 3
                }
            }
            rowStart = rowEnd
        }
        self.asciiKern = kern
        self.hasASCIIKerning = anyKern

        // Detect 3-char contextual ASCII characters (using CTRunGetPositions +
        // CTRunGetTypographicBounds so GPOS/calt adjustments like SF Pro's
        // digit-colon are detected reliably).
        var contextual: Set<UInt16> = []
        let contexts: [(UInt16, UInt16)] = [(0x31, 0x32), (0x30, 0x30), (0x41, 0x41), (0x61, 0x61), (0x66, 0x69)]
        var probeUnits: [UInt16] = []
        probeUnits.reserveCapacity(contexts.count * count * 4)
        var probeMeta: [(UInt16, UInt16, UInt16)] = []
        probeMeta.reserveCapacity(contexts.count * count)
        for (l, r) in contexts {
            for c in ascii {
                probeUnits.append(l)
                probeUnits.append(c)
                probeUnits.append(r)
                probeUnits.append(0xFFFC)
                probeMeta.append((l, c, r))
            }
        }
        let probeStr = String(utf16CodeUnits: probeUnits, count: probeUnits.count)
        let probeLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: probeStr, attributes: [Self.fontKey: font]))
        var probeAdv = [Double](repeating: 0, count: probeUnits.count)
        for run in (CTLineGetGlyphRuns(probeLine) as? [CTRun] ?? []) {
            let gc = CTRunGetGlyphCount(run)
            guard gc > 0 else { continue }
            var pos = [CGPoint](repeating: .zero, count: gc)
            var ridx = [CFIndex](repeating: 0, count: gc)
            CTRunGetPositions(run, CFRange(), &pos)
            CTRunGetStringIndices(run, CFRange(), &ridx)
            let rw = CTRunGetTypographicBounds(run, CFRange(), nil, nil, nil)
            let right = Double(pos[0].x) + rw
            for m in 0..<gc {
                probeAdv[ridx[m]] += (m + 1 < gc) ? Double(pos[m + 1].x - pos[m].x) : (right - Double(pos[m].x))
            }
        }
        for (idx, (l, c, r)) in probeMeta.enumerated() {
            let off = idx * 4
            let actual = probeAdv[off] + probeAdv[off + 1] + probeAdv[off + 2]
            let predicted =
                Double(widths[Int(l)]) + Double(widths[Int(c)]) + Double(widths[Int(r)])
                + Double(kern[Int(l) * 128 + Int(c)]) + Double(kern[Int(c) * 128 + Int(r)])
            if abs(actual - predicted) > 0.005 {
                contextual.insert(c)
            }
        }
        self.contextualASCIIChars = contextual
        let ligProbe = "fi fl ff ffi ffl"
        let ligLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: ligProbe, attributes: [Self.fontKey: font]))
        self.hasASCIILigatures = CTLineGetGlyphCount(ligLine) != ligProbe.utf16.count
    }

    /// Lazily measures one non-ASCII composed character cluster and its
    /// fallback-font vertical metrics (`REDESIGN.md §3`: 0 wrong heights over
    /// 8,278 multilingual lines).
    func nonASCIICluster(_ s: String) -> (width: Float, metrics: LineFontMetrics) {
        if let hit = nonASCII.withLock({ $0.clusters[s] }) {
            return hit
        }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: s, attributes: [Self.fontKey: font]))
        let w = Float(CTLineGetTypographicBounds(line, nil, nil, nil))
        var m = LineFontMetrics.zero
        for run in (CTLineGetGlyphRuns(line) as? [CTRun] ?? []) {
            var a: CGFloat = 0
            var d: CGFloat = 0
            var l: CGFloat = 0
            _ = CTRunGetTypographicBounds(run, CFRange(), &a, &d, &l)
            m.formMax(LineFontMetrics(ascent: Float(a), descent: Float(d), leading: Float(l)))
        }
        let value = (w, m)
        nonASCII.withLock { $0.clusters[s] = value }
        return value
    }

    /// Fast single-BMP-unit cluster lookup using a caller-owned local table so
    /// hot Cyrillic/CJK/Greek loops avoid per-character `Mutex` and `String`
    /// allocations.
    func bmpCluster(
        _ u: UInt16, local: inout [UInt16: (width: Float, metrics: LineFontMetrics)]
    ) -> (width: Float, metrics: LineFontMetrics) {
        if let hit = local[u] { return hit }
        if let hit = nonASCII.withLock({ $0.bmpClusters[u] }) {
            local[u] = hit
            return hit
        }
        let s = String(utf16CodeUnits: [u], count: 1)
        let value = nonASCIICluster(s)
        nonASCII.withLock { $0.bmpClusters[u] = value }
        local[u] = value
        return value
    }

    /// Fast BMP pair-kerning lookup keyed by `(a << 16) | b` with a
    /// caller-owned local cache (zero `String` or `Mutex` overhead on hits).
    func bmpPairKern(
        _ a: UInt16, _ b: UInt16, widthA: Float, widthB: Float, local: inout [UInt32: Float]
    ) -> Float {
        let key = (UInt32(a) << 16) | UInt32(b)
        if let hit = local[key] { return hit }
        if let hit = nonASCII.withLock({ $0.bmpPairKern[key] }) {
            local[key] = hit
            return hit
        }
        let s = String(utf16CodeUnits: [a, b], count: 2)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: s, attributes: [Self.fontKey: font]))
        let w = Float(CTLineGetTypographicBounds(line, nil, nil, nil))
        let k = w - widthA - widthB
        nonASCII.withLock { $0.bmpPairKern[key] = k }
        local[key] = k
        return k
    }

    /// Lazily measures kerning adjustment between two adjacent clusters where
    /// at least one is non-ASCII.
    func nonASCIIPairKern(_ a: String, _ b: String, widthA: Float, widthB: Float) -> Float {
        let key = a + "\u{0}" + b
        if let hit = nonASCII.withLock({ $0.pairKern[key] }) {
            return hit
        }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: a + b, attributes: [Self.fontKey: font]))
        let w = Float(CTLineGetTypographicBounds(line, nil, nil, nil))
        let k = w - widthA - widthB
        nonASCII.withLock { $0.pairKern[key] = k }
        return k
    }

    @inline(__always)
    static func nextTabX(after x: CGFloat, tabInterval: CGFloat, fallbackAdvance: CGFloat) -> CGFloat {
        guard tabInterval > 0 else { return x + fallbackAdvance }
        return (floor((x + 0.001) / tabInterval) + 1) * tabInterval
    }

    /// Core Text's exact tab-stop advancement for wrapped lines: custom
    /// `tabInterval` repeats indefinitely; default paragraph style has 12
    /// stops 28 pt apart (`28...336 pt`) and 0 advance past 336 pt.
    @inline(__always)
    static func coreTextTabStop(after x: Double, tabInterval: CGFloat) -> Double {
        if tabInterval > 0 {
            let interval = Double(tabInterval)
            return (floor((x + 0.001) / interval) + 1) * interval
        }
        guard x < 336.0 - 1e-4 else { return x }
        return (floor((x + 1e-4) / 28.0) + 1) * 28.0
    }

    /// Unicode space separators + TAB that `CTLineGetTrailingWhitespaceWidth`
    /// excludes from visible line width.
    @inline(__always)
    static func isTrailingWhitespace(_ u: UInt16) -> Bool {
        u == 0x20 || u == 0x09 || u == 0xA0 || u == 0x1680
            || (u >= 0x2000 && u <= 0x200A)
            || u == 0x202F || u == 0x205F || u == 0x3000
    }

    /// Breakable whitespace (all `isTrailingWhitespace` except non-breaking
    /// `U+00A0` NBSP and `U+202F` NNBSP) where Core Text's space-overflow
    /// shortcut breaks immediately.
    @inline(__always)
    static func isBreakableWhitespace(_ u: UInt16) -> Bool {
        isTrailingWhitespace(u) && u != 0xA0 && u != 0x202F
    }

    /// Zero-width format/control code units that Core Text ignores when
    /// scanning backward for trailing whitespace (e.g. `" \u{00AD}"`, `"\t\u{2060}"`).
    @inline(__always)
    static func isTrailingIgnorable(_ u: UInt16) -> Bool {
        u == 0x00AD || (u >= 0x200B && u <= 0x200F) || (u >= 0x2060 && u <= 0x206F) || u == 0xFEFF
            || (u < 0x20 && u != 0x09) || (u >= 0x7F && u <= 0x9F)
    }

    /// Whether a Unicode scalar belongs to a script or control class whose
    /// widths depend on surrounding context (Arabic, Hebrew, Indic, SEA/Thai,
    /// Hangul Jamo, Mongolian, combining marks, BiDi/format/C1 controls,
    /// joiners/variation selectors, tag sequences) and must therefore use
    /// in-context Core Text shaping (`REDESIGN.md §3–4`).
    @inline(__always)
    static func scalarNeedsInContextShaping(_ v: UInt32) -> Bool {
        if v >= 0x0080 && v <= 0x009F { return true }
        if v < 0x0300 { return false }
        if v <= 0x036F { return true }
        if v >= 0x0590 && v <= 0x109F { return true }
        if v >= 0x1100 && v <= 0x11FF { return true }
        if v >= 0x1700 && v <= 0x1AFF { return true }
        if v >= 0x1DC0 && v <= 0x1DFF { return true }
        if v >= 0x200B && v <= 0x206F { return true }
        if v >= 0x20D0 && v <= 0x20FF { return true }
        if v >= 0xA800 && v <= 0xABFF { return true }
        if v >= 0xFB1D && v <= 0xFDFF { return true }
        if v >= 0xFE00 && v <= 0xFEFF { return true }
        if v >= 0xE0000 && v <= 0xE007F { return true }
        return false
    }
}
