// UIKit-hosted coverage runs on iOS; the macOS text host has its own
// AppKit implementation exercised by the perf lab.
#if os(iOS)
import Foundation
import Markdown
import Testing
import UIKit

@testable import mai

struct ChatMarkdownTests {
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
            [unsafe](javascript:alert%281%29) remain valid Markdown.
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
    func frequentCumulativeAndReplacementUpdatesPreserveSource() {
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
        var displayedSource = ""

        for chunk in chunks {
            displayedSource.append(contentsOf: chunk)
            let analysis = ChatMarkdownDocumentAnalyzer.analyze(
                source: displayedSource
            )

            #expect(analysis.requiresPlainTextFallback == false)
        }

        let replacement = """
            The provider replaced its draft with a complete plain-text answer.
            A second line confirms that newline content remains available.
            """
        displayedSource = replacement
        let replacementAnalysis = ChatMarkdownDocumentAnalyzer.analyze(
            source: displayedSource
        )

        #expect(chunks.count > 40)
        #expect(displayedSource == replacement)
        #expect(displayedSource.hasPrefix(completeSource) == false)
        #expect(replacementAnalysis == ChatMarkdownDocumentAnalysis())
    }

    @Test
    func settledMessageSegmentationPreservesSourceAndSemanticBoundaries() throws {
        let prose = String(
            repeating: "A selectable paragraph with **bold text** and Unicode 👩🏽‍💻.\n\n",
            count: 45
        )
        let source =
            prose + #"""
                ```swift
                let state = "ready"
                ```

                | Feature | State |
                | :--- | :---: |
                | Selection | enabled |

                """# + prose

        let segments = try #require(ChatMarkdownSegmenter.segments(of: source))

        #expect(segments.map(\.source).joined() == source)
        #expect(segments.map(\.kind) == [.prose, .rich, .rich, .prose])
        #expect(segments[1].source.contains("```swift"))
        #expect(segments[2].source.contains("| Feature | State |"))
    }

    @Test
    func consecutiveProseStaysSelectableAcrossThematicBreak() throws {
        let padding = String(
            repeating: "A long prose paragraph.\n\n",
            count: 100
        )
        let source = padding + "> Quoted prose.\n\n---\n\nFinal paragraph."
        let segments = try #require(ChatMarkdownSegmenter.segments(of: source))

        #expect(segments == [ChatMarkdownSegment(kind: .prose, source: source)])
    }

    @Test
    func longProseStaysInOneSelectableSegment() throws {
        let paragraph = String(repeating: "Selectable Markdown prose. ", count: 16)
        let source = Array(repeating: paragraph, count: 40)
            .joined(separator: "\n\n")

        let segments = try #require(ChatMarkdownSegmenter.segments(of: source))

        #expect(segments == [ChatMarkdownSegment(kind: .prose, source: source)])
    }

    @Test
    func referenceDefinitionsStayOnTheExistingRenderer() {
        let padding = String(repeating: "Long prose paragraph.\n\n", count: 220)
        let referenceSource = padding + "[Documentation][docs]\n\n[docs]: /guide"

        #expect(ChatMarkdownSegmenter.shouldOptimize(referenceSource))
        #expect(ChatMarkdownSegmenter.segments(of: referenceSource) == nil)
    }

    @Test
    func unsupportedMathSyntaxRemainsSelectableLiteralProse() throws {
        let source = "The result is $x + y$.\n\n\\[z = 2\\]"
        let segments = try #require(ChatMarkdownSegmenter.segments(of: source))

        #expect(segments == [ChatMarkdownSegment(kind: .prose, source: source)])
    }

    @Test
    func textOptimizationPolicyCoversHistoryAndLongUserMessages() {
        let longSource = String(
            repeating: "x",
            count: ChatMarkdownSegmenter.optimizationThreshold + 1
        )
        let shortSource = String(
            repeating: "x",
            count: ChatMarkdownSegmenter.optimizationThreshold
        )

        #expect(
            ChatTextOptimizationPolicy.shouldOptimize(
                role: MaidMessageRole.assistant.rawValue,
                messageTurnID: nil,
                streamingTurnID: nil,
                source: shortSource
            )
        )
        #expect(
            ChatTextOptimizationPolicy.shouldOptimize(
                role: MaidMessageRole.assistant.rawValue,
                messageTurnID: "past-turn",
                streamingTurnID: "running-turn",
                source: longSource
            )
        )
        #expect(
            ChatTextOptimizationPolicy.shouldOptimize(
                role: MaidMessageRole.assistant.rawValue,
                messageTurnID: "running-turn",
                streamingTurnID: "running-turn",
                source: longSource
            ) == false
        )
        #expect(
            ChatTextOptimizationPolicy.shouldOptimize(
                role: MaidMessageRole.user.rawValue,
                messageTurnID: nil,
                streamingTurnID: nil,
                source: longSource
            )
        )
        #expect(
            ChatTextOptimizationPolicy.shouldOptimize(
                role: MaidMessageRole.user.rawValue,
                messageTurnID: nil,
                streamingTurnID: nil,
                source: shortSource
            ) == false
        )
    }

    @Test
    func messageRenderPlannerActivatesTheNativePaths() {
        let source = String(
            repeating: "A settled paragraph with **Markdown**.\n\n",
            count: 80
        )
        let cache = ChatMarkdownSegmentCache()

        let restoredAssistant = ChatMessageTextPlanner.plan(
            messageID: "restored-assistant",
            role: MaidMessageRole.assistant.rawValue,
            messageTurnID: nil,
            streamingTurnID: nil,
            source: source,
            segmentCache: cache
        )
        let reopenedAssistant = ChatMessageTextPlanner.plan(
            messageID: "restored-assistant",
            role: MaidMessageRole.assistant.rawValue,
            messageTurnID: nil,
            streamingTurnID: nil,
            source: source,
            segmentCache: cache
        )
        let longUser = ChatMessageTextPlanner.plan(
            messageID: "long-user",
            role: MaidMessageRole.user.rawValue,
            messageTurnID: nil,
            streamingTurnID: nil,
            source: source,
            segmentCache: cache
        )
        let streamingAssistant = ChatMessageTextPlanner.plan(
            messageID: "streaming-assistant",
            role: MaidMessageRole.assistant.rawValue,
            messageTurnID: "running-turn",
            streamingTurnID: "running-turn",
            source: source,
            segmentCache: cache
        )

        guard case .segmented(let segments) = restoredAssistant else {
            Issue.record("Restored assistant message did not use native segments")
            return
        }
        #expect(segments.map(\.kind) == [.prose])
        #expect(reopenedAssistant == restoredAssistant)

        let documentWideFallback = ChatMessageTextPlanner.plan(
            messageID: "reference-assistant",
            role: MaidMessageRole.assistant.rawValue,
            messageTurnID: nil,
            streamingTurnID: nil,
            source: "[Documentation][docs]\n\n[docs]: /guide",
            segmentCache: cache
        )
        #expect(documentWideFallback == .existingRenderer)

        guard case .segmented(let userSegments) = longUser else {
            Issue.record("Long user message did not use native Markdown segments")
            return
        }
        #expect(userSegments.map(\.kind) == [.prose])
        #expect(streamingAssistant == .existingRenderer)
    }

    @Test
    func primeRequestsCoverExactlyTheMessagesThePlannerWillSegment() {
        let longSource = String(
            repeating: "A settled paragraph with **Markdown**.\n\n",
            count: 80
        )
        let timeline = [
            messageEntry(id: "prompt", role: .user, text: "go", turnID: "finished-turn"),
            messageEntry(
                id: "folded-assistant",
                role: .assistant,
                text: longSource,
                turnID: "finished-turn"
            ),
            messageEntry(
                id: "final-assistant",
                role: .assistant,
                text: longSource,
                turnID: "finished-turn"
            ),
            messageEntry(id: "long-user", role: .user, text: longSource, turnID: "running-turn"),
            messageEntry(
                id: "streaming-assistant",
                role: .assistant,
                text: longSource,
                turnID: "running-turn"
            ),
            messageEntry(
                id: "short-assistant",
                role: .assistant,
                text: "Done.",
                turnID: "running-turn"
            ),
        ]

        let requests = ChatMarkdownSegmentCache.primeRequests(
            rows: ChatTimelineLayout.rows(
                timeline: timeline,
                streamingTurnID: "running-turn",
                latestTurn: nil,
                expandedSectionIDs: []
            ),
            streamingTurnID: "running-turn"
        )

        // The folded intermediate message is invisible at first render; the
        // streaming and short messages never consult the cache.
        #expect(requests.map(\.messageID) == ["final-assistant", "long-user"])
        #expect(requests.first?.source == longSource)
    }

    @Test
    func cancelledPrimingCanResume() async {
        let source = String(
            repeating: "A settled paragraph with **Markdown**.\n\n",
            count: 80
        )
        let requests = (0..<8).map {
            ChatMarkdownPrimeRequest(messageID: "message-\($0)", source: source)
        }
        let cache = ChatMarkdownSegmentCache()

        let cancelled = Task { await cache.prime(requests: requests) }
        cancelled.cancel()
        await cancelled.value

        await cache.prime(requests: requests)

        for request in requests {
            #expect(
                cache.contains(
                    messageID: request.messageID,
                    source: request.source
                )
            )
        }
    }

    @Test
    func primingSettledHistoryMakesFirstRenderACacheHit() async {
        let source = String(
            repeating: "A settled paragraph with **Markdown**.\n\n",
            count: 80
        )
        let cache = ChatMarkdownSegmentCache()

        await cache.prime(requests: [
            ChatMarkdownPrimeRequest(messageID: "settled-assistant", source: source)
        ])

        let plan = ChatMessageTextPlanner.plan(
            messageID: "settled-assistant",
            role: MaidMessageRole.assistant.rawValue,
            messageTurnID: nil,
            streamingTurnID: nil,
            source: source,
            segmentCache: cache
        )
        guard case .segmented(let segments) = plan else {
            Issue.record("Primed assistant message did not use native segments")
            return
        }
        #expect(segments.map(\.kind) == [.prose])
    }

    @Test
    func primingRetainsARealisticallyLargeWorkingSet() async {
        let source = String(
            repeating: "A settled paragraph with **Markdown**.\n\n",
            count: 80
        )
        let requests = (0..<258).map {
            ChatMarkdownPrimeRequest(messageID: "message-\($0)", source: source)
        }
        let cache = ChatMarkdownSegmentCache()

        await cache.prime(requests: requests)

        // The thread-owned cache retains the loaded transcript without
        // forcing its first render to reparse old entries.
        #expect(cache.entryCount == requests.count)
    }

    private func messageEntry(
        id: String,
        role: MaidMessageRole,
        text: String,
        turnID: String? = nil
    ) -> TimelineEntry {
        TimelineEntry(
            approval: nil,
            item: nil,
            kind: MaidTimelineEntryKind.message.rawValue,
            message: Message(
                attachments: nil,
                createdAt: Date(timeIntervalSince1970: 0),
                id: id,
                role: role.rawValue,
                text: text,
                turnID: turnID,
                updatedAt: Date(timeIntervalSince1970: 0)
            )
        )
    }

    @Test
    func proseRendererBuildsStyledTextWithoutMarkdownDelimiters() {
        let rendered = ChatProseMarkdownRenderer.attributedString(
            from: "# Heading\n\nA **bold** line with `code`.\n\n- First\n- Second"
        )

        #expect(rendered.string.contains("Heading"))
        #expect(rendered.string.contains("bold"))
        #expect(rendered.string.contains("•  First"))
        #expect(rendered.string.contains("**") == false)
        #expect(rendered.length > 0)
        #expect(rendered.attribute(.font, at: 0, effectiveRange: nil) != nil)
        let headingLevel =
            rendered.attribute(
                .accessibilityTextHeadingLevel,
                at: 0,
                effectiveRange: nil
            ) as? NSNumber
        #expect(headingLevel?.intValue == 1)
    }

    @Test
    func proseRendererAddsOnlySupportedNativeLinks() throws {
        let rendered = ChatProseMarkdownRenderer.attributedString(
            from:
                "[Web](https://example.com/docs), [relative](/docs), [custom](javascript:alert%281%29)."
        )
        let web = (rendered.string as NSString).range(of: "Web")
        let relative = (rendered.string as NSString).range(of: "relative")
        let custom = (rendered.string as NSString).range(of: "custom")

        #expect(
            rendered.attribute(
                .link,
                at: web.location,
                effectiveRange: nil
            ) as? URL == URL(string: "https://example.com/docs")
        )
        #expect(
            rendered.attribute(
                .link,
                at: relative.location,
                effectiveRange: nil
            ) == nil
        )
        #expect(
            rendered.attribute(
                .link,
                at: custom.location,
                effectiveRange: nil
            ) == nil
        )
    }

    @Test
    func quoteDecorationIsNotPartOfSelectableOrCopiedText() {
        let rendered = ChatProseMarkdownRenderer.attributedString(
            from: "Before.\n\n> Quoted text.\n\nAfter."
        )

        #expect(rendered.string == "Before.\n\nQuoted text.\n\nAfter.")
        #expect(rendered.string.contains(">") == false)
        #expect(rendered.string.contains("▏") == false)
        let quoteRange = (rendered.string as NSString).range(of: "Quoted text.")
        #expect(
            rendered.attribute(
                .chatQuoteBarOffsets,
                at: quoteRange.location,
                effectiveRange: nil
            ) != nil
        )
    }

    @Test
    func prelaidOutProseHostRemainsSelectable() throws {
        let source = String(
            repeating: "Selectable prose wraps across the chat width. ",
            count: 120
        )
        let store = ChatTextLayoutStore()
        let layout = store.layout(
            id: "selection-test",
            source: source,
            style: .markdownProse,
            width: 358
        )
        let host = ChatSelectableTextHostView(
            frame: CGRect(x: 0, y: 0, width: 358, height: layout.height)
        )
        host.update(
            layoutID: "selection-test",
            source: source,
            style: .markdownProse,
            layoutStore: store
        )
        host.layoutIfNeeded()

        let textView = try #require(host.subviews.first as? UITextView)
        textView.selectedRange = NSRange(location: 0, length: 10)

        #expect(textView.isSelectable)
        #expect(textView.isEditable == false)
        #expect(textView.isScrollEnabled == false)
        #expect(textView.selectedRange == NSRange(location: 0, length: 10))
        #expect(
            textView.text
                == source.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    @Test
    func growingProseRunPreservesAnExistingSelection() throws {
        let firstSource = "First paragraph.\n\nSecond paragraph."
        let secondSource = firstSource + "\n\nThird paragraph."
        let store = ChatTextLayoutStore()
        let firstLayout = store.layout(
            id: "growing-selection-test",
            source: firstSource,
            style: .markdownProse,
            width: 358
        )
        let host = ChatSelectableTextHostView(
            frame: CGRect(
                x: 0,
                y: 0,
                width: 358,
                height: firstLayout.height
            )
        )
        host.update(
            layoutID: "growing-selection-test",
            source: firstSource,
            style: .markdownProse,
            layoutStore: store
        )
        host.layoutIfNeeded()
        let firstTextView = try #require(
            host.subviews.first as? UITextView
        )
        let selection = NSRange(location: 0, length: 15)
        firstTextView.selectedRange = selection

        let secondLayout = store.layout(
            id: "growing-selection-test",
            source: secondSource,
            style: .markdownProse,
            width: 358
        )
        host.frame.size.height = secondLayout.height
        host.update(
            layoutID: "growing-selection-test",
            source: secondSource,
            style: .markdownProse,
            layoutStore: store
        )
        host.layoutIfNeeded()
        let secondTextView = try #require(
            host.subviews.first as? UITextView
        )

        #expect(secondTextView.selectedRange == selection)
    }

    @Test
    func selectableTextViewsSupportRangeSelectionAndLinks() {
        let textView = UITextView(usingTextLayoutManager: false)
        ChatSelectableTextViewConfiguration.apply(to: textView)

        #expect(textView.isSelectable)
        #expect(!textView.isEditable)
        #expect(!textView.isScrollEnabled)
        #expect(textView.linkTextAttributes[.underlineStyle] != nil)
    }

    @Test
    func plainUserTextPreservesMarkdownCharactersAndSelection() throws {
        let source = "# Literal heading\n\n**not bold** and `not code`"
        let store = ChatTextLayoutStore()
        let host = ChatSelectableTextHostView(
            frame: CGRect(x: 0, y: 0, width: 330, height: 200)
        )
        host.update(
            layoutID: "plain-user-selection-test",
            source: source,
            style: .plain,
            layoutStore: store
        )
        host.layoutIfNeeded()

        let textView = try #require(host.subviews.first as? UITextView)
        textView.selectedRange = NSRange(location: 0, length: 9)

        #expect(textView.text == source)
        #expect(textView.selectedRange == NSRange(location: 0, length: 9))
        #expect(textView.isSelectable)
        #expect(textView.isEditable == false)
    }

    @Test
    func recycledProseHostReusesItsSelectableTextView() throws {
        let source = String(
            repeating: "A recycled row keeps its prepared native text. ",
            count: 120
        )
        let store = ChatTextLayoutStore()
        let layout = store.layout(
            id: "recycled-selection-test",
            source: source,
            style: .markdownProse,
            width: 358
        )
        let frame = CGRect(
            x: 0,
            y: 0,
            width: 358,
            height: layout.height
        )

        let firstHost = ChatSelectableTextHostView(frame: frame)
        firstHost.update(
            layoutID: "recycled-selection-test",
            source: source,
            style: .markdownProse,
            layoutStore: store
        )
        firstHost.layoutIfNeeded()
        let firstTextView = try #require(
            firstHost.subviews.first as? UITextView
        )
        firstTextView.selectedRange = NSRange(location: 4, length: 12)
        firstHost.dismantle()

        let secondHost = ChatSelectableTextHostView(frame: frame)
        secondHost.update(
            layoutID: "recycled-selection-test",
            source: source,
            style: .markdownProse,
            layoutStore: store
        )
        secondHost.layoutIfNeeded()
        let secondTextView = try #require(
            secondHost.subviews.first as? UITextView
        )

        #expect(secondTextView === firstTextView)
        #expect(secondTextView.selectedRange == NSRange(location: 4, length: 12))
        #expect(secondTextView.isSelectable)
        #expect(secondTextView.isEditable == false)
    }

    @Test
    func recycledTextViewCanPresentAnotherPreparedRow() throws {
        let store = ChatTextLayoutStore()
        let firstSource = String(repeating: "First prepared row. ", count: 80)
        let secondSource = String(repeating: "Second prepared row. ", count: 100)
        let firstLayout = store.layout(
            id: "first-recycled-row",
            source: firstSource,
            style: .markdownProse,
            width: 358
        )
        let firstHost = ChatSelectableTextHostView(
            frame: CGRect(x: 0, y: 0, width: 358, height: firstLayout.height)
        )
        firstHost.update(
            layoutID: "first-recycled-row",
            source: firstSource,
            style: .markdownProse,
            layoutStore: store
        )
        firstHost.layoutIfNeeded()
        let firstTextView = try #require(firstHost.subviews.first as? UITextView)
        firstTextView.selectedRange = NSRange(location: 2, length: 8)
        firstHost.dismantle()

        let secondLayout = store.layout(
            id: "second-recycled-row",
            source: secondSource,
            style: .markdownProse,
            width: 358
        )
        let secondHost = ChatSelectableTextHostView(
            frame: CGRect(x: 0, y: 0, width: 358, height: secondLayout.height)
        )
        secondHost.update(
            layoutID: "second-recycled-row",
            source: secondSource,
            style: .markdownProse,
            layoutStore: store
        )
        secondHost.layoutIfNeeded()
        let secondTextView = try #require(
            secondHost.subviews.first as? UITextView
        )

        #expect(secondTextView === firstTextView)
        #expect(
            secondTextView.text
                == secondSource.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        #expect(secondTextView.selectedRange == NSRange(location: 0, length: 0))
    }

    @Test
    func presentationKeepsStreamingAndDiagnosticsIndependent() {
        let presentation = ChatMarkdownPresentation(
            isStreaming: true,
            showsDiagnostics: true
        )

        #expect(presentation.isStreaming)
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

#endif
