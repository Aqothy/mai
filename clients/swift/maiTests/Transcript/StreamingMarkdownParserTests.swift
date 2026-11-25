import CoreGraphics
import Foundation
import Testing

@testable import mai

/// The rows a stream leaves are the rows the message has when opened later:
/// any chunking of a message ends in the blocks of a one-shot parse, and
/// committed blocks never change while it streams.
struct StreamingMarkdownParserTests {
    private static let fixtures: [(String, String)] = [
        ("rich", ChatMarkdownFixtures.richBlocks),
        ("code", ChatMarkdownFixtures.codeHeavy),
        ("catalog", ChatMarkdownFixtures.componentCatalog),
        ("long", ChatMarkdownFixtures.longMarkdown),
        ("lists", "- one\n- two\n\n- loose three\n\n  continued\n\nafter\n\n1. first\n2. second\n\n> quote\n> more\n\n---\n\n# Done\n"),
        ("html", "<!--\n\ncomment\n\n-->\n\ntext\n\n    indented\n\n    code\n\nend"),
    ]

    private static func committedLength(of source: String) -> Int {
        var copy = source
        return copy.withUTF8 { MarkdownPlanner.parse(bytes: $0, incomplete: true).committedLength }
    }

    @Test(arguments: [1, 7, 16, 97])
    func anyChunkingEndsInTheOneShotBlocks(chunk: Int) {
        for (name, source) in Self.fixtures {
            let characters = Array(source)
            var parser = StreamingMarkdownParser()
            var committed: [MarkdownBlock] = []
            var offset = 0
            // Chunk size 1 on the long fixtures would take long; step them
            // faster while keeping odd boundaries.
            let step = source.count > 4_000 ? max(chunk, 31) : chunk
            while offset < characters.count {
                offset = min(characters.count, offset + step)
                let snapshot = parser.update(String(characters[..<offset]))
                #expect(Array(snapshot.committed.prefix(committed.count)) == committed, "\(name) committed changed")
                committed = snapshot.committed
            }
            #expect(parser.finish(source) == MarkdownPlanner.blocks(from: source), "\(name) chunk \(chunk)")
        }
    }

    @Test func anOpenFenceStreamsAsCodeWithoutWaitingForItsClose() {
        var parser = StreamingMarkdownParser()
        let snapshot = parser.update("Intro\n\n```swift\nlet a = 1\nlet b")
        #expect(snapshot.committed == [.paragraph([MarkdownInline(text: "Intro")])])
        #expect(snapshot.open == [.code(language: "swift", code: "let a = 1\nlet b")])
    }

    @Test func unfinishedEmphasisAndLinksRenderHealed() {
        var parser = StreamingMarkdownParser()
        #expect(
            parser.update("Some **bold").open
                == [.paragraph([MarkdownInline(text: "Some "), MarkdownInline(text: "bold", style: .strong)])])
        var links = StreamingMarkdownParser()
        #expect(links.update("See [the docs](https://exa").open == [.paragraph([MarkdownInline(text: "See the docs")])])
    }

    /// A reference definition can resolve earlier references while keeping
    /// final output equal to one-shot parsing.
    @Test func aReferenceDefinitionResolvesEarlierBlocks() {
        let source = "Read [the guide][g].\n\nMore text.\n\n[g]: https://example.com\n"
        var parser = StreamingMarkdownParser()
        _ = parser.update(String(source.prefix(30)))
        _ = parser.update(source)
        #expect(parser.finish(source) == MarkdownPlanner.blocks(from: source))
    }

    /// Go code indents with tabs: a line of one tab and a brace (or a tab
    /// alone) is shorter than its indent in columns, and used to be sliced
    /// past its end.
    @Test func tabIndentedCodeStreamsToTheOneShotBlocks() {
        let source = "Intro\n\n```go\nfunc main() {\n\tif ok {\n\t\trun()\n\t}\n\t\n}\n```\n\n\tindented\n\t\nDone\n"
        var parser = StreamingMarkdownParser()
        for end in 1...source.count { _ = parser.update(String(source.prefix(end))) }
        #expect(parser.finish(source) == MarkdownPlanner.blocks(from: source))
    }

    /// CommonMark ends an HTML block at its closing tag in any letter case;
    /// an uppercase closer commits at the following blank line.
    @Test func anUppercaseHTMLCloserEndsItsBlock() {
        let committed = "<PRE>\nhello\n</PRE>\n\n"
        #expect(Self.committedLength(of: committed + "After\n") == committed.utf8.count)
    }

    /// A paragraph right after indented code is not code: its blank line
    /// commits both, even when more indented code follows.
    @Test func aParagraphAfterIndentedCodeCommitsAtItsBlankLine() {
        let committed = "    code\npara\n\n"
        #expect(Self.committedLength(of: committed + "    more\n") == committed.utf8.count)
    }

    /// `[key]: value` is a link definition in prose but code inside a fence
    /// (YAML, a TypeScript computed key): it must not reset committed blocks.
    @Test func definitionSyntaxInsideAFenceKeepsTheCommittedBlocks() {
        let source = "First paragraph.\n\n```ts\n[key]: value\n```\n\nAfter.\n"
        var parser = StreamingMarkdownParser()
        #expect(parser.update("First paragraph.\n\n").committed.count == 1)
        #expect(parser.update(String(source.dropLast("After.\n".count))).committed.count == 2)
        #expect(parser.committedResetCount == 0)
        #expect(parser.finish(source) == MarkdownPlanner.blocks(from: source))
    }

    /// Completion follows `@pierre/words`: code spans match runs of equal length
    /// (backslashes inside code are literal), code spans inside open emphasis
    /// still let it close, intra-word `_` is not emphasis, trailing `***` with
    /// nothing open stays literal, and code blocks are never mutated.
    @Test func theOpenTailCompletesByPierreRules() {
        var p1 = StreamingMarkdownParser()
        #expect(
            p1.update("Run **bold `code` more").open == [
                .paragraph([
                    MarkdownInline(text: "Run "), MarkdownInline(text: "bold ", style: .strong),
                    MarkdownInline(text: "code", style: [.strong, .code]), MarkdownInline(text: " more", style: .strong),
                ])
            ])
        var p2 = StreamingMarkdownParser()
        #expect(p2.update("set max_tokens higher").open == [.paragraph([MarkdownInline(text: "set max_tokens higher")])])
        var p3 = StreamingMarkdownParser()
        #expect(
            p3.update("``foo ` bar``").open == [.paragraph([MarkdownInline(text: "foo ` bar", style: .code)])])
        var p4 = StreamingMarkdownParser()
        #expect(p4.update("`\\`").open == [.paragraph([MarkdownInline(text: "\\", style: .code)])])
        var p5 = StreamingMarkdownParser()
        #expect(p5.update("hello ***").open == [.paragraph([MarkdownInline(text: "hello ***")])])
        var p6 = StreamingMarkdownParser()
        #expect(p6.update("**bold ").open == [.paragraph([MarkdownInline(text: "bold", style: .strong)])])
        var p7 = StreamingMarkdownParser()
        #expect(p7.update("    let x = **foo").open == [.code(language: nil, code: "let x = **foo")])
        var p8 = StreamingMarkdownParser()
        #expect(
            p8.update("- item\n\n  ```swift\n  let x = **foo").open == [
                .list(MarkdownList(startIndex: nil, isTight: false, items: [
                    MarkdownList.Item(blocks: [
                        .paragraph([MarkdownInline(text: "item")]),
                        .code(language: "swift", code: "let x = **foo"),
                    ]),
                ]))
            ])
    }

    /// GFM 5.3 task list markers parse into `MarkdownList.Item.taskChecked`,
    /// strip the marker from paragraph text, hide partial `[` / `[x` prefixes
    /// while streaming, and match one-shot parsing across arbitrary chunking.
    @Test func gfmTaskListMarkersParseAndStreamEquivalently() {
        let source = "- [ ] Todo item\n- [x] Done **bold**\n- [X] Also done\n- [ ]no space\n- [ ] \n- Regular\n"
        let blocks = MarkdownPlanner.blocks(from: source)
        #expect(
            blocks == [
                .list(MarkdownList(startIndex: nil, items: [
                    MarkdownList.Item(taskChecked: false, blocks: [.paragraph([MarkdownInline(text: "Todo item")])]),
                    MarkdownList.Item(taskChecked: true, blocks: [
                        .paragraph([MarkdownInline(text: "Done "), MarkdownInline(text: "bold", style: .strong)]),
                    ]),
                    MarkdownList.Item(taskChecked: true, blocks: [.paragraph([MarkdownInline(text: "Also done")])]),
                    MarkdownList.Item(taskChecked: nil, blocks: [.paragraph([MarkdownInline(text: "[ ]no space")])]),
                    MarkdownList.Item(taskChecked: nil, blocks: [.paragraph([MarkdownInline(text: "[ ]")])]),
                    MarkdownList.Item(taskChecked: nil, blocks: [.paragraph([MarkdownInline(text: "Regular")])]),
                ]))
            ])
        // Streaming partial markers hide `[`, `[x`, `[x]` until content follows.
        var partial = StreamingMarkdownParser()
        #expect(partial.update("- [x").open == [.list(MarkdownList(startIndex: nil, items: [MarkdownList.Item(blocks: [])]))])
        // Streaming in 1-byte and 7-byte chunks matches one-shot.
        for chunk in [1, 7] {
            var parser = StreamingMarkdownParser()
            let chars = Array(source)
            var offset = 0
            while offset < chars.count {
                offset = min(chars.count, offset + chunk)
                _ = parser.update(String(chars[..<offset]))
            }
            #expect(parser.finish(source) == blocks, "chunk \(chunk)")
        }
    }

    /// Partial table delimiter rows wait until the delimiter row is valid
    /// (pierre parity), and a started table's body row stays a body row.
    @Test func partialTableDelimiterWaitsAndBodyRowsStayCells() {
        var partial = StreamingMarkdownParser()
        #expect(partial.update("| A | B |\n| -").open == [.paragraph([MarkdownInline(text: "| A | B |\n| -")])])
        var started = StreamingMarkdownParser()
        let table = "| A | B |\n| --- | --- |\n| - |"
        #expect(
            started.update(table).open == [
                .table(MarkdownTable(
                    alignments: [.leading, .leading],
                    header: [[MarkdownInline(text: "A")], [MarkdownInline(text: "B")]],
                    rows: [[[MarkdownInline(text: "-")], []]]))
            ])
    }

    /// Any agent may send CRLF (a Windows file quoted in a fence): a CRLF
    /// blank line commits, an open CRLF fence streams as code, a rule keeps
    /// its spelling, and streaming ends in the one-shot blocks.
    @Test func crlfStreamsLikeLF() {
        #expect(Self.committedLength(of: "Para\r\n\r\nNext") == 8)
        var crlfFence = StreamingMarkdownParser()
        #expect(
            crlfFence.update("```go\r\nlet a = 1\r\n").open == [.code(language: "go", code: "let a = 1")])
        #expect(MarkdownPlanner.blocks(from: "***\r\n") == [.rule(spelling: "***")])
        let source =
            "# Title\r\n\r\n```swift\r\nlet a = 1\r\n\t}\r\n```\r\n\r\n---\r\n\r\n| A | B |\r\n| --- | --- |\r\n| 1 | 2 |\r\n\r\nEnd\r\n"
        var parser = StreamingMarkdownParser()
        var committed: [MarkdownBlock] = []
        for end in stride(from: 1, through: source.utf8.count, by: 5) {
            let snapshot = parser.update(String(decoding: Array(source.utf8.prefix(end)), as: UTF8.self))
            #expect(Array(snapshot.committed.prefix(committed.count)) == committed)
            committed = snapshot.committed
        }
        #expect(!committed.isEmpty)
        #expect(parser.finish(source) == MarkdownPlanner.blocks(from: source))
    }

    /// Large open fence, paragraph and table match one-shot parsing across
    /// incremental streaming updates.
    @Test(arguments: [17, 97, 256])
    func largeOpenBlocksStreamIncrementallyAndMatchOneShot(chunk: Int) {
        let fence = "Intro\n\n```go\n" + (0..<120).map { "\tx\($0) := f(\($0))\n" }.joined() + "```\n\nEnd"
        let words = ["stream", "layout", "**bold**", "`code`", "alpha", "beta", "foo_bar", "text"]
        let paragraph = (0..<600).map { words[$0 % words.count] }.joined(separator: " ")
        let table = "| Col A | Col B |\n| --- | --- |\n" + (0..<80).map { "| `k\($0)` | **v\($0)** |\n" }.joined() + "\nDone"
        for source in [fence, paragraph, table] {
            let chars = Array(source)
            var parser = StreamingMarkdownParser()
            var committed: [MarkdownBlock] = []
            var offset = 0
            while offset < chars.count {
                offset = min(chars.count, offset + chunk)
                let snap = parser.update(String(chars[..<offset]))
                #expect(Array(snap.committed.prefix(committed.count)) == committed)
                committed = snap.committed
            }
            #expect(parser.finish(source) == MarkdownPlanner.blocks(from: source))
        }
    }

    /// A link reference definition near the top of a document stays incremental
    /// (zero committed resets) while resolving later reference links identically
    /// to one-shot.
    @Test func topLinkReferenceDefinitionStaysIncremental() {
        var source = "[docs]: https://example.com/docs\n\n"
        for index in 0..<40 {
            source += "Paragraph \(index) references [the docs][docs] with **bold** and `code_\(index)`.\n\n"
        }
        let chars = Array(source)
        var parser = StreamingMarkdownParser()
        var offset = 0
        var previousCommitted = 0
        while offset < chars.count {
            offset = min(chars.count, offset + 97)
            let snap = parser.update(String(chars[..<offset]))
            #expect(snap.committed.count >= previousCommitted)
            previousCommitted = snap.committed.count
        }
        #expect(parser.committedResetCount == 0)
        #expect(parser.finish(source) == MarkdownPlanner.blocks(from: source))
    }

    /// A plain-text single paragraph and a rich single paragraph with inline
    /// syntax both match one-shot parsing across arbitrary chunk boundaries.
    @Test(arguments: [1, 7, 31, 128])
    func singleParagraphLiteralAndRichStreamMatchOneShot(chunk: Int) {
        let plain = (0..<120).map { "word\($0)" }.joined(separator: " ")
        let rich = (0..<60).map {
            "Sentence \($0) has **bold**, `code_\($0)`, *em*, ~~del~~, and [site](https://example.com/\($0))."
        }.joined(separator: " ")
        for source in [plain, rich] {
            let chars = Array(source)
            var parser = StreamingMarkdownParser()
            var offset = 0
            while offset < chars.count {
                offset = min(chars.count, offset + chunk)
                _ = parser.update(String(chars[..<offset]))
            }
            #expect(parser.finish(source) == MarkdownPlanner.blocks(from: source))
        }
    }

    /// Trailing `[label]:` in prose (not a real link reference definition) does
    /// not drop committed blocks or disable incremental streaming.
    @Test func proseColonAfterBracketsDoesNotTriggerDefinitionReset() {
        let source = "Intro paragraph.\n\nSecond paragraph mentions\n[paragraph continuation text]:\n\nAfter.\n"
        var parser = StreamingMarkdownParser()
        let chars = Array(source)
        for end in stride(from: 1, through: chars.count, by: 7) {
            _ = parser.update(String(chars[..<end]))
        }
        #expect(parser.committedResetCount == 0)
        #expect(parser.finish(source) == MarkdownPlanner.blocks(from: source))
    }

    /// Audit regressions: streaming equivalence across multi-word emphasis,
    /// split links, raw HTML, bare CR fences/tables, earlier-definition
    /// precedence, HTML block types 3-5, and trailing tabs.
    @Test func auditStreamingEquivalenceRegressions() {
        let cases: [(String, [String])] = [
            ("multi-word emphasis", ["**hello world foo bar", "** done"]),
            ("split link", ["See [foo bar]", "(https://example.com) ok"]),
            ("literal angle html", ["Hello world <div class=foo ", "bar>"]),
            ("bare CR fence close", ["```\nhello\n", "```\r**after**"]),
            ("split CRLF fence opener", ["```\r", "\nlet x = 1\r\n```"]),
            ("earlier def wins", ["[a]: https://first.example.com\n\n", "[a]: https://second.example.com\n\nSee [a]."]),
            ("html type 3", ["<?php\n\necho 1;\n?>\n\nafter"]),
            ("html type 4", ["<!DOCTYPE html\n\n>\n\nafter"]),
            ("html type 5", ["<![CDATA[\n\nx\n]]>\n\nafter"]),
            ("table bare CR", ["| A | B |\n| --- | --- |\n| 1 | 2 |\r", "| 3 | 4 |"]),
            ("trailing tab", ["hello world\t", "*a*"]),
        ]
        for (name, chunks) in cases {
            var parser = StreamingMarkdownParser()
            var acc = ""
            for chunk in chunks {
                acc += chunk
                _ = parser.update(acc)
            }
            #expect(parser.finish(acc) == MarkdownPlanner.blocks(from: acc), "\(name)")
        }
    }

    /// Audit regressions: parser correctness for CR in fences, indented-code
    /// trimming, link label normalization, 1-column tables, fence info entities,
    /// XML entities, GFM extended autolinks, raw HTML comments, and strikethrough.
    @Test func auditParserCorrectnessRegressions() {
        #expect(MarkdownPlanner.blocks(from: "```\r\nfoo\r\n\t```\r\n```") == [.code(language: nil, code: "foo\n\t```")])
        #expect(
            MarkdownPlanner.blocks(from: "```\nfoo ` bar\r```\n**after**") == [
                .code(language: nil, code: "foo ` bar"),
                .paragraph([MarkdownInline(text: "after", style: .strong)]),
            ])
        #expect(
            MarkdownPlanner.blocks(from: ">     code\n>\t  \n") == [
                .quote([.code(language: nil, code: "code")])
            ])
        #expect(
            MarkdownPlanner.blocks(from: "[\u{00A0}]: https://example.com\n\n[\u{00A0}]") == [
                .paragraph([MarkdownInline(text: "\u{00A0}", link: URL(string: "https://example.com"))])
            ])
        #expect(
            MarkdownPlanner.blocks(from: "[foo]\n\n[FOO]: https://example.com") == [
                .paragraph([MarkdownInline(text: "foo", link: URL(string: "https://example.com"))])
            ])
        #expect(
            MarkdownPlanner.blocks(from: "[ὈΔΥΣΣΕΎΣ]: https://example.com\n\n[ὀδυσσεύς]") == [
                .paragraph([MarkdownInline(text: "ὀδυσσεύς", link: URL(string: "https://example.com"))])
            ])
        #expect(
            MarkdownPlanner.blocks(from: "foo\n:---\nbar") == [
                .table(MarkdownTable(
                    alignments: [.leading],
                    header: [[MarkdownInline(text: "foo")]],
                    rows: [[[MarkdownInline(text: "bar")]]]))
            ])
        #expect(
            MarkdownPlanner.blocks(from: "```foo&#32;bar\ncode\n```") == [.code(language: "foo", code: "code")])
        #expect(
            MarkdownPlanner.blocks(from: "&AMP;&LT;&GT;&QUOT;") == [.paragraph([MarkdownInline(text: "&<>\"")])])
        #expect(
            MarkdownPlanner.blocks(from: "a <!--> b <!---> c") == [
                .paragraph([
                    MarkdownInline(text: "a "),
                    MarkdownInline(text: "<!-->", style: .code),
                    MarkdownInline(text: " b "),
                    MarkdownInline(text: "<!--->", style: .code),
                    MarkdownInline(text: " c"),
                ])
            ])
        #expect(
            MarkdownPlanner.blocks(from: "~~a ~5 b~~") == [
                .paragraph([MarkdownInline(text: "~~a ~5 b~~")])
            ])
        // GFM extended autolinks.
        #expect(
            MarkdownPlanner.blocks(from: "www.google.com/search?q=commonmark&hl;") == [
                .paragraph([
                    MarkdownInline(
                        text: "www.google.com/search?q=commonmark",
                        link: URL(string: "http://www.google.com/search?q=commonmark")),
                    MarkdownInline(text: "&hl;"),
                ])
            ])
        #expect(
            MarkdownPlanner.blocks(from: "http://localhost:8080") == [
                .paragraph([MarkdownInline(text: "http://localhost:8080", link: URL(string: "http://localhost:8080"))])
            ])
        #expect(
            MarkdownPlanner.blocks(from: "\"https://example.com\"") == [
                .paragraph([
                    MarkdownInline(text: "\""),
                    MarkdownInline(text: "https://example.com", link: URL(string: "https://example.com")),
                    MarkdownInline(text: "\""),
                ])
            ])
        #expect(
            MarkdownPlanner.blocks(from: "mailto:a@b.com") == [
                .paragraph([MarkdownInline(text: "mailto:a@b.com", link: URL(string: "mailto:a@b.com"))])
            ])
    }

    /// Every example in the 1,324-example CommonMark + GFM spec corpus parses
    /// cleanly and produces the exact same block tree when streamed in chunks
    /// as when parsed one-shot.
    @Test func commonMarkAndGFMSpecStreamingMatchesOneShot() throws {
        final class BundleAnchor {}
        let url =
            Bundle(for: BundleAnchor.self).url(forResource: "commonmark-gfm-spec", withExtension: "json")
            ?? URL(filePath: #filePath).deletingLastPathComponent().appending(path: "commonmark-gfm-spec.json")
        let data = try Data(contentsOf: url)
        let examples = try JSONDecoder().decode([String].self, from: data)
        #expect(examples.count == 1_324)

        for (index, source) in examples.enumerated() {
            let oneShot = MarkdownPlanner.blocks(from: source)
            var parser = StreamingMarkdownParser()
            let bytes = Array(source.utf8)
            var offset = 0
            while offset < bytes.count {
                // Step by UTF-8 scalar boundary in small chunks to stress block
                // and inline seams without splitting a scalar mid-codepoint.
                var next = min(bytes.count, offset + 11)
                while next < bytes.count, (bytes[next] & 0xC0) == 0x80 { next += 1 }
                let prefix = String(decoding: bytes[..<next], as: UTF8.self)
                _ = parser.update(prefix)
                offset = next
            }
            let streamed = parser.finish(source)
            #expect(streamed == oneShot, "spec example \(index) diverged:\n\(source)")
        }
    }
}
