import Foundation
import Markdown
import MarkdownView
import Testing

@testable import mai

struct ChatMarkdownTests {
    @Test
    func sharedCodeHighlighterPreservesSwiftSourceAndTokenRuns() async throws {
        let source = "let greeting = \"Hello, Markdown\""
        let result = await ChatCodeHighlighter.shared.highlight(
            code: source,
            language: "swift",
            themeName: "atom-one-dark"
        )
        let highlighted = try #require(result)

        #expect(String(highlighted.characters) == source)
        #expect(highlighted.runs.count > 1)
    }

    @Test
    func supportedMarkdownProducesExpectedSemanticNodes() {
        let source = #"""
            # Heading

            A paragraph with *emphasis*, **strong text**, ~~strikethrough~~,
            `inline code`, and a [safe link](https://example.com/docs).

            > A blockquote with **formatting**.

            1. First ordered item
               - Nested unordered item
            2. Second ordered item

            ```swift
            let greeting = "Hello, Markdown"
            ```

            ---

            | Feature | State |
            | :--- | :---: |
            | Streaming | Ready |
            """#
        let document = Markdown.Document(parsing: source)
        var counter = MarkdownStructureCounter()
        counter.visit(document)

        #expect(counter.headings == 1)
        #expect(counter.paragraphs > 0)
        #expect(counter.emphasis > 0)
        #expect(counter.strong > 0)
        #expect(counter.strikethrough > 0)
        #expect(counter.inlineCode > 0)
        #expect(counter.links > 0)
        #expect(counter.blockQuotes > 0)
        #expect(counter.orderedLists > 0)
        #expect(counter.unorderedLists > 0)
        #expect(counter.codeBlocks > 0)
        #expect(counter.thematicBreaks > 0)
        #expect(counter.tables > 0)
        #expect(
            ChatMarkdownDocumentAnalyzer.analyze(document)
                == ChatMarkdownDocumentAnalysis()
        )
    }

    @Test
    func plainTextProducesAParagraphWithoutFallback() {
        let source = """
            Plain text remains readable across lines.
            Unicode is preserved: café, e\u{301}, 日本語, and 👩🏽‍💻.
            """
        let document = Markdown.Document(parsing: source)
        var counter = MarkdownStructureCounter()
        counter.visit(document)

        #expect(counter.paragraphs == 1)
        #expect(counter.formattedOrBlockFeatureCount == 0)
        #expect(
            ChatMarkdownDocumentAnalyzer.analyze(document)
                == ChatMarkdownDocumentAnalysis()
        )
    }

    @Test
    func rawAnalyzerDetectsHTMLAndImagesAsADefensiveFallback() {
        let source = #"""
            <section>
            Block HTML must remain inert.
            </section>

            A paragraph with <kbd>inline HTML</kbd>.

            ![Remote image](https://example.invalid/image.png)
            """#

        let analysis = ChatMarkdownDocumentAnalyzer.analyze(source: source)

        #expect(analysis.containsBlockHTML)
        #expect(analysis.containsInlineHTML)
        #expect(analysis.containsImage)
        #expect(analysis.requiresPlainTextFallback)
        #expect(
            analysis.plainTextFallbackDescription
                == "block HTML, inline HTML, image"
        )
    }

    @Test
    func sanitizerLocalizesHTMLAndImagesWithoutFlatteningTheMessage() {
        let source = #"""
            # Heading 👩🏽‍💻

            Before **formatted prose**.

            <section>
            Block HTML stays visible.
            </section>

            Press <kbd>Command</kbd> to continue.

            ![Remote image](https://example.invalid/image.png)

            After [a display-only link](javascript:alert%281%29).
            """#

        let sanitized = ChatMarkdownSourceSanitizer.sanitize(source)
        let document = Markdown.Document(parsing: sanitized)
        var counter = MarkdownStructureCounter()
        counter.visit(document)

        #expect(sanitized.hasPrefix("# Heading 👩🏽‍💻"))
        #expect(sanitized.contains("Before **formatted prose**."))
        #expect(sanitized.contains("~~~html"))
        #expect(sanitized.contains("<section>"))
        #expect(sanitized.contains("` <kbd> `"))
        #expect(
            sanitized.contains(
                "` ![Remote image](https://example.invalid/image.png) `"
            )
        )
        #expect(sanitized.contains("[a display-only link]"))
        #expect(counter.headings == 1)
        #expect(counter.strong == 1)
        #expect(counter.codeBlocks == 1)
        #expect(counter.inlineCode >= 2)
        #expect(counter.links == 1)
        #expect(
            ChatMarkdownDocumentAnalyzer.analyze(document)
                == ChatMarkdownDocumentAnalysis()
        )
    }

    @Test
    func htmlAndImageLookingTextInsideCodeIsNotRewritten() {
        let source = #"""
            ```markdown
            <section>This is a literal example.</section>
            ![Example image](https://example.invalid/image.png)
            ```

            Inline code is literal too: `<script>` and `![alt](image.png)`.
            """#

        let sanitized = ChatMarkdownSourceSanitizer.sanitize(source)
        let analysis = ChatMarkdownDocumentAnalyzer.analyze(source: sanitized)

        #expect(sanitized == source)
        #expect(analysis == ChatMarkdownDocumentAnalysis())
    }

    @Test
    func linksRemainMarkdownWithoutTriggeringWholeMessageFallback() {
        let source = """
            [HTTPS](https://example.com), [relative](/docs), and
            [unsafe](javascript:alert%281%29) remain display-only links.
            """
        let sanitized = ChatMarkdownSourceSanitizer.sanitize(source)
        let analysis = ChatMarkdownDocumentAnalyzer.analyze(source: sanitized)

        #expect(sanitized == source)
        #expect(analysis == ChatMarkdownDocumentAnalysis())
    }

    @Test
    func incompleteMarkdownRemainsAnalyzableWithoutUnsafeFallback() {
        let partialSources = [
            "The response ends with **unfinished strong and _nested emphasis",
            "Documentation: [Markdown reference](https://example.com/docs/mark",
            """
            | Renderer | Streaming | Tables |
            | :--- | :---: |
            | Native | yes
            """,
            #"""
            ```swift
            struct PendingReply {
                let source: String
            }
            """#,
        ]

        for source in partialSources {
            let analysis = ChatMarkdownDocumentAnalyzer.analyze(source: source)

            #expect(source.isEmpty == false)
            #expect(analysis == ChatMarkdownDocumentAnalysis())
        }
    }

    @Test
    func anUnclosedFenceTreatsUnsupportedLookingSyntaxAsLiteralCode() {
        let source = #"""
            ```html
            <script>alert("inert")</script>
            ![not an image node](https://example.invalid/image.png)
            """#

        let analysis = ChatMarkdownDocumentAnalyzer.analyze(source: source)

        #expect(analysis == ChatMarkdownDocumentAnalysis())
        #expect(analysis.requiresPlainTextFallback == false)
    }

    @Test
    func frequentCumulativeAndReplacementUpdatesPreserveStreamingSource() {
        let completeSource = #"""
            ## Streamed response

            This grows through **partial delimiters**, a
            [documentation link](https://example.com/docs), and Unicode 👩🏽‍💻.

            1. Preserve the stable message identifier.
            2. Analyze each cumulative source.

            ```swift
            let state = "streaming"
            ```
            """#
        let chunks = characterChunks(
            source: completeSource,
            pattern: [1, 2, 3, 5, 8, 13]
        )

        let streamingSource = StreamingMarkdownSource()
        let stableSourceIdentity = ObjectIdentifier(streamingSource)
        var cumulativeSource = ""

        for chunk in chunks {
            cumulativeSource.append(contentsOf: chunk)
            streamingSource.text = cumulativeSource
            let analysis = ChatMarkdownDocumentAnalyzer.analyze(
                source: streamingSource.text
            )

            #expect(ObjectIdentifier(streamingSource) == stableSourceIdentity)
            #expect(streamingSource.text == cumulativeSource)
            #expect(analysis.requiresPlainTextFallback == false)
        }

        let replacement = """
            The provider replaced its draft with a complete plain-text answer.
            A second line confirms that newline content remains available.
            """
        streamingSource.text = replacement
        let replacementAnalysis = ChatMarkdownDocumentAnalyzer.analyze(
            source: streamingSource.text
        )
        streamingSource.finishStreaming()

        #expect(chunks.count > 40)
        #expect(ObjectIdentifier(streamingSource) == stableSourceIdentity)
        #expect(streamingSource.text == replacement)
        #expect(streamingSource.text.hasPrefix(completeSource) == false)
        #expect(replacementAnalysis == ChatMarkdownDocumentAnalysis())
    }

    #if DEBUG
        @Test
        func mockComponentCatalogRetainsEveryCoreSemanticCategory() {
            let document = Markdown.Document(
                parsing: MockChatMarkdownFixtures.componentCatalog
            )
            var counter = MarkdownStructureCounter()
            counter.visit(document)

            #expect(counter.headings >= 6)
            #expect(counter.paragraphs > 0)
            #expect(counter.emphasis > 0)
            #expect(counter.strong > 0)
            #expect(counter.strikethrough > 0)
            #expect(counter.inlineCode > 0)
            #expect(counter.links > 0)
            #expect(counter.blockQuotes > 0)
            #expect(counter.orderedLists > 0)
            #expect(counter.unorderedLists > 0)
            #expect(counter.codeBlocks > 0)
            #expect(counter.thematicBreaks > 0)
            #expect(counter.tables > 0)
            #expect(
                ChatMarkdownDocumentAnalyzer.analyze(document)
                    == ChatMarkdownDocumentAnalysis()
            )
        }

        @Test
        func unsupportedSandboxFixturesBecomeSafeMarkdown() {
            let analyses = Dictionary(
                uniqueKeysWithValues: MockChatMarkdownFixtures.unsupportedSamples.map {
                    let sanitized = ChatMarkdownSourceSanitizer.sanitize(
                        $0.markdown
                    )
                    return (
                        $0.id,
                        ChatMarkdownDocumentAnalyzer.analyze(source: sanitized)
                    )
                }
            )

            #expect(analyses.count == MockChatMarkdownFixtures.unsupportedSamples.count)
            for analysis in analyses.values {
                #expect(analysis == ChatMarkdownDocumentAnalysis())
            }
        }

        @Test
        func everyDeterministicStreamProfileReconstructsExactUnicodeAndNewlines() {
            let source = [
                "👩🏽‍💻 café e\u{301}\r\n",
                "\r\n",
                "## 日本語と Markdown\n",
                "A family emoji stays whole: 👨‍👩‍👧‍👦\n",
                "A hard break follows.  \n",
                "終わり\n",
            ].joined()

            for profile in MockChatStreamProfile.allCases {
                let chunks = MockChatMarkdownStream.chunks(
                    source: source,
                    profile: profile
                )
                var appendedSource = ""
                for chunk in chunks {
                    MockChatMarkdownStream.append(chunk, to: &appendedSource)
                }

                #expect(chunks.isEmpty == false)
                #expect(chunks.first == "👩🏽‍💻")
                #expect(appendedSource == source)
                #expect(
                    MockChatMarkdownStream.reconstructedSource(from: chunks)
                        == source
                )
            }
        }

        @MainActor
        @Test
        func mockJumpToBottomImmediatelyRestoresStreamingFollowIntent() {
            let scrollState = MockChatScrollState()
            scrollState.noteUserScrollActivity(isActive: true)

            #expect(scrollState.shouldFollowBottom == false)

            scrollState.requestScrollToBottom(animated: true)

            #expect(scrollState.shouldFollowBottom)
            #expect(scrollState.bottomScrollRequest.animated)
        }

        @Test
        func largeVariableHeightTranscriptHasStableUniqueRowsAndVariedContent() {
            let messageCount = 2_000
            let messages = MockChatMessage.variableHeightStressConversation(
                count: messageCount
            )

            #expect(messages.count == messageCount)
            #expect(Set(messages.map(\.id)).count == messageCount)
            #expect(Set(messages.map(\.text.count)).count >= 10)
            #expect(messages.contains(where: { $0.role == .user }))
            #expect(messages.contains(where: { $0.role == .agent }))
            #expect(
                messages.contains(where: { $0.text.contains("```swift") })
            )
            #expect(
                MockChatMessage.variableHeightStressConversation(count: -1).isEmpty
            )
        }
    #endif

    @Test
    func presentationKeepsStreamingConfigurationBoundedAndPortable() {
        let presentation = ChatMarkdownPresentation(
            isStreaming: true,
            streamingThrottle: .milliseconds(-10),
            showsDiagnostics: true
        )

        #expect(presentation.isStreaming)
        #expect(presentation.streamingThrottle == .zero)
        #expect(presentation.showsDiagnostics)
    }

    @Test
    func timelinePresentationStreamsOnlyAssistantMessagesFromTheRunningTurn() {
        let streaming = ChatMarkdownPresentation.timelineMessage(
            role: MaidMessageRole.assistant.rawValue,
            turnID: "turn-1",
            streamingTurnID: "turn-1"
        )
        let user = ChatMarkdownPresentation.timelineMessage(
            role: MaidMessageRole.user.rawValue,
            turnID: "turn-1",
            streamingTurnID: "turn-1"
        )
        let completed = ChatMarkdownPresentation.timelineMessage(
            role: MaidMessageRole.assistant.rawValue,
            turnID: "turn-1",
            streamingTurnID: nil
        )
        let otherTurn = ChatMarkdownPresentation.timelineMessage(
            role: MaidMessageRole.assistant.rawValue,
            turnID: "turn-1",
            streamingTurnID: "turn-2"
        )
        let missingTurnIDs = ChatMarkdownPresentation.timelineMessage(
            role: MaidMessageRole.assistant.rawValue,
            turnID: nil,
            streamingTurnID: nil
        )

        #expect(streaming.isStreaming)
        #expect(user.isStreaming == false)
        #expect(completed.isStreaming == false)
        #expect(otherTurn.isStreaming == false)
        #expect(missingTurnIDs.isStreaming == false)
    }

    private func characterChunks(
        source: String,
        pattern: [Int]
    ) -> [String] {
        var chunks: [String] = []
        var lowerBound = source.startIndex
        var patternIndex = 0

        while lowerBound < source.endIndex {
            let chunkSize = pattern[patternIndex % pattern.count]
            let upperBound =
                source.index(
                    lowerBound,
                    offsetBy: chunkSize,
                    limitedBy: source.endIndex
                ) ?? source.endIndex
            chunks.append(String(source[lowerBound..<upperBound]))
            lowerBound = upperBound
            patternIndex += 1
        }

        return chunks
    }
}

private struct MarkdownStructureCounter: MarkupWalker {
    var headings = 0
    var paragraphs = 0
    var emphasis = 0
    var strong = 0
    var strikethrough = 0
    var inlineCode = 0
    var links = 0
    var blockQuotes = 0
    var orderedLists = 0
    var unorderedLists = 0
    var codeBlocks = 0
    var thematicBreaks = 0
    var tables = 0

    var formattedOrBlockFeatureCount: Int {
        headings
            + emphasis
            + strong
            + strikethrough
            + inlineCode
            + links
            + blockQuotes
            + orderedLists
            + unorderedLists
            + codeBlocks
            + thematicBreaks
            + tables
    }

    mutating func visitHeading(_ heading: Markdown.Heading) {
        headings += 1
        descendInto(heading)
    }

    mutating func visitParagraph(_ paragraph: Markdown.Paragraph) {
        paragraphs += 1
        descendInto(paragraph)
    }

    mutating func visitEmphasis(_ emphasis: Markdown.Emphasis) {
        self.emphasis += 1
        descendInto(emphasis)
    }

    mutating func visitStrong(_ strong: Markdown.Strong) {
        self.strong += 1
        descendInto(strong)
    }

    mutating func visitStrikethrough(
        _ strikethrough: Markdown.Strikethrough
    ) {
        self.strikethrough += 1
        descendInto(strikethrough)
    }

    mutating func visitInlineCode(_ inlineCode: Markdown.InlineCode) {
        self.inlineCode += 1
    }

    mutating func visitLink(_ link: Markdown.Link) {
        links += 1
        descendInto(link)
    }

    mutating func visitBlockQuote(_ blockQuote: Markdown.BlockQuote) {
        blockQuotes += 1
        descendInto(blockQuote)
    }

    mutating func visitOrderedList(_ orderedList: Markdown.OrderedList) {
        orderedLists += 1
        descendInto(orderedList)
    }

    mutating func visitUnorderedList(_ unorderedList: Markdown.UnorderedList) {
        unorderedLists += 1
        descendInto(unorderedList)
    }

    mutating func visitCodeBlock(_ codeBlock: Markdown.CodeBlock) {
        codeBlocks += 1
    }

    mutating func visitThematicBreak(
        _ thematicBreak: Markdown.ThematicBreak
    ) {
        thematicBreaks += 1
    }

    mutating func visitTable(_ table: Markdown.Table) {
        tables += 1
        descendInto(table)
    }
}
