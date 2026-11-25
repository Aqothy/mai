import CoreGraphics
import Foundation
import Testing

@testable import mai

/// Selection as a text editor tests it: random transcripts of prose, code,
/// tables, user messages, thoughts and chrome, some rows laid out and some
/// not, and random selections, hit tests and word and character ranges,
/// each checked against a model of the transcript as one string.
@MainActor
@Suite(.serialized)
struct TranscriptSelectionFuzzTests {
    private let style = TextStyle.current()

    private func text(_ rng: inout FuzzRNG, _ length: Int, tokens: [String]) -> String {
        TranscriptFuzz.adversarialText(&rng, utf16Length: rng.int(in: 1..<length), newlines: rng.chance(30), tokens: tokens)
    }

    private func randomRows(_ rng: inout FuzzRNG, tokens: [String]) -> [TranscriptRow] {
        func text(_ rng: inout FuzzRNG, _ length: Int) -> String { self.text(&rng, length, tokens: tokens) }
        var rows: [TranscriptRow] = []
        for index in 0..<rng.int(in: 4..<24) {
            let kind: TranscriptRowKind
            switch rng.int(in: 0..<7) {
            case 0: kind = .markdownBlock(.paragraph([MarkdownInline(text: text(&rng, 600))]), .single)
            case 1: kind = .markdownBlock(.code(language: nil, code: text(&rng, 400)), .single)
            case 2:
                let cells = (0..<rng.int(in: 1..<4)).map { _ in [MarkdownInline(text: text(&rng, 20))] }
                kind = .markdownBlock(
                    .table(MarkdownTable(alignments: cells.map { _ in .leading }, header: cells, rows: [cells, cells])),
                    .single)
            case 3: kind = .userMessage(source: text(&rng, 300))
            case 4: kind = .thought(text(&rng, 300))
            case 5: kind = .activity(summary: "Read files")
            default: kind = .markdownBlock(.heading(level: 2, [MarkdownInline(text: text(&rng, 40))]), .single)
            }
            rows.append(TranscriptRow(id: "r\(index)", kind: kind, messageID: "m\(index % 3)", role: .assistant))
        }
        return rows
    }

    @Test(arguments: 0..<4)
    func selectionsHitTestsAndRangesMatchTheTranscriptAsOneText(seed: Int) {
        checkSelections(seed: 0x5E1E_C700 &+ UInt64(seed), tokens: TranscriptFuzz.adversarialTokens)
    }

    /// The same with every kind of character a model can emit mixed in
    /// (`unicodeEdgeTokens`).
    @Test(arguments: 0..<4)
    func selectionsHoldForEveryKindOfCharacter(seed: Int) {
        checkSelections(
            seed: 0x5E1E_C800 &+ UInt64(seed), tokens: TranscriptFuzz.adversarialTokens + TranscriptFuzz.unicodeEdgeTokens)
    }

    private func checkSelections(seed: UInt64, tokens: [String]) {
        var rng = FuzzRNG(seed: seed)
        for iteration in 0..<(4 * TranscriptFuzz.scale) {
            let controller = TranscriptController(configuration: .testing)
            controller.columnWidth = CGFloat(rng.int(in: 200..<700))
            let rows = randomRows(&rng, tokens: tokens)
            controller.setRows(rows)
            // Some rows laid out, some not: offsets must agree either way.
            var heights: [String: CGFloat] = [:]
            for row in controller.rows where rng.chance(70) {
                let layout = RowLayoutBuilder.layout(controller.request(row))
                controller.storeLayout(layout)
                heights[row.id] = layout.height
                if row.kind.isSelectable {
                    #expect(
                        layout.content.selectableString == RowSelectableText.string(for: row.kind, style: style),
                        "seed \(seed) iteration \(iteration): \(row.id) text differs without its layout")
                }
            }
            controller.setHeights(heights)
            let context = "seed \(seed) iteration \(iteration)"

            // The model: selectable rows' texts joined by their separators.
            var model = ""
            var starts: [String: Int] = [:]
            var selectable: [(index: Int, text: String)] = []
            for index in controller.rows.indices {
                guard let rowText = controller.selectableText(ofRowAt: index) else { continue }
                if !selectable.isEmpty { model += controller.rows[index].separatorBefore }
                starts[controller.rows[index].id] = model.utf16.count
                model += rowText
                selectable.append((index, rowText))
            }
            guard !selectable.isEmpty else { continue }
            let modelUTF16 = Array(model.utf16)
            func global(_ position: TextPosition) -> Int { (starts[position.rowID] ?? 0) + position.offset }
            // Selections end on grapheme boundaries, as hit tests and word
            // ranges put them.
            func randomPosition() -> TextPosition {
                let pick = selectable[rng.int(in: 0..<selectable.count)]
                let boundaries = pick.text.indices.map { pick.text.utf16.distance(from: pick.text.startIndex, to: $0) }
                    + [pick.text.utf16.count]
                return TextPosition(rowID: controller.rows[pick.index].id, offset: rng.pick(boundaries))
            }

            for step in 0..<40 {
                // Copy reads the model's text between the two ends.
                let a = randomPosition()
                let b = randomPosition()
                controller.setSelection(TranscriptSelection(anchor: a, focus: b))
                let (low, high) = (min(global(a), global(b)), max(global(a), global(b)))
                let expected = String(decoding: modelUTF16[low..<high], as: UTF16.self)
                #expect(controller.selectedText() == expected, "\(context) step \(step): copy")
                // UIKit's position arithmetic walks the same text.
                #expect(controller.offset(from: a, to: b) == global(b) - global(a), "\(context) step \(step): offset")
                if let moved = controller.position(from: a, offset: global(b) - global(a)) {
                    #expect(global(moved) == global(b), "\(context) step \(step): position(from:offset:)")
                }
                // Word and character ranges cover the position and never cut
                // a grapheme cluster.
                for range in [controller.wordRange(around: a), controller.characterRange(around: a)].compactMap({ $0 }) {
                    guard let index = controller.geometry.index(for: a.rowID),
                        let rowText = controller.selectableText(ofRowAt: index)
                    else { continue }
                    let ns = rowText as NSString
                    for offset in [range.anchor.offset, range.focus.offset] where offset < ns.length {
                        #expect(
                            TextLayoutEngine.startsCluster(ns, at: offset),
                            "\(context) step \(step): range edge \(offset) inside a cluster")
                    }
                    #expect(range.anchor.offset <= max(range.focus.offset, min(a.offset, ns.length)))
                }
                // Highlights are finite and inside their rows.
                let ordered = global(a) <= global(b) ? (a, b) : (b, a)
                for rect in controller.selectionRects(from: ordered.0, to: ordered.1, columnX: 0, scrollX: { _ in 0 }) {
                    #expect(rect.minX.isFinite && rect.width.isFinite && rect.height >= 0, "\(context): rect \(rect)")
                    #expect(rect.minY >= 0 && rect.maxY <= controller.geometry.totalHeight + 1, "\(context): rect \(rect)")
                }
            }

            // A hit anywhere lands on a grapheme boundary of a laid-out row.
            for _ in 0..<60 {
                let y = CGFloat(rng.int(in: 0..<max(1, Int(controller.geometry.totalHeight))))
                let x = CGFloat(rng.int(in: -20..<Int(controller.columnWidth) + 40))
                guard let position = controller.textPosition(atDocumentPoint: CGPoint(x: x, y: y), columnX: 0),
                    let index = controller.geometry.index(for: position.rowID),
                    let rowText = controller.selectableText(ofRowAt: index)
                else { continue }
                let ns = rowText as NSString
                #expect(position.offset >= 0 && position.offset <= ns.length, "\(context): hit out of range")
                if position.offset < ns.length, !TextLayoutEngine.startsCluster(ns, at: position.offset) {
                    let cluster = ns.rangeOfComposedCharacterSequence(at: position.offset)
                    let scalars = ns.substring(with: cluster).unicodeScalars.map { String($0.value, radix: 16) }
                    Issue.record("\(context): hit at \(position.offset) inside cluster \(cluster) \(scalars) of \(position.rowID)")
                }
            }
        }
    }
}
