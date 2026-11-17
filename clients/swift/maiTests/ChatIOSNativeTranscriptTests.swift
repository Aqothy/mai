#if os(iOS)
    import SwiftUI
    import Testing
    import UIKit

    @testable import mai

    @MainActor
    struct ChatIOSNativeTranscriptTests {
        private func makeDocument() -> ChatNativeTranscript<Text>.VirtualDocument {
            let document = ChatNativeTranscript<Text>.VirtualDocument(
                frame: CGRect(x: 0, y: 0, width: 300, height: 200))
            document.nativeRowFactory = { _, reused in reused ?? UIView() }
            return document
        }

        private var rowContent: (Int) -> Text { { Text("Row \($0)") } }

        @Test func readingPositionHoldsThroughHeightChangeAboveAndPrepend() {
            let document = makeDocument()
            defer { document.tearDown() }
            let ids = (0..<10).map { "row-\($0)" }
            document.install(
                heights: Array(repeating: 100, count: 10), width: 300, ids: ids,
                content: rowContent)
            document.contentOffset = CGPoint(x: 0, y: 350)

            // The first row grows above the viewport; the row being read keeps
            // its place on screen, in the same pass.
            document.noteHeight(
                200, id: "row-0", revision: document.rowRevisions["row-0"] ?? 0)
            #expect(document.contentOffset.y == 450)

            // An older page arrives above every row.
            document.install(
                heights: [20, 50] + document.geometry.heights, width: 300,
                ids: ["older-a", "older-b"] + ids, changedIDs: ["older-a", "older-b"],
                content: rowContent)
            #expect(document.contentOffset.y == 520)
        }

        @Test func followingKeepsTheEndInViewWhileAReplyGrows() {
            let document = makeDocument()
            defer { document.tearDown() }
            document.isBottomFollowingEnabled = { true }
            document.install(
                heights: [600, 20, 1], width: 300, ids: ["reply", "working", "end"],
                content: rowContent)
            #expect(document.contentOffset.y == document.contentSize.height - 200)
            for height in [CGFloat(630), 950, 780, 1100] {
                document.noteHeight(
                    height, id: "reply", revision: document.rowRevisions["reply"] ?? 0)
                #expect(document.contentOffset.y == document.contentSize.height - 200)
            }
        }

        /// A keyboard closing while the reader is just above the end must not
        /// leave blank space below the last row.
        @Test func shrinkingInsetsPullTheOffsetBackInsideTheContent() {
            let document = makeDocument()
            defer { document.tearDown() }
            document.install(
                heights: Array(repeating: 100, count: 10), width: 300, content: rowContent)
            document.setViewportInsets(UIEdgeInsets(top: 0, left: 0, bottom: 300, right: 0))
            document.contentOffset = CGPoint(x: 0, y: 1_100)
            document.setViewportInsets(.zero)
            #expect(document.contentOffset.y == 800)
        }

        @Test func initialAlignmentWaitsForRowsThenLandsOnTheEnd() async {
            let document = makeDocument()
            defer { document.tearDown() }
            var completed = 0
            document.beginInitialBottomAlignment { completed += 1 }
            #expect(document.initialBottomAlignmentCompletion != nil)
            document.install(
                heights: Array(repeating: 100, count: 10), width: 300, content: rowContent)
            #expect(document.contentOffset.y == 800)
            #expect(document.initialBottomAlignmentCompletion == nil)
            for _ in 0..<5 { await Task.yield() }
            #expect(completed == 1)
        }

        /// Offset changes the reader makes, by any input, are intent; the
        /// document's own are not.
        @Test func onlyTheReadersOwnScrollsCountAsIntent() {
            let document = makeDocument()
            defer { document.tearDown() }
            let ids = (0..<10).map { "row-\($0)" }
            document.install(
                heights: Array(repeating: 100, count: 10), width: 300, ids: ids,
                content: rowContent)
            let preserver = ChatIOSScrollPositionPreserver()
            var moves: [ChatScrollFollowPolicy.ReaderScroll] = []
            preserver.configure(
                ChatScrollIntentHandlers(
                    noteReaderLeftEnd: { moves.append(.leftEnd) },
                    noteReaderReachedEnd: { moves.append(.reachedEnd) }))
            preserver.attach(to: document)

            document.contentOffset = CGPoint(x: 0, y: 500)
            document.contentOffset = CGPoint(x: 0, y: 300)
            document.contentOffset = CGPoint(x: 0, y: 600)
            document.contentOffset = CGPoint(x: 0, y: 800)
            #expect(moves == [.leftEnd, .reachedEnd])

            document.noteHeight(
                200, id: "row-0", revision: document.rowRevisions["row-0"] ?? 0)
            #expect(document.contentOffset.y == 900)
            #expect(moves == [.leftEnd, .reachedEnd])
        }

        /// The jump lands on the end as it is when it arrives, and the
        /// document's own frames are not the reader's intent.
        @Test func anAnimatedJumpArrivesAtAnEndThatGrewOnTheWay() {
            let document = makeDocument()
            defer { document.tearDown() }
            let window = UIWindow(frame: document.frame)
            window.addSubview(document)
            let ids = (0..<10).map { "row-\($0)" }
            document.install(
                heights: Array(repeating: 100, count: 10), width: 300, ids: ids,
                content: rowContent)
            let preserver = ChatIOSScrollPositionPreserver()
            var moves: [ChatScrollFollowPolicy.ReaderScroll] = []
            preserver.configure(
                ChatScrollIntentHandlers(
                    isBottomFollowingEnabled: { true },
                    noteReaderLeftEnd: { moves.append(.leftEnd) },
                    noteReaderReachedEnd: { moves.append(.reachedEnd) }))
            preserver.attach(to: document)
            document.contentOffset = CGPoint(x: 0, y: 100)
            moves.removeAll()

            #expect(preserver.pinToBottom(animated: true))
            // A row grows while the jump flies; the jump, not a pin, moves
            // the viewport.
            document.noteHeight(400, id: "row-9", revision: document.rowRevisions["row-9"] ?? 0)
            #expect(document.contentOffset.y == 100)
            document.advanceScrollAnimation(to: CACurrentMediaTime() + 1)
            #expect(document.contentOffset.y == document.contentSize.height - 200)
            #expect(moves.isEmpty)
        }

        /// A streaming reply's live row becomes its settled blocks while the
        /// reader is inside it, and the working row below it leaves.
        @Test func aReaderInsideASettlingReplyKeepsTheirPlaceInIt() {
            let document = makeDocument()
            defer { document.tearDown() }
            document.install(
                heights: [100, 900, 40, 1], width: 300,
                ids: ["user", "message-m", "working", "end"],
                sourceIDs: ["user", "m", "working", "end"], content: rowContent)
            document.contentOffset = CGPoint(x: 0, y: 600)

            document.install(
                heights: [100, 400, 500, 1], width: 300,
                ids: ["user", "m#block-0", "m#block-1", "end"],
                sourceIDs: ["user", "m", "m", "end"], content: rowContent)
            #expect(document.contentOffset.y == 600)
        }

        /// The work the reader was looking at folds behind its header when
        /// the turn finishes.
        @Test func aReaderInsideFoldedWorkLandsBelowTheHeader() {
            let document = makeDocument()
            defer { document.tearDown() }
            document.install(
                heights: [100, 40, 300, 300, 900], width: 300,
                ids: ["user", "header", "work-a", "work-b", "reply"], content: rowContent)
            document.contentOffset = CGPoint(x: 0, y: 500)

            document.install(
                heights: [100, 40, 900], width: 300, ids: ["user", "header", "reply"],
                content: rowContent)
            #expect(document.contentOffset.y == 140)
        }
    }
#endif
