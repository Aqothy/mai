import Markdown
import MarkdownView
import XCTest

@testable import mai

#if os(iOS)
    import SwiftUI
    import UIKit
#endif

nonisolated final class ChatMarkdownPerformanceTests: XCTestCase {
    func testRepresentativeLongResponseParseAndSafetyAnalysisPerformance() {
        let source = makeRepresentativeLongResponse(sectionCount: 24)
        var analysis = ChatMarkdownDocumentAnalysis()

        measure(metrics: [XCTClockMetric()]) {
            let document = Markdown.Document(parsing: source)
            analysis = ChatMarkdownDocumentAnalyzer.analyze(document)
        }

        XCTAssertGreaterThan(source.count, 10_000)
        XCTAssertFalse(analysis.requiresPlainTextFallback)
    }

    func testLargeCodeListTableParseAndSafetyAnalysisPerformance() {
        let source = makeLargeCodeListTableResponse(sectionCount: 80)
        var analysis = ChatMarkdownDocumentAnalysis()

        measure(metrics: [XCTClockMetric()]) {
            let document = Markdown.Document(parsing: source)
            analysis = ChatMarkdownDocumentAnalyzer.analyze(document)
        }

        XCTAssertGreaterThan(source.count, 40_000)
        XCTAssertFalse(analysis.requiresPlainTextFallback)
    }

    /// Measures stable `StreamingMarkdownSource` updates followed by a full
    /// swift-markdown parse and safety walk for every cumulative prefix. It
    /// does not measure MarkdownView's private incremental parser.
    func testCumulativePrefixSourceUpdateAndFullAnalysisPerformance() {
        let source = makeRepresentativeLongResponse(sectionCount: 10)
        let cumulativePrefixes = makeCumulativePrefixes(
            source: source,
            updateCount: 120
        )
        let streamingSource = StreamingMarkdownSource()
        let stableSourceIdentity = ObjectIdentifier(streamingSource)
        var analyzedUpdateCount = 0
        var finalAnalysis = ChatMarkdownDocumentAnalysis()

        measure(metrics: [XCTClockMetric()]) {
            var measuredAnalysis = ChatMarkdownDocumentAnalysis()
            var measuredUpdateCount = 0

            for prefix in cumulativePrefixes {
                streamingSource.text = prefix
                let document = Markdown.Document(
                    parsing: streamingSource.text
                )
                measuredAnalysis = ChatMarkdownDocumentAnalyzer.analyze(
                    document
                )
                measuredUpdateCount += 1
            }

            analyzedUpdateCount = measuredUpdateCount
            finalAnalysis = measuredAnalysis
        }
        streamingSource.finishStreaming()

        XCTAssertEqual(ObjectIdentifier(streamingSource), stableSourceIdentity)
        XCTAssertEqual(streamingSource.text, source)
        XCTAssertEqual(analyzedUpdateCount, cumulativePrefixes.count)
        XCTAssertEqual(cumulativePrefixes.last, source)
        XCTAssertFalse(finalAnalysis.requiresPlainTextFallback)
    }

    #if os(iOS)
        /// Mounts the production wrapper so its `onChange` handlers and
        /// StreamingMarkdownReader subscription are exercised by cumulative
        /// prefixes, a non-prefix replacement, and the final static parse.
        @MainActor
        func testHostedStreamingMessageLifecycle() {
            let state = ChatMarkdownHostingState()
            let hostingController = UIHostingController(
                rootView: ChatMarkdownHostingHarness(state: state)
            )
            let window = UIWindow(
                frame: CGRect(x: 0, y: 0, width: 390, height: 844)
            )
            window.rootViewController = hostingController
            window.isHidden = false
            defer {
                window.isHidden = true
            }

            settleLayout(of: hostingController)
            let initialSize = hostingController.sizeThatFits(
                in: CGSize(width: 390, height: 50_000)
            )

            for source in [
                "## Streamed response\n\nA **par",
                "## Streamed response\n\nA **partial** paragraph with `code`.",
                """
                # Replacement

                The provider replaced its draft with a non-prefix update.
                """,
                """
                # Replacement

                The provider replaced its draft with a non-prefix update.

                1. The replacement remains readable.
                2. The final transition performs a complete parse.

                ```swift
                let state = "complete"
                ```
                """,
            ] {
                state.source = source
                settleLayout(of: hostingController)
            }

            state.isStreaming = false
            settleLayout(of: hostingController)
            let finalSize = hostingController.sizeThatFits(
                in: CGSize(width: 390, height: 50_000)
            )

            XCTAssertGreaterThan(initialSize.width, 0)
            XCTAssertGreaterThan(finalSize.height, initialSize.height)
            XCTAssertFalse(state.isStreaming)
        }

        /// Measures the public chat rendering seam by constructing a fresh
        /// host and asking SwiftUI to size a mixed Markdown response at a
        /// representative chat width. This includes static parsing, render
        /// model construction, and initial layout. It does not wait for the
        /// asynchronous syntax-highlighting task, measure rasterization, or
        /// exercise MarkdownView's private incremental parser.
        @MainActor
        func testMixedContentMessageHostingAndLayoutPerformance() {
            let source = makeLargeCodeListTableResponse(sectionCount: 12)
            let sizeProposal = CGSize(width: 390, height: 50_000)
            var measuredSize = CGSize.zero

            measure(metrics: [XCTClockMetric()]) {
                autoreleasepool {
                    let messageView = ChatMarkdownMessageView(
                        messageID: "layout-performance-message",
                        source: source,
                        presentation: ChatMarkdownPresentation(
                            isStreaming: false
                        )
                    )
                    let hostingController = UIHostingController(
                        rootView: messageView
                    )
                    measuredSize = hostingController.sizeThatFits(
                        in: sizeProposal
                    )
                }
            }

            XCTAssertGreaterThan(source.count, 5_000)
            XCTAssertGreaterThan(measuredSize.width, 0)
            XCTAssertGreaterThan(measuredSize.height, 0)
            // `sizeThatFits` may round outward by one physical pixel. Keep
            // detecting meaningful overflow without making the test depend
            // on the simulator's display scale.
            XCTAssertLessThanOrEqual(
                measuredSize.width,
                sizeProposal.width + 1
            )
        }

        /// Records the accepted worst case: one row mounts and lays out a
        /// complete 10k-word response synchronously.
        @MainActor
        func testGiantPlainTextSingleRowHostingAndLayoutPerformance() {
            let source = makeGiantPlainText(wordCount: 10_000)
            let sizeProposal = CGSize(width: 390, height: 1_000_000)
            let layoutsPerMeasurement = 64
            var measuredSize = CGSize.zero

            measure(metrics: [XCTClockMetric()]) {
                for _ in 0..<layoutsPerMeasurement {
                    autoreleasepool {
                        let hostingController = UIHostingController(
                            rootView: Text(source)
                                .textSelection(.enabled)
                                .frame(width: 390, alignment: .leading)
                        )
                        measuredSize = hostingController.sizeThatFits(
                            in: sizeProposal
                        )
                    }
                }
            }

            XCTAssertGreaterThan(source.count, 50_000)
            XCTAssertGreaterThan(measuredSize.height, 0)
        }

        @MainActor
        private func settleLayout(
            of hostingController: UIHostingController<ChatMarkdownHostingHarness>
        ) {
            hostingController.view.setNeedsLayout()
            hostingController.view.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            hostingController.view.layoutIfNeeded()
        }
    #endif

    private func makeRepresentativeLongResponse(sectionCount: Int) -> String {
        var sections: [String] = [
            """
            # Rendering a streamed assistant response

            This representative response combines prose, decisions, code, and
            status details that commonly appear in a long AI conversation.
            Unicode remains part of the workload: café, 日本語, and 👩🏽‍💻.
            """
        ]
        sections.reserveCapacity(sectionCount + 2)

        for sectionIndex in 1...sectionCount {
            sections.append(
                """
                ## Decision \(sectionIndex)

                The renderer keeps message \(sectionIndex) independent from
                surrounding transcript rows. This paragraph is intentionally
                long enough to wrap at normal chat widths while remaining
                selectable and useful with larger Dynamic Type settings.

                1. Preserve the source exactly.
                2. Analyze unsupported syntax before choosing a presentation.
                   - Keep historical messages stable.
                   - Limit frequent work to the active streamed message.
                3. Finish with the same source used for the stored response.

                ```swift
                struct RenderDecision\(sectionIndex): Sendable {
                    let messageID: String
                    let revision = \(sectionIndex)
                    let isStreaming: Bool
                }
                ```

                > Checkpoint \(sectionIndex) confirms that prose after a code
                > block remains part of the same assistant response.
                """
            )
        }

        sections.append(
            """
            ## Conclusion

            The final marker makes complete parsing easy to distinguish from
            an unfinished streamed prefix.
            """
        )
        return sections.joined(separator: "\n\n")
    }

    private func makeLargeCodeListTableResponse(sectionCount: Int) -> String {
        var sections: [String] = [
            """
            # Large code, list, and table response

            This fixture deliberately repeats the expensive practical shapes
            used by an assistant when explaining a substantial implementation.
            """
        ]
        sections.reserveCapacity(sectionCount + 2)

        for sectionIndex in 1...sectionCount {
            sections.append(
                #"""
                ## Module \#(sectionIndex)

                - Validate input for module \#(sectionIndex).
                  - Preserve whitespace and delimiter-like source.
                  - Keep code horizontally readable.
                - Produce a deterministic result.
                - Record enough context for diagnostics.

                ```swift
                actor Module\#(sectionIndex)Store {
                    private var values: [String: String] = [:]

                    func insert(_ value: String, for key: String) {
                        values[key] = value
                    }

                    func value(for key: String) -> String? {
                        values[key]
                    }
                }
                ```

                ```json
                {
                  "module": \#(sectionIndex),
                  "state": "ready",
                  "features": ["code", "lists", "tables"],
                  "message": "literal **delimiters** remain code"
                }
                ```

                | Module | Parsing | Streaming | Selection | Notes |
                | :--- | :---: | :---: | :---: | :--- |
                | \#(sectionIndex) | ready | prefix-safe | enabled | deterministic fixture |
                | \#(sectionIndex).next | ready | coalesced | enabled | repeated workload |
                """#
            )
        }

        sections.append(
            """
            ---

            End of the large mixed-content fixture.
            """
        )
        return sections.joined(separator: "\n\n")
    }

    private func makeCumulativePrefixes(
        source: String,
        updateCount: Int
    ) -> [String] {
        let characters = Array(source)
        let chunkSize = max(
            1,
            (characters.count + updateCount - 1) / updateCount
        )
        var prefixes: [String] = []
        prefixes.reserveCapacity(updateCount)
        var cumulativeSource = ""

        for lowerBound in stride(
            from: 0,
            to: characters.count,
            by: chunkSize
        ) {
            let upperBound = min(lowerBound + chunkSize, characters.count)
            cumulativeSource.append(
                contentsOf: characters[lowerBound..<upperBound]
            )
            prefixes.append(cumulativeSource)
        }

        return prefixes
    }

    private func makeGiantPlainText(wordCount: Int) -> String {
        let vocabulary = [
            "timeline", "renderer", "layout", "scrolling", "message",
            "virtualization", "streaming", "throughput", "latency", "viewport",
        ]
        var words: [String] = []
        words.reserveCapacity(wordCount)
        for index in 0..<wordCount {
            words.append(vocabulary[index % vocabulary.count])
        }
        return words.joined(separator: " ")
    }
}

#if os(iOS)
    @MainActor
    @Observable
    private final class ChatMarkdownHostingState {
        var source = "## Streamed response\n\nA"
        var isStreaming = true
    }

    private struct ChatMarkdownHostingHarness: View {
        let state: ChatMarkdownHostingState

        var body: some View {
            ChatMarkdownMessageView(
                messageID: "hosted-streaming-lifecycle",
                source: state.source,
                presentation: ChatMarkdownPresentation(
                    isStreaming: state.isStreaming,
                    streamingThrottle: .zero
                )
            )
            .frame(width: 390, alignment: .leading)
        }
    }
#endif
