#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing
    @testable import mai

    struct ChatMacScrollPositionPreserverTests {
        @Test
        func bottomOffsetIncludesComposerInsetAndKeepsShortContentAtTopInset() {
            #expect(
                ChatScrollGeometry.bottomOffset(
                    contentHeight: 27_978, viewportHeight: 928,
                    topInset: 0, bottomInset: 102) == 27_152)
            #expect(
                ChatScrollGeometry.bottomOffset(
                    contentHeight: 400, viewportHeight: 928,
                    topInset: 14, bottomInset: 102) == -14)
        }

        /// A move toward older content leaves the end even inside the end
        /// zone; only a move toward the end that shows it follows again, and
        /// an overscroll settling back on the end is no move.
        @Test
        func readerScrollsLeaveOrReachTheEndByDirection() {
            typealias Policy = ChatScrollFollowPolicy
            let cases: [(name: String, from: CGFloat, to: CGFloat, isNearBottom: Bool, expected: Policy.ReaderScroll?)] = [
                ("up inside the end zone", 1_000, 990, true, .leftEnd),
                ("up far from the end", 500, 200, false, .leftEnd),
                ("down onto the end", 900, 1_000, true, .reachedEnd),
                ("down short of the end", 200, 500, false, nil),
                ("overscroll settling back", 1_040, 1_000, true, nil),
                ("subpixel noise", 1_000, 999.8, true, nil),
            ]
            for testCase in cases {
                #expect(
                    Policy.readerScroll(
                        from: testCase.from, to: testCase.to, endTop: 1_000,
                        isNearBottom: testCase.isNearBottom) == testCase.expected,
                    "\(testCase.name)")
            }
        }

        /// The reader's clip moves are reported; the document's own, and a
        /// resize's, are not.
        @Test @MainActor
        func onlyTheReadersClipMovesAreReported() {
            let document = ChatNativeTranscript<Text>.VirtualDocument()
            document.nativeRowFactory = { _, reused in reused ?? NSView() }
            let scroll = ChatMacTranscriptScrollView(
                frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            scroll.documentView = document
            document.observeViewport(of: scroll)
            defer { document.tearDown() }
            let ids = (0..<10).map { "row-\($0)" }
            document.install(heights: Array(repeating: 100, count: 10), width: 300, ids: ids) {
                Text("Row \($0)")
            }
            let preserver = ChatMacScrollPositionPreserver()
            var moves: [ChatScrollFollowPolicy.ReaderScroll] = []
            preserver.configure(
                ChatScrollIntentHandlers(
                    noteReaderLeftEnd: { moves.append(.leftEnd) },
                    noteReaderReachedEnd: { moves.append(.reachedEnd) }))
            preserver.attach(to: document)
            #expect(preserver.pinToBottom())

            scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 800))
            #expect(moves == [.leftEnd, .reachedEnd])

            document.noteHeight(200, id: "row-0", revision: document.rowRevisions["row-0"] ?? 0)
            #expect(scroll.contentView.bounds.minY == 900)
            scroll.setFrameSize(NSSize(width: 300, height: 150))
            #expect(moves == [.leftEnd, .reachedEnd])
        }

        @Test @MainActor
        func remeasurementDuringUserScrollingKeepsTheUsersNewPosition() async {
            let document = ChatNativeTranscript<Text>.VirtualDocument()
            document.nativeRowFactory = { _, reused in reused ?? NSView() }
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            scroll.documentView = document
            func remeasureFirstRow(to height: CGFloat) {
                document.install(heights: [height] + Array(repeating: 100, count: 11), width: 300) {
                    Text("Row \($0)")
                }
            }
            remeasureFirstRow(to: 100)
            defer { document.preparationTask?.cancel() }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 250))
            for _ in 0..<20 { await Task.yield() }

            remeasureFirstRow(to: 200)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 700))
            for _ in 0..<20 { await Task.yield() }
            #expect(scroll.contentView.bounds.minY == 700)

            // Where the reader scrolled is the anchor for later layout.
            remeasureFirstRow(to: 250)
            for _ in 0..<20 { await Task.yield() }
            #expect(scroll.contentView.bounds.minY == 750)
        }
    }
#endif
