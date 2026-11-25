import CoreGraphics
import Foundation
import Testing

#if os(macOS)
    import AppKit
#endif

@testable import mai

/// Messages and blocks split into rows read and scroll as one, as a
/// browser shows one element: a split code block scrolls sideways as one
/// `<pre>`, and a split user message renders and copies as it would whole.
@MainActor
@Suite(.serialized)
struct TranscriptSplitBlockTests {
    private let style = TextStyle.current()

    private func layout(_ row: TranscriptRow, width: CGFloat = 600) -> RowLayout {
        RowLayoutBuilder.layout(
            RowLayoutRequest(
                rowID: row.id, kind: row.kind, key: RowLayoutKey(contentVersion: 0, width: width, styleVersion: style.version),
                style: style))
    }

    /// Every chunk scrolls over one width, so all are wide or none: exactly
    /// the unsplit block's when its widest line is in the code font's own
    /// glyphs (ASCII, box drawing, arrows, quotes), and not narrower when it
    /// is CJK (counted two columns an ideograph).
    @Test func chunksOfASplitCodeBlockShareItsWidth() {
        for (widest, isCodeFont) in [
            ("let wide = \"" + String(repeating: "w", count: 300) + "\"", true),
            ("│   ├── “" + String(repeating: "→", count: 40) + "” — …", true),
            (String(repeating: "漢字", count: 60), false),
        ] {
            var lines = (0..<450).map { "let value\($0) = compute(\($0))" }
            lines[420] = widest
            let code = lines.joined(separator: "\n")
            let rows = TranscriptRowChunker.assistantRows(messageID: "m", turnID: "t", blocks: [.code(language: "swift", code: code)])
            #expect(rows.count == 3)
            let whole = layout(TranscriptRow(id: "w", kind: .markdownBlock(.code(language: "swift", code: code), .single)))
            let wholeWidth = whole.content.codeLayout?.contentWidth ?? 0
            let chunks = rows.map { layout($0) }
            let widths = chunks.map { $0.content.codeLayout?.contentWidth ?? 0 }
            #expect(
                Set(widths).count == 1 && (isCodeFont ? widths[0] == wholeWidth : widths[0] >= wholeWidth),
                "chunk widths \(widths), whole \(wholeWidth)")
            #expect(chunks.allSatisfy { ($0.content.wideBody != nil) == (whole.content.wideBody != nil) }, "\(widest)")
        }
    }

    /// A split user message copies exactly as the whole message renders,
    /// wherever the cuts fall: at blank lines, inside a long fence (the
    /// continuation reopens it), inside one huge line (at a space before a
    /// letter, the space kept as the seam's separator).
    @Test(arguments: 0..<4)
    func aSplitUserMessageRendersAsTheWholeMessage(seed: Int) {
        var rng = FuzzRNG(seed: 0x05E5_0000 &+ UInt64(seed))
        for iteration in 0..<(3 * TranscriptFuzz.scale) {
            var document = TranscriptFuzz.markdownDocument(&rng, blocks: rng.int(in: 30..<90))
            switch rng.int(in: 0..<3) {
            case 0:
                document += "\n\n```swift\n" + (0..<rng.int(in: 300..<900)).map { "let v\($0) = \($0)" }.joined(separator: "\n") + "\n```"
            case 1:
                document += "\n\n" + (0..<4_000).map { ["alpha", "beta", "**gamma**", "café", "- dash", "1. one"][$0 % 6] }
                    .joined(separator: " ")
            default:
                break
            }
            let rows = TranscriptRowChunker.userRows(messageID: "m", turnID: "t", source: document)
            guard rows.count > 1 else { continue }
            var rendered = ""
            for (index, row) in rows.enumerated() {
                if index > 0 { rendered += row.separatorBefore }
                rendered += RowSelectableText.string(for: row.kind, style: style) ?? ""
            }
            let whole = RowSelectableText.string(for: .userMessage(source: document), style: style) ?? ""
            #expect(rendered == whole, "seed \(seed) iteration \(iteration): \(rows.count) rows render differently")
        }
    }

    #if os(macOS)
        /// Scrolling one chunk of a split code block sideways scrolls the
        /// others; a chunk mounted again comes back to where the block was
        /// left, as a browser keeps `scrollLeft`. One scrollbar, under the
        /// last chunk.
        @Test func chunksOfASplitCodeBlockScrollSidewaysTogether() {
            let controller = TranscriptController(configuration: .testing)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 600))
            scroll.automaticallyAdjustsContentInsets = false
            let document = TranscriptDocumentView(controller: controller)
            scroll.documentView = document
            let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            defer {
                window.contentView = nil
                window.close()
            }
            // Lines of 10 KB: three per 32 KB chunk, four chunks on screen.
            let code = (0..<12).map { "line \($0) " + String(repeating: "x", count: 10_000) }.joined(separator: "\n")
            let rows = TranscriptRowChunker.assistantRows(messageID: "m", turnID: "t", blocks: [.code(language: nil, code: code)])
            #expect(rows.count == 4)
            controller.setRows(rows)
            let layouts = rows.map { RowLayoutBuilder.layout(controller.request($0)) }
            for layout in layouts { controller.storeLayout(layout) }
            controller.setHeights(Dictionary(uniqueKeysWithValues: layouts.map { ($0.rowID, $0.height) }))
            controller.alignInitialEndIfPossible()
            document.layoutSubtreeIfNeeded()
            let scrollers = rows.compactMap { document.wideBlocks[$0.id] }
            #expect(scrollers.count == 4)
            #expect(scrollers.map(\.hasHorizontalScroller) == [false, false, false, true])

            // The reader scrolls the second chunk.
            scrollers[1].contentView.scroll(to: NSPoint(x: 700, y: 0))
            #expect(scrollers.allSatisfy { $0.scrollX == 700 })
            #expect(controller.wideBlockOffsets[rows[0].id] == 700)

            // Unmounted and mounted again, a chunk starts where the block is.
            let body = layouts[2].content.wideBody
            document.removeWideBlock(rowID: rows[2].id)
            if let body {
                document.showWideBlock(
                    rowID: rows[2].id, group: controller.wideBlockGroup(forRowAt: 2), body: body, key: layouts[2].key,
                    origin: .zero, drawn: .null, visible: .null, streamed: nil)
            }
            #expect(document.wideBlocks[rows[2].id]?.scrollX == 700)
        }
    #endif
}
