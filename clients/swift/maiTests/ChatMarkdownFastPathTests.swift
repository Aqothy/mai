import Testing

@testable import mai

/// Rendering fast paths skip work the full swift-markdown parse would do.
/// Each must stay semantically identical to that parse.
struct ChatMarkdownFastPathTests {
    /// `segments(of:)` returns one prose run without parsing when a
    /// conservative prefilter finds no possible rich-block introducer.
    @Test @MainActor
    func segmentPrefilterMatchesTheFullParser() {
        let sources =
            MockChatMessage.variableHeightStressConversation(count: 1_000).map(\.text) + [
                "Plain paragraph with **bold** and a [link](https://example.com).",
                "# Heading\n\n- list\n- items\n\n> quote\n\n---\n\nTail",
                "Setext heading\n===\n\n1. ordered\n2. list\n\n* * *",
                "Inline `code`, *emphasis* and ![image](https://example.com/a.png)",
                "[ref]: https://example.com\n\nUses [ref].",
                "   \n",
            ]
        for source in sources {
            #expect(
                ChatMarkdownSegmenter.segments(of: source)
                    == ChatMarkdownSegmenter.segmentsUsingFullParser(of: source),
                "\(source.prefix(60))")
        }
    }

    /// Streaming freezes stable prose at a chunk limit so a settle touches a
    /// bounded tail. Chunking is presentation-only: the streamed plan must
    /// converge on the settled full parse.
    @Test @MainActor
    func streamedPrefixesConvergeOnTheSettledPlan() throws {
        let source = MockChatMessage.essay(wordCount: 10_000)
        let characters = Array(source)
        let chunkSize = (characters.count + 239) / 240
        var planner = ChatIncrementalMarkdownRenderPlanner()
        var snapshot: ChatStreamingMarkdownSnapshot?
        for end in stride(from: chunkSize, through: characters.count + chunkSize - 1, by: chunkSize) {
            snapshot = planner.snapshot(
                source: String(characters[..<min(end, characters.count)]),
                sourceIsAppendOnly: true)
        }
        let final = try #require(snapshot)
        #expect(final.stableBlockCount > 1)
        #expect(
            ChatMarkdownRenderPlan(blocks: final.plan.blocks)
                == ChatMarkdownRenderPlanner.plan(from: source))
    }
}
