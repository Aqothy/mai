import Foundation
import Testing

@testable import mai

struct ChatStreamingMarkdownRendererTests {
    @Test
    func repairsPartialInlineFormattingWithoutChangingCompletedSource() {
        #expect(
            ChatStreamingMarkdownRepairer.repair("A **partial").displaySource
                == "A **partial**"
        )
        #expect(
            ChatStreamingMarkdownRepairer.repair("A *partial").displaySource
                == "A *partial*"
        )
        #expect(
            ChatStreamingMarkdownRepairer.repair("Use `print").displaySource
                == "Use `print`"
        )
        #expect(
            ChatStreamingMarkdownRepairer.repair("A ~~partial").displaySource
                == "A ~~partial~~"
        )

        let complete = "A **complete** value with `code`."
        let repaired = ChatStreamingMarkdownRepairer.repair(complete)
        #expect(repaired.displaySource == complete)
        #expect(repaired.appliedKinds.isEmpty)
    }

    @Test
    func hidesDelimiterOnlyTailsUntilTheyHaveContent() {
        #expect(
            ChatStreamingMarkdownRepairer.repair("Paragraph\n\n##")
                .displaySource == "Paragraph\n\n"
        )
        #expect(
            ChatStreamingMarkdownRepairer.repair("Paragraph **")
                .displaySource == "Paragraph "
        )
        #expect(
            ChatStreamingMarkdownRepairer.repair("Paragraph `")
                .displaySource == "Paragraph "
        )
        #expect(
            ChatStreamingMarkdownRepairer.repair("Read [the gui")
                .displaySource == "Read the gui"
        )
    }

    @Test
    func rendersOpenFencesAsDedicatedCodeBlocks() {
        let source = "```swift\nlet value = 42"
        let repaired = ChatStreamingMarkdownRepairer.repair(source)
        let plan = ChatMarkdownRenderPlanner.plan(from: repaired.displaySource)

        #expect(repaired.displaySource == source)
        #expect(repaired.appliedKinds == [.codeFence])
        #expect(repaired.openCodeBlock?.language == "swift")
        #expect(repaired.openCodeBlock?.code == "let value = 42")
        #expect(plan.blocks.count == 1)
        guard case .code(let block) = plan.blocks[0] else {
            Issue.record("Expected repaired source to render as code")
            return
        }
        #expect(block.language == "swift")
        #expect(block.kind == .fenced)
        #expect(block.code == "let value = 42")

        let completed = ChatStreamingMarkdownRepairer.repair(
            source + "\n```"
        )
        #expect(!completed.appliedKinds.contains(.codeFence))
        #expect(completed.openCodeBlock == nil)
    }

    @Test
    func incompleteLinksRepairWhileUnsupportedImagesRemainLiteral() {
        let link = ChatStreamingMarkdownRepairer.repair(
            "Read [the guide](https://example.com/par"
        )
        let image = ChatStreamingMarkdownRepairer.repair(
            "Before ![diagram](https://example.com/par"
        )
        let autolink = ChatStreamingMarkdownRepairer.repair(
            "Visit <https://example.com/par"
        )

        #expect(link.displaySource == "Read the guide")
        #expect(link.appliedKinds == [.link])
        #expect(
            image.displaySource
                == "Before ![diagram](https://example.com/par"
        )
        #expect(image.appliedKinds.isEmpty)
        #expect(autolink.displaySource == "Visit https://example.com/par")
        #expect(autolink.appliedKinds == [.link])
    }

    @Test
    func escapedAndCodeProtectedDelimitersRemainLiteral() {
        let escaped = #"Use \*literal and \`literal"#
        let completedCode = "Use `**literal**` here"
        let partialLink = "Use `[not a link]` and [the guide"

        #expect(
            ChatStreamingMarkdownRepairer.repair(escaped).displaySource
                == escaped
        )
        #expect(
            ChatStreamingMarkdownRepairer.repair(completedCode).displaySource
                == completedCode
        )
        #expect(
            ChatStreamingMarkdownRepairer.repair(partialLink).displaySource
                == "Use `[not a link]` and the guide"
        )
    }

    @Test
    func everyPrefixOfRepresentativeMarkdownRemainsRenderable() {
        let source = """
            ## Streaming

            A **bold** value, an *italic* value, and `inline code`.

            [Guide](https://example.com/guide)

            ```swift
            let value = 42
            ```
            """
        var prefix = ""

        for character in source {
            prefix.append(character)
            let repaired = ChatStreamingMarkdownRepairer.repair(prefix)
            _ = ChatMarkdownRenderPlanner.plan(from: repaired.displaySource)
        }

        let finalRepair = ChatStreamingMarkdownRepairer.repair(source)
        #expect(finalRepair.displaySource == source)
        #expect(finalRepair.appliedKinds.isEmpty)
    }

    @Test
    func repairsAPartialDelimiterRowIntoAVisibleTable() {
        let partial = """
            | Name | State |
            | --
            """
        let repaired = ChatStreamingMarkdownRepairer.repair(partial)
        let plan = ChatMarkdownRenderPlanner.plan(from: repaired.displaySource)

        #expect(repaired.appliedKinds == [.table])
        #expect(repaired.displaySource.hasSuffix("| --- | --- |"))
        guard case .table(let table) = plan.blocks.first else {
            Issue.record("Expected a table before its delimiter row finished")
            return
        }
        #expect(table.header.count == 2)
    }

    @Test
    func partialBlockQuoteUsesASelectableDecoratedBlockImmediately() {
        var planner = ChatIncrementalMarkdownRenderPlanner()

        let marker = planner.snapshot(source: "> ")
        #expect(marker.plan.blocks.isEmpty)

        let firstText = planner.snapshot(source: "> Q")
        guard case .prose(let prose) = firstText.plan.blocks.first,
            case .quote(let quote)? = prose.pieces.first
        else {
            Issue.record("Expected a quote as soon as text arrived")
            return
        }
        #expect(String(quote.characters) == "Q")
        #expect(String(quote.characters).contains("▏") == false)
        #expect(String(quote.characters).contains(">") == false)

        let continued = planner.snapshot(source: "> Quote\n> continues")
        guard case .prose(let continuedProse) = continued.plan.blocks.first,
            case .quote(let continuedQuote)? = continuedProse.pieces.first
        else {
            Issue.record("Expected the active quote to remain a quote")
            return
        }
        #expect(String(continuedQuote.characters) == "Quote continues")
    }

    @Test
    func incrementalPlannerKeepsCompletedParagraphsStable() {
        var planner = ChatIncrementalMarkdownRenderPlanner()
        let secondSource =
            "First paragraph.\n\nSecond paragraph is streaming now.\n\nThird"
        let first = planner.snapshot(
            source: "First paragraph.\n\nSecond paragraph is streaming"
        )
        let second = planner.snapshot(source: secondSource)

        #expect(first.stableBlockCount == 1)
        #expect(second.stableBlockCount == 1)
        #expect(second.plan.blocks.count == 2)
        guard case .prose(let stableProse) = second.plan.blocks.first else {
            Issue.record("Expected completed paragraphs to share one run")
            return
        }
        #expect(stableProse.pieces.count == 2)
        #expect(stableProse.source.contains("First paragraph."))
        #expect(stableProse.source.contains("Second paragraph is streaming now."))
        #expect(!stableProse.source.contains("Third"))
        #expect(
            ChatMarkdownRenderPlan(blocks: second.plan.blocks)
                == ChatMarkdownRenderPlanner.plan(from: secondSource)
        )
    }

    /// A fresh planner parsing the complete source in one call must produce
    /// the same chunked blocks as incremental streaming did. The settled
    /// flip seeds a recreated view from the last streamed snapshot and
    /// relies on this to avoid re-laying-out every stable run.
    @Test
    func batchReplayMatchesIncrementalChunking() {
        var incremental = ChatIncrementalMarkdownRenderPlanner()
        var source = ""
        var finalSnapshot: ChatStreamingMarkdownSnapshot?

        let blocks =
            (1...16).map { index in
                "Paragraph \(index) "
                    + String(repeating: "replay word ", count: 45)
                    + "ends."
            }
            + [
                "```swift\nlet value = 42\n```",
                "> A quote block between prose runs.",
                "Closing paragraph after the quote.",
            ]
        for block in blocks {
            source += block + "\n\n"
            finalSnapshot = incremental.snapshot(
                source: source,
                sourceIsAppendOnly: true
            )
        }

        var batch = ChatIncrementalMarkdownRenderPlanner()
        let replay = batch.snapshot(source: source, sourceIsAppendOnly: true)

        #expect(replay.plan == finalSnapshot?.plan)
        #expect(replay.stableBlockCount == finalSnapshot?.stableBlockCount)
    }

    @Test
    func incrementalPlannerResetsForProviderReplacement() {
        var planner = ChatIncrementalMarkdownRenderPlanner()
        _ = planner.snapshot(source: "First.\n\nSecond.\n\nDraft")
        let replacement = "A replacement with **complete** Markdown."
        let snapshot = planner.snapshot(source: replacement)

        #expect(snapshot.stableBlockCount == 0)
        #expect(
            ChatMarkdownRenderPlan(blocks: snapshot.plan.blocks)
                == ChatMarkdownRenderPlanner.plan(from: replacement)
        )
    }

    @Test
    func referenceDefinitionReturnsToFullDocumentParsing() {
        var planner = ChatIncrementalMarkdownRenderPlanner()
        let prefix = "Read [the guide][guide].\n\nA second paragraph.\n\n"
        _ = planner.snapshot(
            source: prefix,
            sourceIsAppendOnly: true
        )
        let source = prefix + "[guide]: https://example.com"
        let snapshot = planner.snapshot(
            source: source,
            sourceIsAppendOnly: true
        )

        #expect(snapshot.stableBlockCount == 0)
        #expect(
            ChatMarkdownRenderPlan(blocks: snapshot.plan.blocks)
                == ChatMarkdownRenderPlanner.plan(from: source)
        )
    }
}
