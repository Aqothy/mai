import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import mai

/// One layout serves measuring, drawing, hit testing and selection (PLAN 3.1
/// rule 8): lines break at the width, paragraphs keep the chat's spacing and
/// indents, carets and decorations line up with the glyphs.
@MainActor
struct TextLayoutEngineTests {
    private let style = TextStyle.current()

    private func layout(_ blocks: [MarkdownBlock], width: CGFloat) -> TextLayout {
        RowLayoutBuilder.prose(blocks, width: width, style: style)
    }

    @Test func linesBreakWithinTheWidthAndCoverTheText() {
        let words = Array(repeating: "transcript", count: 60).joined(separator: " ")
        let text = layout([.paragraph([MarkdownInline(text: words)])], width: 300)
        #expect(text.lines.count > 3)
        #expect(text.lines.allSatisfy { $0.x + $0.width <= 300.5 })
        #expect(text.lines.first?.range.lowerBound == 0)
        #expect(text.lines.last?.range.upperBound == words.utf16.count)
        for (above, below) in zip(text.lines, text.lines.dropFirst()) {
            #expect(above.range.upperBound == below.range.lowerBound)
            #expect(below.top >= above.bottom)
        }
        #expect(text.size.height == ceil(text.lines.last?.bottom ?? 0))
    }

    @Test func blocksAreSeparatedByTheBlockSpacing() {
        let one = layout([.paragraph([MarkdownInline(text: "One")])], width: 400)
        let two = layout(
            [.paragraph([MarkdownInline(text: "One")]), .paragraph([MarkdownInline(text: "Two")])], width: 400)
        let lineHeight = one.lines[0].height
        #expect(two.lines.count == 2)
        #expect(two.lines[1].top == lineHeight + style.lineSpacing + style.blockSpacing)
    }

    @Test func listItemsHangTheirTextAfterTheMarker() {
        let item = Array(repeating: "wrapping", count: 30).joined(separator: " ")
        let list = layout(
            [.list(MarkdownList(startIndex: nil, items: [MarkdownList.Item(blocks: [.paragraph([MarkdownInline(text: item)])])]))],
            width: 300)
        #expect(list.lines.count > 1)
        #expect(list.lines[0].x == 0)
        #expect(list.lines.dropFirst().allSatisfy { $0.x == style.listIndent })
        #expect(list.string.hasPrefix("•  "))
    }

    @Test func taskListItemsEmitCheckboxDecorationsAndIndentFirstLine() {
        let blocks = MarkdownPlanner.blocks(from: "- [ ] First task\n- [x] Second task\n")
        let rendered = layout(blocks, width: 300)
        #expect(rendered.decorations.map(\.kind) == [.taskUnchecked, .taskChecked])
        #expect(rendered.lines.count == 2)
        #expect(rendered.lines.allSatisfy { $0.x == style.listIndent })
        #expect(rendered.string == "First task\nSecond task")
    }

    @Test func caretsRunLeftToRightAcrossEachLine() {
        let text = layout([.paragraph([MarkdownInline(text: "Carets café 👩🏽‍💻 end")])], width: 1_000)
        let line = text.lines[0]
        #expect(line.caretOffsets.count == line.range.count + 1)
        #expect(zip(line.caretOffsets, line.caretOffsets.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(abs((line.caretOffsets.last ?? 0) - (line.x + line.width)) < 1)
    }

    /// Carets from glyph positions match Core Text's at every character
    /// boundary, and stay at a cluster's start inside it.
    @Test(arguments: [
        "Plain ASCII text, with punctuation; and (brackets) 123.",
        "café naïve résumé and cafe\u{301} decomposed",
        "Emoji 👩🏽‍💻 🎉 and flags 🇨🇦 in a line",
        "漢字かな交じり文 with Latin",
        "office fifty flow affix ffl",
        "func consume(ctx context.Context) -> Int { 42 }",
    ])
    func glyphCaretsMatchCoreText(text: String) {
        for font in [style.font(.body).font, style.font(.code).font] {
            let attributed = NSAttributedString(
                string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let line = CTLineCreateWithAttributedString(attributed)
            let range = 0..<attributed.length
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let glyphs = TextLayoutEngine.caretOffsets(
                of: line, range: range, string: attributed.string as NSString, indent: 4, width: width)
            let system = TextLayoutEngine.enumeratedCaretOffsets(of: line, range: range, indent: 4, width: width)
            #expect(glyphs.count == system.count)
            #expect(zip(glyphs, glyphs.dropFirst()).allSatisfy { $0 <= $1 })
            var boundary = 0
            for character in text {
                #expect(abs(glyphs[boundary] - system[boundary]) < 0.5, "\(text) at \(boundary)")
                let next = boundary + character.utf16.count
                for inside in (boundary + 1)..<max(boundary + 1, next) {
                    #expect(glyphs[inside] == glyphs[boundary], "inside a cluster of \(text) at \(inside)")
                }
                boundary = next
            }
            #expect(abs(glyphs[boundary] - system[boundary]) < 0.5)
        }
    }

    @Test func inlineCodeLinksAndStrikethroughGetDecorations() {
        let text = layout(
            [
                .paragraph([
                    MarkdownInline(text: "Run "), MarkdownInline(text: "make", style: .code),
                    MarkdownInline(text: " or "),
                    MarkdownInline(text: "read", link: URL(string: "https://example.com")),
                    MarkdownInline(text: " not", style: .strikethrough),
                ])
            ], width: 1_000)
        let kinds = text.decorations.map(\.kind)
        #expect(kinds.contains(.inlineCodeBackground))
        #expect(kinds.contains(.underline))
        #expect(kinds.contains(.strikethrough))
        #expect(text.links.first == URL(string: "https://example.com"))
        #expect(text.runs.contains { $0.linkIndex == 0 })
    }

    @Test func codeKeepsLinesUnwrappedWithAnAnalyticHeight() {
        let code = "let a = 1\n" + String(repeating: "x", count: 400) + "\nend"
        let block = CodeLayout.make(code: code, language: "swift", colors: nil, width: 300, style: style)
        #expect(block.body.lines.count == 3)
        #expect(block.isWiderThanBlock)
        #expect(block.size.height == ceil(style.codeHeaderHeight + 3 * style.codeLineHeight + style.codeBottomInset))
        #expect(CodeLayout.displayName("py") == "Python")
    }

    @Test func tablesSizeColumnsWithinTheirLimits() {
        let table = MarkdownTable(
            alignments: [.leading, .trailing],
            header: [[MarkdownInline(text: "Name")], [MarkdownInline(text: "Value")]],
            rows: [[[MarkdownInline(text: "a")], [MarkdownInline(text: "1")]]])
        let layout = TableLayout.make(table, width: 760, style: style)
        #expect(layout.cells.count == 4)
        #expect(layout.dividers.count == 1)
        #expect(layout.gridSize.width >= 2 * style.tableMinimumColumnWidth + style.tableColumnSpacing)
        #expect(TableLayout.tabSeparatedText(table) == "Name\tValue\na\t1")
    }

    /// A CRLF code block is as tall as its lines: "\r\n" is one Character,
    /// so counting Characters saw one line and clipped the rest.
    @Test func crlfCodeHasOneLinePerLine() {
        let crlf = CodeLayout.make(code: "a\r\nb\r\nc", language: nil, colors: nil, width: 400, style: style)
        let lf = CodeLayout.make(code: "a\nb\nc", language: nil, colors: nil, width: 400, style: style)
        #expect(crlf.size.height == lf.size.height)
    }

    /// A list's bullet follows how deep in lists it is: two quotes indent as
    /// much as a list, and used to make a top-level list's bullet `◦`.
    @Test func aListInQuotesStartsAtTheFirstBullet() {
        let list = MarkdownBlock.list(
            MarkdownList(startIndex: nil, items: [MarkdownList.Item(blocks: [.paragraph([MarkdownInline(text: "a")])])]))
        let text = AttributedTextBuilder.build([.quote([.quote([list])])], style: style)
        #expect(text.string.string.hasPrefix("•"))
    }

    /// An item that starts with code or a nested list still shows its marker.
    @Test func aListItemStartingWithABlockKeepsItsMarker() {
        let code = AttributedTextBuilder.build(
            [.list(MarkdownList(startIndex: nil, items: [MarkdownList.Item(blocks: [.code(language: nil, code: "make")])]))],
            style: style)
        #expect(code.string.string.hasPrefix("•"))
        #expect(code.string.string.hasSuffix("make"))
        let numbered = AttributedTextBuilder.build(
            [.list(MarkdownList(startIndex: 3, items: [MarkdownList.Item(blocks: [.code(language: nil, code: "make")])]))],
            style: style)
        #expect(numbered.string.string.hasPrefix("3."))
    }

    /// The newline ending a paragraph is in that paragraph's font: in the
    /// body font, the last line of code in a quote was taller than the rest.
    @Test func aParagraphBreakDoesNotRaiseTheLineItEnds() {
        let layout = layout(
            [.quote([.code(language: nil, code: "a\nb"), .paragraph([MarkdownInline(text: "x")])])], width: 500)
        #expect(layout.lines.count == 3)
        #expect(layout.lines[0].height == layout.lines[1].height)
    }

    /// A table's last column's cells end at the grid: their boxes (hit
    /// testing, selection) reached half a column spacing past it.
    @Test func theLastColumnsBoxesEndAtTheGrid() {
        for columns in 1...3 {
            let cell = [MarkdownInline(text: "x")]
            let table = MarkdownTable(
                alignments: Array(repeating: .leading, count: columns), header: Array(repeating: cell, count: columns),
                rows: [Array(repeating: cell, count: columns)])
            let layout = TableLayout.make(table, width: 400, style: style)
            let last = layout.cells.filter { $0.column == columns - 1 }
            #expect(last.allSatisfy { abs($0.box.maxX - layout.gridSize.width) < 1 }, "\(columns) columns")
        }
    }

    /// Core Text reorders a Devanagari vowel sign before its consonant, so
    /// glyph order is not text order there: those lines take Core Text's
    /// carets, and a trailing edge never lands inside an emoji's pair.
    @Test func reorderedAndRightToLeftLinesTakeCoreTextsCarets() {
        for text in ["हिन्दी किताब", "שלום 👋 עולם"] {
            let attributed = NSAttributedString(
                string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): style.font(.body).font])
            let line = CTLineCreateWithAttributedString(attributed)
            let range = 0..<attributed.length
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let string = attributed.string as NSString
            let carets = TextLayoutEngine.caretOffsets(of: line, range: range, string: string, indent: 0, width: width)
            #expect(
                carets == TextLayoutEngine.enumeratedCaretOffsets(
                    of: line, range: range, string: string, indent: 0, width: width))
            let emoji = string.range(of: "👋")
            if emoji.location != NSNotFound { #expect(carets[emoji.location + 1] == carets[emoji.location]) }
        }
    }

    /// Incremental streaming layouts for prose, code and tables match one-shot
    /// layout bit-for-bit.
    @Test func incrementalLayoutsMatchFullLayout() {
        // 1. Prose paragraph growth.
        let words = ["stream", "layout", "**bold**", "`code`", "café", "👩🏽‍💻", "text", "frame"]
        let part1 = (0..<80).map { words[$0 % words.count] }.joined(separator: " ")
        let part2 = part1 + " " + (0..<40).map { words[$0 % words.count] }.joined(separator: " ")
        let block1 = MarkdownPlanner.blocks(from: part1)[0]
        let block2 = MarkdownPlanner.blocks(from: part2)[0]
        let kind1 = TranscriptRowKind.markdownBlock(block1, .init(isFirst: true, isLast: true))
        let kind2 = TranscriptRowKind.markdownBlock(block2, .init(isFirst: true, isLast: true))
        let key = RowLayoutKey(contentVersion: 0, width: 420, styleVersion: style.version)
        let first = RowLayoutBuilder.layout(RowLayoutRequest(rowID: "p", kind: kind1, key: key, style: style))
        var incReq = RowLayoutRequest(rowID: "p", kind: kind2, key: key, style: style)
        incReq.previous = (kind1, first)
        let incremental = RowLayoutBuilder.layout(incReq)
        let full = RowLayoutBuilder.layout(RowLayoutRequest(rowID: "p", kind: kind2, key: key, style: style))
        #expect(incremental.height == full.height)
        if case .text(let a, _) = incremental.content, case .text(let b, _) = full.content {
            #expect(a.size == b.size)
            #expect(a.lines.count == b.lines.count)
            #expect(RowContentDiff.unchangedHeight(a, b) == .infinity)
        } else {
            Issue.record("expected text layouts")
        }

        // 2. Code fence growth (including CRLF).
        let code1 = "line 0\r\nline 1\r\nline 2\r\nline 3\r\nline 4"
        let code2 = code1 + "\r\nline 5\r\nline 6"
        let c1 = CodeLayout.make(code: code1, language: "go", colors: nil, width: 400, style: style)
        let c2Inc = CodeLayout.make(code: code2, language: "go", colors: nil, width: 400, style: style, previous: c1)
        let c2Full = CodeLayout.make(code: code2, language: "go", colors: nil, width: 400, style: style)
        #expect(c2Inc.size == c2Full.size)
        #expect(c2Inc.body.lines.count == 7)
        #expect(RowContentDiff.unchangedHeight(c2Inc.body, c2Full.body) == .infinity)

        // 3. Table growth.
        let t1 = MarkdownTable(
            alignments: [.leading, .trailing],
            header: [[MarkdownInline(text: "A")], [MarkdownInline(text: "B")]],
            rows: (0..<10).map { [[MarkdownInline(text: "row\($0)")], [MarkdownInline(text: "\($0)")]] })
        let t2 = MarkdownTable(
            alignments: t1.alignments, header: t1.header,
            rows: t1.rows + [[[MarkdownInline(text: "row10")], [MarkdownInline(text: "10")]]])
        let tl1 = TableLayout.make(t1, width: 500, style: style)
        let tl2Inc = TableLayout.make(t2, width: 500, style: style, previous: tl1)
        let tl2Full = TableLayout.make(t2, width: 500, style: style)
        #expect(tl2Inc.size == tl2Full.size)
        #expect(RowContentDiff.unchangedHeight(.tableBody(tl2Inc), .tableBody(tl2Full)) == .infinity)
    }

    /// Incremental suffix layout must not duplicate URLs in `links` or leave
    /// stale decorations when a paragraph with links grows over many updates.
    @Test func incrementalParagraphSuffixDoesNotLeakLinksOrDecorations() throws {
        let url = try #require(URL(string: "https://example.com"))
        let baseInlines = [
            MarkdownInline(text: "Line one of text that definitely wraps across multiple lines in a narrow column here. "),
            MarkdownInline(text: "Line two of text that also wraps cleanly across the column width so keepCount is two. "),
            MarkdownInline(text: "Check "),
            MarkdownInline(text: "link", style: [], link: url),
            MarkdownInline(text: " and "),
            MarkdownInline(text: "code", style: .code),
            MarkdownInline(text: " now"),
        ]
        let pos = TranscriptBlockPosition(isFirst: true, isLast: true)
        let key = RowLayoutKey(contentVersion: 0, width: 300, styleVersion: style.version)
        var currentInlines = baseInlines
        var prevKind = TranscriptRowKind.markdownBlock(.paragraph(currentInlines), pos)
        var prevLayout = RowLayoutBuilder.layout(RowLayoutRequest(rowID: "p", kind: prevKind, key: key, style: style))

        for step in 0..<10 {
            currentInlines[currentInlines.count - 1].text += " w\(step)"
            let nextKind = TranscriptRowKind.markdownBlock(.paragraph(currentInlines), pos)
            var req = RowLayoutRequest(rowID: "p", kind: nextKind, key: key, style: style)
            req.previous = (prevKind, prevLayout)
            prevLayout = RowLayoutBuilder.layout(req)
            prevKind = nextKind
        }

        let full = RowLayoutBuilder.layout(RowLayoutRequest(rowID: "p", kind: prevKind, key: key, style: style))
        if case .text(let incText, _) = prevLayout.content, case .text(let fullText, _) = full.content {
            #expect(incText.links == [url])
            #expect(incText.links == fullText.links)
            #expect(incText.decorations.count == fullText.decorations.count)
            #expect(RowContentDiff.unchangedHeight(incText, fullText) == .infinity)
        } else {
            Issue.record("expected text layouts")
        }
    }

    /// Tabs in code stop every 4 columns, on the code font's grid, so
    /// tab-indented code lines up with space-indented code, in a code block
    /// (streamed or whole) and in one nested in a list.
    @Test func codeTabsStopEveryFourColumns() {
        let column = style.codeColumnWidth
        let code = "\tx\n    x\nab\tx\nabcd\tx\nabcde\t\tx\nlast"
        let whole = CodeLayout.make(code: code, language: nil, colors: nil, width: 600, style: style)
        let streamed = CodeLayout.make(
            code: code + " line", language: nil, colors: nil, width: 600, style: style, previous: whole)
        let nested = layout(
            [.list(MarkdownList(startIndex: nil, items: [MarkdownList.Item(blocks: [.code(language: nil, code: code)])]))],
            width: 600)
        let nestedStart = (nested.string as NSString).range(of: "\tx").location
        for (name, body, start) in [("whole", whole.body, 0), ("streamed", streamed.body, 0), ("nested", nested, nestedStart)] {
            let lines = body.lines.filter { $0.range.lowerBound >= start }
            // The caret before each line's `x`, from the line's first caret.
            func xCaret(_ line: TextLine) -> CGFloat {
                let offset = ((body.string as NSString).range(of: "x", range: NSRange(line.range)).location) - line.range.lowerBound
                return line.caretOffsets[offset] - line.caretOffsets[0]
            }
            let expected: [CGFloat] = [4, 4, 4, 8, 12].map { $0 * column }
            let actual = lines.prefix(5).map(xCaret)
            #expect(zip(actual, expected).allSatisfy { abs($0 - $1) < 0.01 }, "\(name): \(actual) vs \(expected)")
        }
    }

    /// Reordered and BiDi lines place their end-of-cluster carets at the
    /// cluster's full visual edge, not at a mid-cluster Core Text sub-caret
    /// (Myanmar syllables like "ကျွန်တော်"/"မြန်မာ", and ZWJ before a letter).
    @Test func reorderedEndOfLineCaretsCoverTheFullLine() {
        for sample in ["ကျွန်တော်", "မြန်မာ", "မြန်မာ\u{200D}a"] {
            let laid = layout([.paragraph([MarkdownInline(text: sample)])], width: 400)
            guard let line = laid.lines.first else {
                Issue.record("expected line for \(sample)")
                continue
            }
            #expect(
                abs((line.caretOffsets.last ?? 0) - (line.x + line.width)) < 0.5,
                "\(sample): end caret \(line.caretOffsets.last ?? -1) vs width \(line.width)")
            let rects = laid.selectionRects(for: line.range)
            #expect(rects.count == 1 && abs(rects[0].width - line.width) < 0.5, "\(sample): rect \(rects) vs width \(line.width)")
        }
        // In "مرحبا a\u{200D}b", 'b' must keep a non-zero caret span after the ZWJ.
        let mixed = "مرحبا a\u{200D}b"
        let laidMixed = layout([.paragraph([MarkdownInline(text: mixed)])], width: 400)
        guard let line = laidMixed.lines.first else {
            Issue.record("expected line for mixed BiDi")
            return
        }
        let bStart = (mixed as NSString).range(of: "b").location
        let span = abs(line.caretOffsets[bStart + 1] - line.caretOffsets[bStart])
        #expect(span > 1, "expected non-zero caret span for 'b', got \(span)")
    }

    /// Tight lists separate items by `listItemSpacing` (8 pt); loose lists
    /// (blank line between items or inside a multi-block item) use
    /// `blockSpacing` (16 pt), matching browsers and CommonMark §5.3.
    @Test func tightAndLooseListsDifferInItemSpacing() {
        let tightBlocks = MarkdownPlanner.blocks(from: "- Alpha\n- Beta\n")
        let looseBlocks = MarkdownPlanner.blocks(from: "- Alpha\n\n- Beta\n")
        guard case .list(let tight) = tightBlocks.first, case .list(let loose) = looseBlocks.first else {
            Issue.record("expected list blocks")
            return
        }
        #expect(tight.isTight)
        #expect(!loose.isTight)

        let tightLayout = layout(tightBlocks, width: 400)
        let looseLayout = layout(looseBlocks, width: 400)
        let delta = looseLayout.size.height - tightLayout.size.height
        let expected = style.blockSpacing - style.listItemSpacing
        #expect(abs(delta - expected) < 0.5, "expected loose list taller by \(expected), got \(delta)")
    }

    /// Selecting across an LTR/RTL boundary on one line produces disjoint
    /// per-run highlight rects instead of one spanning rect over unselected
    /// glyphs in between.
    @Test func mixedBiDiSelectionProducesDisjointRectsPerRun() {
        let text = "hello שלום world"
        let laid = layout([.paragraph([MarkdownInline(text: text)])], width: 400)
        // Select "lo של" (UTF-16 offsets 3..<8): covers the end of "hello"
        // (left side) and the visual right half of "שלום" (right of "ום"),
        // leaving "ום" unselected between them.
        let rects = laid.selectionRects(for: 3..<8)
        #expect(rects.count == 2, "expected 2 disjoint BiDi selection rects, got \(rects)")
        if rects.count == 2 {
            let ordered = rects.sorted { $0.minX < $1.minX }
            #expect(ordered[1].minX > ordered[0].maxX + 1, "expected unselected gap between BiDi runs: \(ordered)")
        }
    }

    /// Hit-testing in the vertical gap between two lines snaps to the closer
    /// line at the exact vertical midpoint (YYText rule).
    @Test func lineGapHitTestingSnapsAtVerticalMidpoint() {
        let laid = layout(
            [.paragraph([MarkdownInline(text: "First")]), .paragraph([MarkdownInline(text: "Second")])],
            width: 400)
        #expect(laid.lines.count == 2)
        let gapTop = laid.lines[0].bottom
        let gapBottom = laid.lines[1].top
        #expect(gapBottom - gapTop >= 10)
        let midpoint = (gapTop + gapBottom) / 2
        #expect(laid.lineIndex(nearestY: midpoint - 0.5) == 0)
        #expect(laid.lineIndex(nearestY: midpoint + 0.5) == 1)
    }

    /// A pure-LTR line in a multi-line layout that contains RTL on another line
    /// must still highlight its exact LTR substring (not drop runs or invert
    /// using zero `visualWidth`).
    @Test func ltrLineSelectionWorksWhenAnotherLineContainsRTL() {
        let laid = layout(
            [
                .paragraph([MarkdownInline(text: "Hello "), MarkdownInline(text: "world", style: .strong)]),
                .paragraph([MarkdownInline(text: "שלום")]),
            ],
            width: 400)
        #expect(laid.hasComplexBiDi)
        #expect(!laid.lines[0].hasComplexBiDi)
        #expect(laid.lines[1].hasComplexBiDi)

        // Select "lo " (3..<6) on line 0: must lie strictly to the right of "Hel".
        let partial = laid.selectionRects(for: 3..<6)
        #expect(partial.count == 1)
        if let rect = partial.first {
            #expect(abs(rect.minX - laid.lines[0].caretOffsets[3]) < 0.5)
            #expect(abs(rect.maxX - laid.lines[0].caretOffsets[6]) < 0.5)
        }
        // Select "Hello wor" (0..<9) across both LTR runs: must start at x=0 and cover "Hello ".
        let across = laid.selectionRects(for: 0..<9)
        #expect(across.count == 1)
        if let rect = across.first {
            #expect(abs(rect.minX - laid.lines[0].caretOffsets[0]) < 0.5)
            #expect(abs(rect.maxX - laid.lines[0].caretOffsets[9]) < 0.5)
        }
    }

    /// CommonMark §5.3 edge cases: a blank line inside a blockquote must not
    /// make its enclosing list loose, whereas a blank line after an indented
    /// code block inside a list item makes the list loose.
    @Test func tightLooseListEdgeCasesMatchCommonMark() {
        let quotedBlank = MarkdownPlanner.blocks(from: "- > a\n  >\n- b\n")
        if case .list(let list) = quotedBlank.first {
            #expect(list.isTight)
        } else {
            Issue.record("expected tight list with quoted blank line")
        }

        let indentedCodeBlank = MarkdownPlanner.blocks(from: "-     code\n\n- bar\n")
        if case .list(let list) = indentedCodeBlank.first {
            #expect(!list.isTight)
        } else {
            Issue.record("expected loose list after indented code blank line")
        }
    }

    /// UAX #9 P2/P3 `paragraphIsRTL`: Arabic-Indic digits are weak (do not
    /// force RTL before an LTR letter), while Arabic Letter Mark (U+061C) and
    /// strong RTL letters do.
    @Test func paragraphIsRTLClassifiesDigitsAndALMCorrectly() {
        #expect(!TextLayoutEngine.paragraphIsRTL("١٢٣ hello" as NSString, startingAt: 0))
        #expect(TextLayoutEngine.paragraphIsRTL("\u{061C}hello" as NSString, startingAt: 0))
        #expect(TextLayoutEngine.paragraphIsRTL("123 مرحبا" as NSString, startingAt: 0))
    }

    /// UAX #29 GB4: `\t` and other C0/C1 controls always end a grapheme cluster
    /// even when followed by a combining mark or ZWJ (Apple's
    /// `rangeOfComposedCharacterSequence` merges them, while Core Text breaks).
    @Test func tabBeforeCombiningMarkOrZWJEndsCluster() {
        for sample in ["a\t\u{0301}b", "a\t\u{200D}b"] {
            let ns = sample as NSString
            #expect(TextLayoutEngine.startsCluster(ns, at: 1))
            #expect(TextLayoutEngine.startsCluster(ns, at: 2))
            #expect(TextLayoutEngine.clusterRange(in: ns, at: 1) == NSRange(location: 1, length: 1))
            #expect(TextLayoutEngine.clusterRange(in: ns, at: 2) == NSRange(location: 2, length: 1))
            let laid = layout([.paragraph([MarkdownInline(text: sample)])], width: 200)
            #expect(TranscriptFuzz.caretInsideCluster(laid) == nil)
        }
    }

    /// Incremental suffix layout keeps the full paragraph's UAX #9 direction
    /// when line 2 begins with an invisible RTL mark (`U+200F`/`U+061C`) or
    /// when lines 0..1 were neutral before an RTL suffix.
    @Test func incrementalParagraphSuffixPreservesParagraphDirection() {
        let pos = TranscriptBlockPosition(isFirst: true, isLast: true)
        let key = RowLayoutKey(contentVersion: 0, width: 260, styleVersion: style.version)
        let prefix1 = "Line one of English text that wraps cleanly. Line two of English text that wraps cleanly too. "
        let inlines1 = [MarkdownInline(text: prefix1 + "tail")]
        let inlines2 = [MarkdownInline(text: prefix1 + "\u{200F}tail more words")]
        let kind1 = TranscriptRowKind.markdownBlock(.paragraph(inlines1), pos)
        let kind2 = TranscriptRowKind.markdownBlock(.paragraph(inlines2), pos)
        let first = RowLayoutBuilder.layout(RowLayoutRequest(rowID: "p", kind: kind1, key: key, style: style))
        var req = RowLayoutRequest(rowID: "p", kind: kind2, key: key, style: style)
        req.previous = (kind1, first)
        let incremental = RowLayoutBuilder.layout(req)
        let full = RowLayoutBuilder.layout(RowLayoutRequest(rowID: "p", kind: kind2, key: key, style: style))
        #expect(TranscriptFuzz.difference(incremental.content, full.content) == nil)

        // Neutral prefix (digits/punctuation) followed by RTL flips the whole
        // paragraph and must fall back to one-shot layout.
        let neutral = String(repeating: "12345 67890 ", count: 12)
        let n1 = TranscriptRowKind.markdownBlock(.paragraph([MarkdownInline(text: neutral)]), pos)
        let n2 = TranscriptRowKind.markdownBlock(.paragraph([MarkdownInline(text: neutral + "\u{200F}123")]), pos)
        let firstNeutral = RowLayoutBuilder.layout(RowLayoutRequest(rowID: "n", kind: n1, key: key, style: style))
        var neutralReq = RowLayoutRequest(rowID: "n", kind: n2, key: key, style: style)
        neutralReq.previous = (n1, firstNeutral)
        let incNeutral = RowLayoutBuilder.layout(neutralReq)
        let fullNeutral = RowLayoutBuilder.layout(RowLayoutRequest(rowID: "n", kind: n2, key: key, style: style))
        #expect(TranscriptFuzz.difference(incNeutral.content, fullNeutral.content) == nil)
    }

    /// When a newly appended line adds an underline before an inline-code
    /// background (whose rect extends 1 pt above `line.top`), `RowContentDiff`
    /// must report the smaller `minY` so the band above it is not kept stale.
    @Test func unchangedHeightAccountsForProtrudingLaterDecorationsOnNewLine() throws {
        let url = try #require(URL(string: "https://example.com"))
        let base = MarkdownInline(text: "First line of text here.\n")
        let before = layout([.paragraph([base])], width: 400)
        let after = layout(
            [
                .paragraph([
                    base,
                    MarkdownInline(text: "link", link: url),
                    MarkdownInline(text: " "),
                    MarkdownInline(text: "code", style: .code),
                ])
            ], width: 400)
        #expect(after.lines.count == 2)
        let secondLineTop = after.lines[1].top
        let unchanged = RowContentDiff.unchangedHeight(before, after)
        #expect(unchanged < secondLineTop, "expected unchanged (\(unchanged)) < line 1 top (\(secondLineTop))")
    }
}
