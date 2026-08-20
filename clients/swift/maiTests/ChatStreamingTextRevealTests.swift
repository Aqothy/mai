import Foundation
import Testing

@testable import mai

struct ChatStreamingTextRevealTests {
    @Test
    func recordsOverlappingAppendsAsIndependentBatches() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var state = ChatStreamingTextRevealState()
        let identity = ChatStreamingTextRevealTarget.Identity(
            stableBlockCount: 0,
            blockIndex: 0,
            content: .proseText(pieceIndex: 0)
        )

        state.observe(
            target: ChatStreamingTextRevealTarget(
                identity: identity,
                characterCount: 5
            ),
            updateID: 1,
            sourceIsAppendOnly: true,
            at: start
        )
        state.observe(
            target: ChatStreamingTextRevealTarget(
                identity: identity,
                characterCount: 6
            ),
            updateID: 2,
            sourceIsAppendOnly: true,
            at: start.addingTimeInterval(0.05)
        )
        state.observe(
            target: ChatStreamingTextRevealTarget(
                identity: identity,
                characterCount: 11
            ),
            updateID: 3,
            sourceIsAppendOnly: true,
            at: start.addingTimeInterval(0.1)
        )

        #expect(state.batches.map(\.characterCount) == [1, 5])
        #expect(
            abs(
                state.batches[0].progress(
                    at: start.addingTimeInterval(0.15)
                ) - 0.5
            ) < 0.0001
        )
        #expect(
            abs(
                state.batches[1].progress(
                    at: start.addingTimeInterval(0.15)
                ) - 0.25
            ) < 0.0001
        )
    }

    @Test
    func parsedTargetCountsExtendedGraphemeClusters() {
        let start = Date(timeIntervalSinceReferenceDate: 2_000)
        var state = ChatStreamingTextRevealState()
        var planner = ChatIncrementalMarkdownRenderPlanner()
        let first = planner.snapshot(
            source: "A",
            sourceIsAppendOnly: true
        )
        let second = planner.snapshot(
            source: "A👨‍👩‍👧‍👦",
            sourceIsAppendOnly: true
        )

        state.observe(
            target: ChatStreamingTextRevealTarget(snapshot: first),
            updateID: 1,
            sourceIsAppendOnly: true,
            at: start
        )
        state.observe(
            target: ChatStreamingTextRevealTarget(snapshot: second),
            updateID: 2,
            sourceIsAppendOnly: true,
            at: start.addingTimeInterval(0.05)
        )

        #expect(state.batches.map(\.characterCount) == [1])
    }

    @Test
    func replacementBecomesANewBaselineWithoutAnimating() {
        let start = Date(timeIntervalSinceReferenceDate: 3_000)
        var state = ChatStreamingTextRevealState()
        let identity = ChatStreamingTextRevealTarget.Identity(
            stableBlockCount: 0,
            blockIndex: 0,
            content: .proseText(pieceIndex: 0)
        )

        state.observe(
            target: ChatStreamingTextRevealTarget(
                identity: identity,
                characterCount: 8
            ),
            updateID: 10,
            sourceIsAppendOnly: true,
            at: start
        )
        state.observe(
            target: ChatStreamingTextRevealTarget(
                identity: identity,
                characterCount: 13
            ),
            updateID: 11,
            sourceIsAppendOnly: true,
            at: start.addingTimeInterval(0.05)
        )
        state.observe(
            target: ChatStreamingTextRevealTarget(
                identity: identity,
                characterCount: 11
            ),
            updateID: 1,
            sourceIsAppendOnly: true,
            at: start.addingTimeInterval(0.1)
        )

        #expect(state.batches.isEmpty)

        state.observe(
            target: ChatStreamingTextRevealTarget(
                identity: identity,
                characterCount: 12
            ),
            updateID: 2,
            sourceIsAppendOnly: true,
            at: start.addingTimeInterval(0.15)
        )
        #expect(state.batches.map(\.characterCount) == [1])
    }

    @Test
    func boundsStateForLargeAndFrequentChunks() {
        let start = Date(timeIntervalSinceReferenceDate: 4_000)
        var state = ChatStreamingTextRevealState()
        let identity = ChatStreamingTextRevealTarget.Identity(
            stableBlockCount: 0,
            blockIndex: 0,
            content: .code
        )

        state.observe(
            target: ChatStreamingTextRevealTarget(
                identity: identity,
                characterCount: 0
            ),
            updateID: 0,
            sourceIsAppendOnly: true,
            at: start
        )
        for updateID in 1...10 {
            state.observe(
                target: ChatStreamingTextRevealTarget(
                    identity: identity,
                    characterCount: updateID * 100
                ),
                updateID: updateID,
                sourceIsAppendOnly: true,
                at: start.addingTimeInterval(Double(updateID) * 0.01)
            )
        }

        #expect(
            state.batches.count
                <= ChatStreamingTextRevealState.maximumBatchCount
        )
        #expect(
            state.batches.reduce(0) { $0 + $1.characterCount }
                == ChatStreamingTextRevealState.maximumAnimatedCharacterCount
        )
    }

    @Test
    func hiddenMarkdownDelimitersDoNotReanimateVisibleText() {
        let start = Date(timeIntervalSinceReferenceDate: 5_000)
        var planner = ChatIncrementalMarkdownRenderPlanner()
        let visible = planner.snapshot(
            source: "Paragraph ",
            sourceIsAppendOnly: true
        )
        let hiddenDelimiter = planner.snapshot(
            source: "Paragraph **",
            sourceIsAppendOnly: true
        )
        var state = ChatStreamingTextRevealState()

        state.observe(
            target: ChatStreamingTextRevealTarget(snapshot: visible),
            updateID: 1,
            sourceIsAppendOnly: true,
            at: start
        )
        state.observe(
            target: ChatStreamingTextRevealTarget(snapshot: hiddenDelimiter),
            updateID: 2,
            sourceIsAppendOnly: true,
            at: start.addingTimeInterval(0.05)
        )

        #expect(state.batches.isEmpty)
    }
}
