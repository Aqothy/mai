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
                200, id: "row-0", revision: document.rowRevisions["row-0", default: 0])
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
                    height, id: "reply", revision: document.rowRevisions["reply", default: 0])
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

        /// Offset changes the reader makes without a drag (a status-bar tap,
        /// a hardware keyboard) are intent; the document's own are not.
        @Test func onlyTheReadersOwnScrollsCountAsIntent() {
            let document = makeDocument()
            defer { document.tearDown() }
            let ids = (0..<10).map { "row-\($0)" }
            document.install(
                heights: Array(repeating: 100, count: 10), width: 300, ids: ids,
                content: rowContent)
            let preserver = ChatIOSScrollPositionPreserver()
            var intents: [Bool] = []
            preserver.configure(
                isBottomFollowingEnabled: { false }, noteUserScrollActivity: { _ in },
                noteUserReachedEnd: {}, noteKeyboardScrollIntent: { intents.append($0) })
            preserver.attach(to: document)

            document.contentOffset = CGPoint(x: 0, y: 500)
            document.contentOffset = CGPoint(x: 0, y: 300)
            document.contentOffset = CGPoint(x: 0, y: 600)
            #expect(intents == [false, true])

            document.noteHeight(
                200, id: "row-0", revision: document.rowRevisions["row-0", default: 0])
            #expect(document.contentOffset.y == 700)
            #expect(intents == [false, true])
        }
    }
#endif
