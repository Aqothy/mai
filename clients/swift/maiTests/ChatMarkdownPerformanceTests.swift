// UIKit-hosted coverage runs on iOS; the macOS text host has its own
// AppKit implementation exercised by the perf lab.
#if os(iOS)
import Markdown
import SwiftUI
import UIKit
import XCTest

@testable import mai

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

    /// Measures the production prose prefilter against 1,000 deterministic
    /// variable-height messages. The equality check keeps its behavior tied
    /// to the full swift-markdown implementation measured below.
    @MainActor
    func testSettledMessageSegmentationFastPathPerformance() {
        let sources = makeSettledSegmentationSources()
        let semanticResults = sources.map {
            ChatMarkdownSegmenter.segmentsUsingFullParser(of: $0)
        }
        XCTAssertEqual(
            sources.map { ChatMarkdownSegmenter.segments(of: $0) },
            semanticResults
        )
        let expectedSegmentCount = semanticResults.compactMap { $0 }
            .reduce(0) { $0 + $1.count }
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        var segmentCount = 0

        measure(metrics: [XCTClockMetric()], options: options) {
            segmentCount = sources.reduce(into: 0) { count, source in
                count += ChatMarkdownSegmenter.segments(of: source)?.count ?? 0
            }
        }

        XCTAssertEqual(segmentCount, expectedSegmentCount)
    }

    /// Baseline for the benchmark above. It runs the previous behavior on the
    /// exact same sources: every message is parsed and inspected semantically.
    @MainActor
    func testSettledMessageSegmentationFullParserPerformance() {
        let sources = makeSettledSegmentationSources()
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        var segmentCount = 0

        measure(metrics: [XCTClockMetric()], options: options) {
            segmentCount = sources.reduce(into: 0) { count, source in
                count +=
                    ChatMarkdownSegmenter.segmentsUsingFullParser(
                        of: source
                    )?.count ?? 0
            }
        }

        XCTAssertGreaterThan(segmentCount, sources.count)
    }

    /// Measures a full swift-markdown parse and safety walk for every
    /// cumulative prefix. This is the deliberately expensive full-reparse
    /// baseline for the incremental production benchmark below.
    func testCumulativePrefixSourceUpdateAndFullAnalysisPerformance() {
        let source = makeRepresentativeLongResponse(sectionCount: 10)
        let cumulativePrefixes = makeCumulativePrefixes(
            source: source,
            updateCount: 120
        )
        var analyzedUpdateCount = 0
        var finalAnalysis = ChatMarkdownDocumentAnalysis()
        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(metrics: [XCTClockMetric()], options: options) {
            var measuredAnalysis = ChatMarkdownDocumentAnalysis()
            var measuredUpdateCount = 0

            for prefix in cumulativePrefixes {
                let document = Markdown.Document(parsing: prefix)
                measuredAnalysis = ChatMarkdownDocumentAnalyzer.analyze(
                    document
                )
                measuredUpdateCount += 1
            }

            analyzedUpdateCount = measuredUpdateCount
            finalAnalysis = measuredAnalysis
        }

        XCTAssertEqual(analyzedUpdateCount, cumulativePrefixes.count)
        XCTAssertEqual(cumulativePrefixes.last, source)
        XCTAssertFalse(finalAnalysis.requiresPlainTextFallback)
    }

    /// Measures repair plus the production stable-prefix/active-tail parser.
    /// Each measurement starts with a fresh planner and consumes the same
    /// cumulative source snapshots used by the hosted comparison below.
    func testStreamingRepairAndRenderPlanPerformance() {
        let source = makeRepresentativeLongResponse(sectionCount: 10)
        let cumulativePrefixes = makeCumulativePrefixes(
            source: source,
            updateCount: 120
        )
        var finalPlan = ChatMarkdownRenderPlan(blocks: [])
        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(
            metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()],
            options: options
        ) {
            var planner = ChatIncrementalMarkdownRenderPlanner()
            for prefix in cumulativePrefixes {
                finalPlan =
                    planner.snapshot(
                        source: prefix,
                        sourceIsAppendOnly: true
                    ).plan
            }
        }

        XCTAssertFalse(finalPlan.blocks.isEmpty)
    }

    /// Baseline for the benchmark below: the previous settle path, where
    /// every settled block re-coalesced the entire stable prefix into one
    /// prose run — O(total prose) per settle, O(n²) over a long message.
    @MainActor
    func testEssayScaleStreamingFullRecoalescingBaselinePerformance() {
        let source = MockChatMessage.essay(wordCount: 10_000)
        let cumulativePrefixes = makeCumulativePrefixes(
            source: source,
            updateCount: 240
        )
        var finalPlan = ChatMarkdownRenderPlan(blocks: [])
        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric()], options: options) {
            var planner = FullRecoalescingStreamingPlannerBaseline()
            for prefix in cumulativePrefixes {
                finalPlan = planner.snapshot(source: prefix)
            }
        }

        XCTAssertGreaterThan(source.utf8.count, 50_000)
        XCTAssertFalse(finalPlan.blocks.isEmpty)
    }

    /// The production path at essay scale: stable prose runs freeze at the
    /// chunk limit, so a settle touches at most one bounded trailing run.
    @MainActor
    func testEssayScaleStreamingChunkedPlannerPerformance() {
        let source = MockChatMessage.essay(wordCount: 10_000)
        let cumulativePrefixes = makeCumulativePrefixes(
            source: source,
            updateCount: 240
        )
        var finalSnapshot: ChatStreamingMarkdownSnapshot?
        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric()], options: options) {
            var planner = ChatIncrementalMarkdownRenderPlanner()
            for prefix in cumulativePrefixes {
                finalSnapshot = planner.snapshot(
                    source: prefix,
                    sourceIsAppendOnly: true
                )
            }
        }

        guard let finalSnapshot else {
            return XCTFail("Expected a final snapshot")
        }
        // Chunking is presentation-only: re-coalescing matches a full parse.
        XCTAssertGreaterThan(finalSnapshot.stableBlockCount, 1)
        XCTAssertEqual(
            ChatMarkdownRenderPlan(blocks: finalSnapshot.plan.blocks),
            ChatMarkdownRenderPlanner.plan(from: source)
        )
    }

    /// Mounts the production wrapper through cumulative prefixes, a
    /// non-prefix replacement, and the final native attributed parse.
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
    /// representative chat width. This includes static parsing, native
    /// attributed-string construction, and initial layout. It does not
    /// measure rasterization.
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
                    ),
                    textLayoutStore: ChatTextLayoutStore()
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

    /// Baseline for the former List-remount behavior: the render plan is hot,
    /// but every remount gets a fresh prose layout/native-view store.
    @MainActor
    func testNativeRichBlockFreshStoreRemountBaselinePerformance() {
        let source = makeLargeCodeListTableResponse(sectionCount: 12)
        let messageID = "native-rich-fresh-store-remount-benchmark"
        _ = ChatMarkdownRenderCache.shared.plan(
            messageID: messageID,
            source: source
        )
        let sizeProposal = CGSize(width: 390, height: 100_000)
        var measuredSize = CGSize.zero

        measure(metrics: [XCTClockMetric()]) {
            autoreleasepool {
                let controller = UIHostingController(
                    rootView: ChatMarkdownMessageView(
                        messageID: messageID,
                        source: source,
                        presentation: ChatMarkdownPresentation(
                            isStreaming: false
                        ),
                        textLayoutStore: ChatTextLayoutStore()
                    )
                    .frame(width: 358, alignment: .leading)
                )
                measuredSize = controller.sizeThatFits(in: sizeProposal)
            }
        }

        XCTAssertGreaterThan(measuredSize.height, 0)
    }

    /// Production hot path: List can recreate the SwiftUI row while settled
    /// prose keeps the thread-owned TextKit layouts and reusable native views.
    @MainActor
    func testNativeRichBlockHotRemountPerformance() {
        let source = makeLargeCodeListTableResponse(sectionCount: 12)
        let messageID = "native-rich-remount-benchmark"
        let plan = ChatMarkdownRenderCache.shared.plan(
            messageID: messageID,
            source: source
        )
        let textLayoutStore = ChatTextLayoutStore()
        for (index, block) in plan.blocks.enumerated() {
            guard case .prose(let prose) = block else { continue }
            _ = textLayoutStore.layout(
                id: "\(messageID)-block-\(index)",
                source: prose.source,
                style: .markdownProse,
                width: 358
            )
        }
        let sizeProposal = CGSize(width: 390, height: 100_000)
        var measuredSize = CGSize.zero

        measure(metrics: [XCTClockMetric()]) {
            autoreleasepool {
                let controller = UIHostingController(
                    rootView: ChatMarkdownMessageView(
                        messageID: messageID,
                        source: source,
                        presentation: ChatMarkdownPresentation(
                            isStreaming: false
                        ),
                        textLayoutStore: textLayoutStore
                    )
                    .frame(width: 358, alignment: .leading)
                )
                measuredSize = controller.sizeThatFits(in: sizeProposal)
            }
        }

        XCTAssertGreaterThan(measuredSize.height, 0)
    }

    /// Isolates the retained render-plan cache from SwiftUI layout. This
    /// benchmark answers whether avoiding a repeated swift-markdown parse
    /// is worthwhile independently of row construction.
    func testNativeRichRenderPlanCacheHitPerformance() {
        let source = makeLargeCodeListTableResponse(sectionCount: 12)
        let cache = ChatMarkdownRenderCache()
        _ = cache.plan(messageID: "render-plan-cache-hit", source: source)
        let lookupsPerMeasurement = 1_000
        var blockCount = 0

        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<lookupsPerMeasurement {
                blockCount =
                    cache.plan(
                        messageID: "render-plan-cache-hit",
                        source: source
                    ).blocks.count
            }
        }

        XCTAssertGreaterThan(blockCount, 0)
    }

    /// Cold baseline for the same number of render-plan requests. Every
    /// identity is new, so each request includes swift-markdown parsing.
    func testNativeRichRenderPlanColdPerformance() {
        let source = makeLargeCodeListTableResponse(sectionCount: 12)
        let parsesPerMeasurement = 10
        var blockCount = 0

        measure(metrics: [XCTClockMetric()]) {
            let cache = ChatMarkdownRenderCache()
            for index in 0..<parsesPerMeasurement {
                blockCount =
                    cache.plan(
                        messageID: "render-plan-cold-\(index)",
                        source: source
                    ).blocks.count
            }
        }

        XCTAssertGreaterThan(blockCount, 0)
    }

    /// Measures cache growth for a loaded rich transcript. The cache is
    /// intentionally retained by the measurement block so XCTMemoryMetric
    /// reports the physical-memory delta of the completed entries.
    func testNativeRichRenderPlanCacheMemory() {
        let source = makeLargeCodeListTableResponse(sectionCount: 4)
        let messageCount = 100
        var cache: ChatMarkdownRenderCache?

        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(metrics: [XCTMemoryMetric()], options: options) {
            let measuredCache = ChatMarkdownRenderCache()
            for index in 0..<messageCount {
                _ = measuredCache.plan(
                    messageID: "render-plan-memory-\(index)",
                    source: source + "\n\nMessage \(index)"
                )
            }
            cache = measuredCache
        }

        XCTAssertNotNil(cache)
    }

    /// Cold baseline for a message that has not entered the render-plan
    /// cache yet. Every iteration uses a new identity and includes parsing.
    @MainActor
    func testNativeRichBlockColdMountPerformance() {
        let source = makeLargeCodeListTableResponse(sectionCount: 12)
        let sizeProposal = CGSize(width: 390, height: 100_000)
        var measuredSize = CGSize.zero

        measure(metrics: [XCTClockMetric()]) {
            autoreleasepool {
                let controller = UIHostingController(
                    rootView: ChatMarkdownMessageView(
                        messageID: UUID().uuidString,
                        source: source,
                        presentation: ChatMarkdownPresentation(
                            isStreaming: false
                        ),
                        textLayoutStore: ChatTextLayoutStore()
                    )
                    .frame(width: 358, alignment: .leading)
                )
                measuredSize = controller.sizeThatFits(in: sizeProposal)
            }
        }

        XCTAssertGreaterThan(measuredSize.height, 0)
    }

    /// End-to-end native streaming baseline. It includes source
    /// publication, off-main incremental parsing, SwiftUI updates,
    /// layout, and the final settled render.
    @MainActor
    func testNativeStreamingLifecyclePerformance() {
        let prefixes = makeCumulativePrefixes(
            source: makeRepresentativeLongResponse(sectionCount: 4),
            updateCount: 30
        )
        var finalHeight: CGFloat = 0
        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(
            metrics: [
                XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric(),
            ],
            options: options
        ) {
            autoreleasepool {
                let state = NativeStreamingBenchmarkState()
                let controller = UIHostingController(
                    rootView: NativeStreamingBenchmarkHarness(
                        state: state
                    )
                )
                controller.view.frame = CGRect(
                    x: 0, y: 0, width: 358, height: 844
                )
                let window = UIWindow(
                    frame: CGRect(
                        x: 0, y: 0, width: 358, height: 844
                    )
                )
                window.rootViewController = controller
                window.isHidden = false
                for prefix in prefixes {
                    state.source = prefix
                    pumpStreamingRunLoop(of: controller)
                }
                state.isStreaming = false
                pumpStreamingRunLoop(of: controller, milliseconds: 30)
                finalHeight =
                    controller.sizeThatFits(
                        in: CGSize(width: 358, height: 100_000)
                    ).height
                window.isHidden = true
                window.rootViewController = nil
            }
        }

        XCTAssertGreaterThan(finalHeight, 0)
    }

    /// Keeps a representative boundary-size baseline for the renderer
    /// used by short and actively streaming assistant messages.
    @MainActor
    func testFourKilobyteExistingRendererLayoutPerformance() {
        let source = makeProse(atLeastUTF8Bytes: 4_096)
        var measuredHeight: CGFloat = 0

        measure(metrics: [XCTClockMetric()]) {
            autoreleasepool {
                let controller = UIHostingController(
                    rootView: ChatMarkdownMessageView(
                        messageID: UUID().uuidString,
                        source: source,
                        presentation: ChatMarkdownPresentation(
                            isStreaming: false
                        ),
                        textLayoutStore: ChatTextLayoutStore()
                    )
                    .frame(width: 358, alignment: .leading)
                )
                measuredHeight =
                    controller.sizeThatFits(
                        in: CGSize(
                            width: 358,
                            height: CGFloat.greatestFiniteMagnitude
                        )
                    ).height
            }
        }

        XCTAssertGreaterThanOrEqual(source.utf8.count, 4_096)
        XCTAssertGreaterThan(measuredHeight, 0)
    }

    /// Measures the one-time work production performs away from the main
    /// actor before a boundary-size settled assistant row becomes visible.
    func testFourKilobyteNativeProseColdLayoutPerformance() {
        let source = makeProse(atLeastUTF8Bytes: 4_096)
        var measuredHeight: CGFloat = 0

        measure(metrics: [XCTClockMetric()]) {
            autoreleasepool {
                measuredHeight =
                    ChatTextLayout(
                        source: source,
                        style: .markdownProse,
                        width: 358
                    ).height
            }
        }

        XCTAssertGreaterThanOrEqual(source.utf8.count, 4_096)
        XCTAssertGreaterThan(measuredHeight, 0)
    }

    /// Long prompts are literal text, so they skip Markdown parsing and
    /// use the same pre-laid-out selectable native view.
    func testFourKilobytePlainUserColdLayoutPerformance() {
        let source = makeProse(atLeastUTF8Bytes: 4_096)
        var measuredHeight: CGFloat = 0

        measure(metrics: [XCTClockMetric()]) {
            autoreleasepool {
                measuredHeight =
                    ChatTextLayout(
                        source: source,
                        style: .plain,
                        width: 330
                    ).height
            }
        }

        XCTAssertGreaterThanOrEqual(source.utf8.count, 4_096)
        XCTAssertGreaterThan(measuredHeight, 0)
    }

    /// Models the repeated scrolling hot path: both the glyph layout and
    /// the native view have already been used by this List row.
    @MainActor
    func testFourKilobyteCachedNativeRowAttachmentPerformance() {
        let source = makeProse(atLeastUTF8Bytes: 4_096)
        let store = ChatTextLayoutStore()
        let cached = store.layout(
            id: "four-kilobyte-cached-row",
            source: source,
            style: .markdownProse,
            width: 358
        )
        var attachedTextLength = 0
        let primingHost = ChatSelectableTextHostView(
            frame: CGRect(
                x: 0,
                y: 0,
                width: 358,
                height: cached.height
            )
        )
        primingHost.update(
            layoutID: "four-kilobyte-cached-row",
            source: source,
            style: .markdownProse,
            layoutStore: store
        )
        primingHost.layoutIfNeeded()
        primingHost.dismantle()

        measure(metrics: [XCTClockMetric()]) {
            autoreleasepool {
                let host = ChatSelectableTextHostView(
                    frame: CGRect(
                        x: 0,
                        y: 0,
                        width: 358,
                        height: cached.height
                    )
                )
                host.update(
                    layoutID: "four-kilobyte-cached-row",
                    source: source,
                    style: .markdownProse,
                    layoutStore: store
                )
                host.layoutIfNeeded()
                attachedTextLength =
                    (host.subviews.first as? UITextView)?
                    .attributedText.length ?? 0
                host.dismantle()
            }
        }

        XCTAssertGreaterThan(attachedTextLength, 0)
    }

    /// Guards the trace's worst case: recycling an essay-sized selectable
    /// row must not repeat UITextView's full TextKit attachment work.
    @MainActor
    func testGiantProseRecycledNativeRowAttachmentPerformance() {
        let source = makeGiantPlainText(wordCount: 10_000)
        let store = ChatTextLayoutStore()
        let cached = store.layout(
            id: "giant-recycled-row",
            source: source,
            style: .markdownProse,
            width: 358
        )
        let frame = CGRect(
            x: 0,
            y: 0,
            width: 358,
            height: cached.height
        )
        let primingHost = ChatSelectableTextHostView(frame: frame)
        primingHost.update(
            layoutID: "giant-recycled-row",
            source: source,
            style: .markdownProse,
            layoutStore: store
        )
        primingHost.layoutIfNeeded()
        primingHost.dismantle()
        var attachedTextLength = 0

        measure(metrics: [XCTClockMetric()]) {
            autoreleasepool {
                let host = ChatSelectableTextHostView(frame: frame)
                host.update(
                    layoutID: "giant-recycled-row",
                    source: source,
                    style: .markdownProse,
                    layoutStore: store
                )
                host.layoutIfNeeded()
                attachedTextLength =
                    (host.subviews.first as? UITextView)?
                    .attributedText.length ?? 0
                host.dismantle()
            }
        }

        XCTAssertGreaterThan(source.count, 50_000)
        XCTAssertGreaterThan(attachedTextLength, 0)
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

    /// Measures the one-time Markdown conversion and TextKit layout that
    /// production dispatches off the main thread for settled prose.
    func testSettledProseColdLayoutPerformance() {
        let source = makeGiantPlainText(wordCount: 10_000)
        var measuredHeight: CGFloat = 0

        measure(metrics: [XCTClockMetric()]) {
            autoreleasepool {
                measuredHeight =
                    ChatTextLayout(
                        source: source,
                        style: .markdownProse,
                        width: 358
                    ).height
            }
        }

        XCTAssertGreaterThan(source.count, 50_000)
        XCTAssertGreaterThan(measuredHeight, 0)
    }

    /// Measures the hot path used while List realizes a prose row after
    /// the background warmup has completed: a cache lookup with no parse
    /// or glyph layout.
    @MainActor
    func testSettledProseLayoutCacheHitPerformance() {
        let source = makeGiantPlainText(wordCount: 10_000)
        let store = ChatTextLayoutStore()
        let cached = store.layout(
            id: "cache-performance-message",
            source: source,
            style: .markdownProse,
            width: 358
        )
        let lookupsPerMeasurement = 10_000
        var lastLayout: ChatTextLayout?

        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<lookupsPerMeasurement {
                lastLayout = store.layout(
                    id: "cache-performance-message",
                    source: source,
                    style: .markdownProse,
                    width: 358
                )
            }
        }

        XCTAssertTrue(lastLayout === cached)
    }

    @MainActor
    private func settleLayout<Content: View>(
        of hostingController: UIHostingController<Content>
    ) {
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        hostingController.view.layoutIfNeeded()
    }

    @MainActor
    private func pumpStreamingRunLoop<Content: View>(
        of hostingController: UIHostingController<Content>,
        milliseconds: Double = 1
    ) {
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        RunLoop.main.run(
            until: Date(timeIntervalSinceNow: milliseconds / 1_000)
        )
        hostingController.view.layoutIfNeeded()
    }

    @MainActor
    private func makeSettledSegmentationSources() -> [String] {
        MockChatMessage.variableHeightStressConversation(count: 1_000)
            .map(\.text)
    }

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

    private func makeProse(atLeastUTF8Bytes target: Int) -> String {
        let paragraph =
            "A representative paragraph has **bold text**, a "
            + "[link](https://example.com), Unicode 👩🏽‍💻, and enough words "
            + "to wrap naturally across a phone-sized chat.\n\n"
        var source = ""
        while source.utf8.count < target {
            source += paragraph
        }
        return source
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

/// The streaming settle path as it existed before chunked coalescing, kept
/// only as a measurable baseline: every settled block re-coalesces the
/// entire stable prefix into a single prose run.
private nonisolated struct FullRecoalescingStreamingPlannerBaseline {
    private var stableUTF8Count = 0
    private var stableBlocks: [ChatMarkdownRenderPlan.Block] = []

    mutating func snapshot(source: String) -> ChatMarkdownRenderPlan {
        let sourceUTF8 = source.utf8
        let tailStart = sourceUTF8.index(
            sourceUTF8.startIndex,
            offsetBy: stableUTF8Count
        )
        let rawTail = String(decoding: sourceUTF8[tailStart...], as: UTF8.self)
        let repair = ChatStreamingMarkdownRepairer.repair(rawTail)
        let parsed = repair.openCodeBlock.map {
            [
                ChatMarkdownRenderPlanner.ParsedBlock(
                    utf8Offset: 0,
                    block: .code($0)
                )
            ]
        } ?? ChatMarkdownRenderPlanner.parsedBlocks(from: repair.displaySource)

        let activeBlocks: [ChatMarkdownRenderPlan.Block]
        if parsed.count > 1, let active = parsed.last, active.utf8Offset > 0 {
            stableBlocks = ChatMarkdownRenderPlan(
                blocks: stableBlocks + parsed.dropLast().map(\.block)
            ).blocks
            stableUTF8Count += active.utf8Offset
            activeBlocks = [active.block]
        } else if parsed.isEmpty {
            activeBlocks = []
        } else {
            activeBlocks = parsed.map(\.block)
        }
        return ChatMarkdownRenderPlan(
            streamingStableBlocks: stableBlocks,
            activeBlocks: activeBlocks
        )
    }
}

@MainActor
@Observable
private final class ChatMarkdownHostingState {
    var source = "## Streamed response\n\nA"
    var isStreaming = true
}

private struct ChatMarkdownHostingHarness: View {
    let state: ChatMarkdownHostingState

    @State private var textLayoutStore = ChatTextLayoutStore()

    var body: some View {
        ChatMarkdownMessageView(
            messageID: "hosted-streaming-lifecycle",
            source: state.source,
            presentation: ChatMarkdownPresentation(
                isStreaming: state.isStreaming
            ),
            textLayoutStore: textLayoutStore
        )
        .frame(width: 390, alignment: .leading)
    }
}

@MainActor
@Observable
private final class NativeStreamingBenchmarkState {
    var source = ""
    var isStreaming = true
}

private struct NativeStreamingBenchmarkHarness: View {
    let state: NativeStreamingBenchmarkState

    @State private var textLayoutStore = ChatTextLayoutStore()

    var body: some View {
        ChatMarkdownMessageView(
            messageID: "native-streaming-lifecycle-benchmark",
            source: state.source,
            presentation: ChatMarkdownPresentation(
                isStreaming: state.isStreaming
            ),
            textLayoutStore: textLayoutStore
        )
        .frame(width: 358, alignment: .leading)
    }
}

#endif
