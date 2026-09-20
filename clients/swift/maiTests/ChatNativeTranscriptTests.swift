#if os(macOS)
    import SwiftUI
    import Testing
    import Observation
    @testable import mai

    @MainActor @Observable private final class ExpandingRowState {
        var height: CGFloat = 60
    }

    private struct ExpandingRow: View {
        let state: ExpandingRowState
        let isThought: Bool
        var body: some View { Color.clear.frame(height: isThought ? state.height : 20) }
    }

    private struct FixedHeightRow: View {
        let text: String
        var body: some View { Text(text).frame(height: 100) }
    }

    struct ChatNativeTranscriptTests {
        @Test @MainActor func reflowPreservesReadingPositionEvenWhenTotalHeightIsUnchanged() async {
            let document = ChatNativeTranscript<Text>.VirtualDocument()
            document.nativeRowFactory = { _, reused in reused ?? NSView() }
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            scroll.documentView = document
            let ids = (0..<10).map { "row-\($0)" }
            document.install(heights: Array(repeating: 100, count: 10), width: 300,
                             ids: ids) { Text("Row \($0)") }
            let preserver = ChatMacScrollPositionPreserver()
            preserver.attach(to: document)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 250))
            for _ in 0..<20 { await Task.yield() }
            document.install(heights: [200, 50, 50] + Array(repeating: 100, count: 7),
                             width: 300, ids: ids) { Text("Row \($0)") }
            // Extent remains 1,000; a frame-change observer never sees this reflow.
            #expect(document.bounds.height == 1000)
            #expect(scroll.contentView.bounds.minY == 300)
            document.preparationTask?.cancel()
        }

        @Test @MainActor func growingReplyKeepsWorkingRowPinnedInTheSameLayoutCommit() throws {
            let document = ChatNativeTranscript<Text>.VirtualDocument()
            document.nativeRowFactory = { _, reused in reused ?? NSView() }
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            scroll.documentView = document
            document.install(heights: [600, 20, 1], width: 300,
                             ids: ["reply", "working", "end"]) { Text("Row \($0)") }
            let preserver = ChatMacScrollPositionPreserver()
            preserver.configure(isBottomFollowingEnabled: { true },
                               noteUserScrollActivity: { _ in }, noteUserReachedEnd: {},
                               noteKeyboardScrollIntent: { _ in })
            preserver.attach(to: document)
            #expect(preserver.pinToBottom())
            let workingY = document.rect(ofRow: 1).minY - scroll.contentView.bounds.minY
            for height in [CGFloat(630), 950, 780, 1100] {
                document.noteHeight(height, id: "reply", revision: document.rowRevisions["reply"] ?? 0)
                // No yield: an eventual correction still permits a visibly displaced frame.
                #expect(document.rect(ofRow: 1).minY - scroll.contentView.bounds.minY == workingY)
                #expect(scroll.contentView.bounds.maxY == document.bounds.maxY)
            }
            document.preparationTask?.cancel()
            document.heightUpdateTask?.cancel()
        }

        @Test @MainActor func heightChangesMovePreparedNeighborsBeforeTheyBecomeVisible() async {
            let document = ChatNativeTranscript<Text>.VirtualDocument()
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            scroll.documentView = document
            document.nativeRowFactory = { _, _ in NSView() }
            document.install(heights: Array(repeating: 100, count: 20), width: 300) {
                Text("Row \($0)")
            }
            await document.preparationTask?.value
            let neighbor = document.hosts[3]
            #expect(neighbor != nil)
            document.noteHeight(150, id: "0", revision: document.rowRevisions["0", default: 0])
            // Already-mounted neighbors must move before the next frame can paint.
            #expect(neighbor?.frame.minY == 350)
            #expect(document.rect(ofRow: 3).minY == 350)
            await document.heightUpdateTask?.value
            #expect(neighbor?.frame.minY == document.rect(ofRow: 3).minY)
        }

        @Test @MainActor func expandedContentUpdatesItsHostAndScrollableExtent() async {
            let state = ExpandingRowState()
            let document = ChatNativeTranscript<ExpandingRow>.VirtualDocument()
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            let window = NSWindow(
                contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            scroll.documentView = document
            document.install(heights: [60, 20], width: 300, ids: ["thought", "working"]) {
                ExpandingRow(state: state, isThought: $0 == 0)
            }
            defer {
                document.preparationTask?.cancel()
                window.close()
            }
            for height in [CGFloat(500), 60, 300] {
                state.height = height
                let deadline = ContinuousClock.now + .seconds(2)
                while document.geometry.heights.first != height, ContinuousClock.now < deadline {
                    scroll.layoutSubtreeIfNeeded()
                    try? await Task.sleep(for: .milliseconds(20))
                }
                #expect(document.geometry.heights.first == height)
                #expect(document.hosts[0]?.frame.height == height)
                #expect(document.rect(ofRow: 1).minY == height)
                #expect(document.frame.height == height + 20)
            }
        }

        @Test @MainActor func customRowLookupUsesHalfOpenIntervals() {
            let document = ChatNativeTranscript<Text>.VirtualDocument()
            document.install(heights: [10, 20, 30], width: 300) { Text("Row \($0)") }
            for (position, expected) in [
                (0.0, 0), (9.0, 0), (10.0, 1), (29.0, 1), (30.0, 2), (60.0, 2),
            ] {
                #expect(document.row(at: position) == expected)
            }
            #expect(document.frame.height == 60)
        }

        @Test @MainActor func customViewportKeepsViewsBoundedAndReusesVisibleRows() {
            let document = ChatNativeTranscript<FixedHeightRow>.VirtualDocument()
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            scroll.documentView = document
            document.install(heights: Array(repeating: 100, count: 5850), width: 300) {
                FixedHeightRow(text: "Row \($0)")
            }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 1000))
            document.viewportChanged()
            let visibleHost = document.hosts[10]
            #expect(visibleHost != nil)
            #expect(document.hosts.count <= 8)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 1050))
            document.viewportChanged()
            #expect(document.hosts[10] === visibleHost)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 480000))
            document.viewportChanged()
            #expect(document.hosts[4800] != nil)
            #expect(document.hosts[10] == nil)
            #expect(document.hosts.count <= 8)
            #expect(document.hosts.values.allSatisfy { $0.superview === document })
            let visualOrder = document.subviews.map { $0.frame.minY }
            #expect(visualOrder == visualOrder.sorted())
        }

    }
#endif
