#if os(macOS)
    import AppKit
    import Testing
    @testable import mai

    @MainActor private final class RemeasuringScrollDocument: NSView, ChatMacScrollDocument {
        var heights = Array(repeating: CGFloat(100), count: 12)
        override var isFlipped: Bool { true }
        var numberOfRows: Int { heights.count }

        func rect(ofRow row: Int) -> NSRect {
            NSRect(x: 0, y: heights.prefix(row).reduce(0, +), width: 300, height: heights[row])
        }

        func rows(in rect: NSRect) -> NSRange {
            let visible = heights.indices.filter { self.rect(ofRow: $0).intersects(rect) }
            guard let first = visible.first, let last = visible.last else {
                return NSRange(location: NSNotFound, length: 0)
            }
            return NSRange(location: first, length: last - first + 1)
        }

        func remeasureFirstRow(to height: CGFloat) {
            heights[0] = height
            setFrameSize(NSSize(width: 300, height: heights.reduce(0, +)))
        }
    }

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
        func appKitRemeasurementIsAppliedOnceWhenTheClipAlreadyMoved() async {
            await checkRemeasurement(appKitAdjustsOffset: true)
        }

        @Test @MainActor
        func remeasurementPreservesTheAnchorWhenAppKitDoesNotMoveTheClip() async {
            await checkRemeasurement(appKitAdjustsOffset: false)
        }

        @MainActor private func checkRemeasurement(appKitAdjustsOffset: Bool) async {
            let document = RemeasuringScrollDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 1200))
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            scroll.documentView = document
            let preserver = ChatMacScrollPositionPreserver()
            preserver.attach(to: document)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 250))
            for _ in 0..<20 { await Task.yield() }

            // Row 2 is the reading anchor, initially 50 points above the viewport.
            // NSTableView can correct the clip itself before our deferred observer
            // runs. Both notification orders must preserve the same visible text.
            for height in [CGFloat(200), 50, 175, 100] {
                let expectedOrigin = height + 150
                document.remeasureFirstRow(to: height)
                if appKitAdjustsOffset {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: expectedOrigin))
                }
                for _ in 0..<20 { await Task.yield() }
                #expect(scroll.contentView.bounds.minY == expectedOrigin)
                #expect(document.rect(ofRow: 2).minY - scroll.contentView.bounds.minY == -50)
            }
        }

        @Test @MainActor
        func remeasurementDuringUserScrollingKeepsTheUsersNewPosition() async {
            let document = RemeasuringScrollDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 1200))
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            scroll.documentView = document
            let preserver = ChatMacScrollPositionPreserver()
            preserver.attach(to: document)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 250))
            for _ in 0..<20 { await Task.yield() }

            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            document.remeasureFirstRow(to: 200)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 700))
            for _ in 0..<20 { await Task.yield() }
            #expect(scroll.contentView.bounds.minY == 700)
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            for _ in 0..<20 { await Task.yield() }
            #expect(scroll.contentView.bounds.minY == 700)

            // The end of the gesture establishes a new anchor for later layout.
            document.remeasureFirstRow(to: 250)
            for _ in 0..<20 { await Task.yield() }
            #expect(scroll.contentView.bounds.minY == 750)
        }
    }
#endif
