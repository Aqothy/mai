import Foundation
import Markdown
import Testing

@testable import mai

struct ChatMarkdownChunkingTests {
    @Test
    func shortSourceStaysWhole() {
        let source = "A short reply with **formatting** and `code`."
        #expect(ChatMarkdownChunker.chunks(of: source) == [source])
    }

    @Test
    func longProseSplitsLosslessly() {
        let source = proseSource(paragraphCount: 120)
        let chunks = ChatMarkdownChunker.chunks(of: source)

        #expect(chunks.count > 1)
        #expect(chunks.joined() == source)
        #expect(chunks.allSatisfy { !$0.isEmpty })
    }

    @Test
    func chunkBoundariesPreserveTopLevelBlocks() {
        let source = proseSource(paragraphCount: 120)
        let chunks = ChatMarkdownChunker.chunks(of: source)

        let originalBlockCount = topLevelBlockCount(source)
        let chunkedBlockCount = chunks.map(topLevelBlockCount).reduce(0, +)
        #expect(chunkedBlockCount == originalBlockCount)
    }

    /// Selection-scope contract: prose — headings, lists, paragraphs — stays
    /// one selectable text view below the maximum chunk length, so drag
    /// selection spans it; seams appear only at code fences, tables, or the
    /// prose length bound.
    @Test
    func proseWithHeadingsAndListsStaysWholeUnderMaximum() {
        var sections: [String] = []
        for index in 1...14 {
            sections.append("## Section \(index)")
            sections.append(
                "Opening paragraph \(index) keeps the section oversized in "
                    + "total while every individual block remains ordinary prose."
            )
            sections.append(
                "Follow-up paragraph \(index) adds enough length that the "
                    + "whole document clears the chunking threshold comfortably."
            )
            sections.append(
                "- first point for section \(index)\n"
                    + "- second point for section \(index)\n"
                    + "- third point for section \(index)"
            )
        }
        let source = sections.joined(separator: "\n\n")

        #expect(ChatMarkdownChunker.isOversized(source))
        #expect(source.utf8.count < ChatMarkdownChunker.maximumChunkLength)
        #expect(ChatMarkdownChunker.chunks(of: source) == [source])
    }

    /// Seams land beside code fences (which already interrupt selection)
    /// rather than between paragraphs whenever the prose bound allows.
    @Test
    func cutsPreferCodeFenceBoundaries() {
        var sections: [String] = []
        for index in 1...8 {
            sections.append(proseSource(paragraphCount: 12))
            let lines = Array(
                repeating: "let value\(index) = \"payload-\(index)\"",
                count: 20
            )
            sections.append("```swift\n" + lines.joined(separator: "\n") + "\n```")
        }
        let source = sections.joined(separator: "\n\n")
        let chunks = ChatMarkdownChunker.chunks(of: source)

        #expect(chunks.count > 1)
        #expect(chunks.joined() == source)
        // Every seam is barrier-adjacent: a chunk either ends with a fence or
        // the next chunk starts with one; no seam separates two paragraphs.
        for (chunk, next) in zip(chunks, chunks.dropFirst()) {
            let endsWithFence =
                chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                    .hasSuffix("```")
            let nextStartsWithFence =
                next.trimmingCharacters(in: .whitespacesAndNewlines)
                    .hasPrefix("```")
            #expect(endsWithFence || nextStartsWithFence)
        }
    }

    @Test
    func fencedCodeBlocksNeverSplit() {
        var sections: [String] = []
        for index in 1...12 {
            sections.append(
                "Section \(index) introduces the snippet below with enough "
                    + "prose to keep boundaries realistic."
            )
            let lines = Array(
                repeating: "let value\(index) = \"payload-\(index)\"",
                count: 30
            )
            sections.append("```swift\n" + lines.joined(separator: "\n") + "\n```")
        }
        let source = sections.joined(separator: "\n\n")
        let chunks = ChatMarkdownChunker.chunks(of: source)

        #expect(chunks.count > 1)
        #expect(chunks.joined() == source)
        #expect(chunks.map(codeBlockCount).reduce(0, +) == codeBlockCount(source))
        #expect(
            chunks.map(topLevelBlockCount).reduce(0, +)
                == topLevelBlockCount(source)
        )
    }

    @Test
    func multibyteProseSplitsLosslessly() {
        let paragraph = "日本語のテキストと絵文字 👩🏽‍💻 が混在した段落は、"
            + "分割位置が常に UTF-8 の境界に一致することを確認します。"
        let source = Array(repeating: paragraph, count: 120)
            .joined(separator: "\n\n")
        let chunks = ChatMarkdownChunker.chunks(of: source)

        #expect(chunks.count > 1)
        #expect(chunks.joined() == source)
    }

    @Test
    func referenceDefinitionsDisableChunking() {
        let source = proseSource(paragraphCount: 60)
            + "\n\nSee [the docs][ref] for details.\n\n[ref]: https://example.com/docs"
        #expect(ChatMarkdownChunker.isOversized(source))
        #expect(ChatMarkdownChunker.chunks(of: source) == [source])
    }

    @Test
    func singleOversizedBlockStaysWhole() {
        let lines = Array(repeating: "let payload = \"0123456789abcdef\"", count: 200)
        let source = "```swift\n" + lines.joined(separator: "\n") + "\n```"
        #expect(ChatMarkdownChunker.isOversized(source))
        #expect(ChatMarkdownChunker.chunks(of: source) == [source])
    }

    @MainActor
    @Test
    func cacheRecomputesWhenSourceChanges() {
        let cache = ChatMarkdownChunkCache()
        let short = "One short message."
        #expect(cache.chunks(messageID: "m", source: short) == [short])

        let long = proseSource(paragraphCount: 60)
        let chunks = cache.chunks(messageID: "m", source: long)
        #expect(chunks.count > 1)
        #expect(chunks.joined() == long)
        #expect(cache.chunks(messageID: "m", source: long) == chunks)
    }

    private func proseSource(paragraphCount: Int) -> String {
        (1...paragraphCount).map { index in
            "Paragraph \(index) exercises chunk boundaries with enough "
                + "repeated words to cross the target length once combined "
                + "with its neighbors in the generated essay."
        }.joined(separator: "\n\n")
    }

    private func topLevelBlockCount(_ source: String) -> Int {
        Markdown.Document(parsing: source).childCount
    }

    private func codeBlockCount(_ source: String) -> Int {
        Markdown.Document(parsing: source).children.filter { $0 is CodeBlock }.count
    }
}
