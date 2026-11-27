import CoreFoundation
import Foundation
import Testing

@testable import mai

/// `PreparedText.fastASCIITokenize` restates the UAX #14 rules ICU applies to
/// ASCII text so pure-ASCII paragraphs skip `CFStringTokenizer`. These
/// compare the two on the running OS, so a change to the system's line-break
/// rules fails here instead of silently moving where lines wrap.
nonisolated struct ASCIILineBreakParityTests {
    /// One character of each line-break class the tokenizer knows: LF, SP,
    /// OP, CP, CL, QU, EX, SY, IS, HY, BA, PR, PO, NU, AL.
    private static let classSamples = Array("\n ()}\"!/.-|$%1a".utf16)
    /// Every character the fast path accepts.
    private static let alphabet = [UInt16(0x0A)] + Array(UInt16(0x20)...UInt16(0x7E))

    private struct System {
        var tokenizer: CFStringTokenizer?

        mutating func breaks(_ units: [UInt16]) -> [Int] {
            let string = String(utf16CodeUnits: units, count: units.count) as CFString
            return PreparedText.tokenizeRange(
                cf: string, range: CFRange(location: 0, length: units.count), baseOffset: 0, reusable: &tokenizer)
        }
    }

    private static func mismatch(_ units: [UInt16], _ system: inout System) -> String? {
        let fast = PreparedText.fastASCIITokenize(units)
        let expected = system.breaks(units)
        guard fast != expected else { return nil }
        return "\(String(decoding: units, as: UTF16.self).debugDescription): fast \(fast), system \(expected)"
    }

    /// Every sequence of five classes (759,375, about a second): enough to
    /// reach the rules that look past a neighbor (`OP SP* ×`, `SP ÷ IS NU`,
    /// `PR × OP IS NU`, numbers). Three classes missed `$(.5` and `$(-1`.
    @Test func everyFiveClassSequenceBreaksLikeTheSystem() {
        var system = System()
        var failures: [String] = []
        let samples = Self.classSamples
        for a in samples {
            for b in samples {
                for c in samples {
                    for d in samples {
                        for e in samples {
                            if let failure = Self.mismatch([a, b, c, d, e], &system) { failures.append(failure) }
                        }
                    }
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.count) differ, first: \(failures.prefix(5))")
    }

    /// Every pair of accepted characters between letters, digits, spaces and
    /// brackets, so no character is misclassified.
    @Test func everyCharacterPairBreaksLikeTheSystem() {
        var system = System()
        var failures: [String] = []
        let contexts = Array("a1 (".utf16)
        for before in contexts {
            for x in Self.alphabet {
                for y in Self.alphabet {
                    for after in contexts {
                        if let failure = Self.mismatch([before, x, y, after], &system) { failures.append(failure) }
                    }
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.count) differ, first: \(failures.prefix(5))")
    }

    /// Long random text weighted like prose, code and numbers.
    @Test(arguments: 0..<4) func randomTextBreaksLikeTheSystem(seed: UInt64) {
        var rng = FuzzRNG(seed: 0xA5C1_1000 ^ seed)
        var system = System()
        let words = Array("abcdefghijklmnopqrstuvwxyzABCXYZ".utf16)
        let digits = Array("0123456789".utf16)
        var failures: [String] = []
        for _ in 0..<(1_000 * TranscriptFuzz.scale) {
            var units: [UInt16] = []
            for _ in 0..<rng.int(in: 1..<400) {
                switch rng.int(in: 0..<10) {
                case 0..<4: units.append(rng.pick(words))
                case 4, 5: units.append(rng.pick(digits))
                case 6: units.append(0x20)
                default: units.append(rng.pick(Self.alphabet))
                }
            }
            if let failure = Self.mismatch(units, &system) { failures.append(failure) }
        }
        #expect(failures.isEmpty, "\(failures.count) differ, first: \(failures.prefix(3))")
    }
}
