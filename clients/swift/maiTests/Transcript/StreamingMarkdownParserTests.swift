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

    /// A reference definition can change earlier text; from then on the
    /// whole message parses each update.
    @Test func aReferenceDefinitionParsesTheWholeMessage() {
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
    /// an uppercase closer used to keep everything after it uncommitted.
    @Test func anUppercaseHTMLCloserEndsItsBlock() {
        let committed = "<PRE>\nhello\n</PRE>\n\n"
        #expect(MarkdownCommitBoundary.committedLength(of: Array((committed + "After\n").utf8)) == committed.utf8.count)
    }

    /// A paragraph right after indented code is not code: its blank line
    /// commits both, even when more indented code follows.
    @Test func aParagraphAfterIndentedCodeCommitsAtItsBlankLine() {
        let committed = "    code\npara\n\n"
        #expect(
            MarkdownCommitBoundary.committedLength(of: Array((committed + "    more\n").utf8)) == committed.utf8.count)
    }

    /// `[key]: value` is a link definition in prose but code inside a fence
    /// (YAML, a TypeScript computed key): it must not switch the parser to
    /// whole-message parsing and drop the committed blocks.
    @Test func definitionSyntaxInsideAFenceKeepsTheCommittedBlocks() {
        let source = "First paragraph.\n\n```ts\n[key]: value\n```\n\nAfter.\n"
        var parser = StreamingMarkdownParser()
        #expect(parser.update("First paragraph.\n\n").committed.count == 1)
        #expect(parser.update(String(source.dropLast("After.\n".count))).committed.count == 2)
        #expect(parser.finish(source) == MarkdownPlanner.blocks(from: source))
    }

    /// The open tail heals as CommonMark will read it once closed: code spans
    /// match runs of equal length (a backslash in code is literal), a code
    /// span inside open emphasis still lets it close, `_` inside a word is
    /// not emphasis, and an unclosed `***` at the end goes whole.
    @Test func theOpenTailHealsByCommonMarkRules() {
        #expect(
            MarkdownTailHealer.blocks(forOpenTail: "Run **bold `code` more") == [
                .paragraph([
                    MarkdownInline(text: "Run "), MarkdownInline(text: "bold ", style: .strong),
                    MarkdownInline(text: "code", style: [.strong, .code]), MarkdownInline(text: " more", style: .strong),
                ])
            ])
        #expect(MarkdownTailHealer.healed("set max_tokens higher") == "set max_tokens higher")
        #expect(MarkdownTailHealer.healed("``foo ` bar``") == "``foo ` bar``")
        #expect(MarkdownTailHealer.healed("`\\`") == "`\\`")
        #expect(MarkdownTailHealer.healed("hello ***") == "hello ")
    }

    /// A started table's next row can begin like a delimiter row; it must not
    /// be filled in as one, which showed a row of dashes for a frame.
    @Test func aStartedTablesBodyRowIsNotHealedAsADelimiterRow() {
        let table = "| A | B |\n| --- | --- |\n| - |"
        #expect(MarkdownTailHealer.healed(table) == table)
        #expect(MarkdownTailHealer.healed("| A | B |\n| -") == "| A | B |\n| --- | --- |")
    }
}
