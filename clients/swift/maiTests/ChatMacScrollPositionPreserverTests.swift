#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing
    @testable import mai

    struct ChatMacScrollPositionPreserverTests {
        @Test
        func bottomOriginIncludesComposerInsetAndKeepsShortContentAtTopInset() {
            #expect(
                ChatMacScrollPositionPreserver.bottomOrigin(
                    documentMinY: 0, documentMaxY: 27_978, viewportHeight: 928,
                    topInset: 0, bottomInset: 102) == 27_152)
            #expect(
                ChatMacScrollPositionPreserver.bottomOrigin(
                    documentMinY: 0, documentMaxY: 400, viewportHeight: 928,
                    topInset: 14, bottomInset: 102) == -14)
        }

        /// Upward scrolls cannot resume following from transient bottom geometry.
        @Test
        func onlyAScrollEndingDownwardAtTheBottomRestoresFollowing() {
            #expect(
                !ChatMacScrollPositionPreserver.shouldRestoreFollowingAfterUserScroll(
                    startY: 10_000, endY: 9_000, isNearBottom: true))
            #expect(
                ChatMacScrollPositionPreserver.shouldRestoreFollowingAfterUserScroll(
                    startY: 9_000, endY: 10_000, isNearBottom: true))
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
            let preserver = ChatMacScrollPositionPreserver()
            preserver.attach(to: document)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 250))
            for _ in 0..<20 { await Task.yield() }

            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            remeasureFirstRow(to: 200)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 700))
            for _ in 0..<20 { await Task.yield() }
            #expect(scroll.contentView.bounds.minY == 700)
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            for _ in 0..<20 { await Task.yield() }
            #expect(scroll.contentView.bounds.minY == 700)

            // The end of the gesture establishes a new anchor for later layout.
            remeasureFirstRow(to: 250)
            for _ in 0..<20 { await Task.yield() }
            #expect(scroll.contentView.bounds.minY == 750)
        }
    }
#endif
