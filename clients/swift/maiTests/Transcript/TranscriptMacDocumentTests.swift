#if os(macOS)
    import AppKit
    import CoreGraphics
    import Foundation
    import Testing

    @testable import mai

    /// PLAN 3.9 on the Mac: clip moves arrive through the clip's bounds
    /// notifications, and only the reader's count. Cases from
    /// `ChatMacScrollPositionPreserverTests`, `ChatNativeViewportWidthTests`
    /// and `ChatVirtualTranscriptGeometryTests`.
    @MainActor
    struct TranscriptMacDocumentTests {
        private struct Fixture {
            let window: NSWindow
            let scroll: NSScrollView
            let document: TranscriptDocumentView
            let controller: TranscriptController

            var clip: NSClipView { scroll.contentView }

            func close() {
                window.contentView = nil
                window.close()
            }
        }

        private func make(width: CGFloat = 300, height: CGFloat = 200) -> Fixture {
            let controller = TranscriptController(configuration: .testing)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            scroll.hasVerticalScroller = false
            scroll.automaticallyAdjustsContentInsets = false
            let document = TranscriptDocumentView(controller: controller)
            scroll.documentView = document
            let window = NSWindow(
                contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            return Fixture(window: window, scroll: scroll, document: document, controller: controller)
        }

        private let ids = (0..<10).map { "row-\($0)" }

        private func install(_ fixture: Fixture, heights: [CGFloat]? = nil) {
            let rows = ids.map { TranscriptRow(id: $0, kind: .notice(title: $0, text: nil)) }
            let heights = heights ?? Array(repeating: 100, count: ids.count)
            fixture.controller.setRows(
                rows, measuredHeights: Dictionary(uniqueKeysWithValues: zip(ids, heights)))
        }

        @Test func theFirstRowsLandOnTheEndAndShow() {
            let fixture = make()
            defer { fixture.close() }
            #expect(fixture.document.alphaValue == 0)
            install(fixture)
            #expect(fixture.clip.bounds.minY == 800)
            #expect(fixture.document.alphaValue == 1)
            #expect(fixture.document.frame.height == 1_000)
        }

        /// The reader's clip moves are reported; the document's own, and a
        /// resize's, are not.
        @Test func onlyTheReadersClipMovesCount() {
            let fixture = make()
            defer { fixture.close() }
            install(fixture)
            fixture.controller.debugReaderMoves.removeAll()

            fixture.clip.scroll(to: NSPoint(x: 0, y: 500))
            fixture.clip.scroll(to: NSPoint(x: 0, y: 800))
            #expect(fixture.controller.debugReaderMoves == [.awayFromEnd, .reachedEnd])

            fixture.controller.setHeights(["row-0": 200])
            #expect(fixture.clip.bounds.minY == 900)
            fixture.scroll.setFrameSize(NSSize(width: 300, height: 150))
            fixture.scroll.tile()
            #expect(fixture.controller.debugReaderMoves == [.awayFromEnd, .reachedEnd])
            #expect(fixture.clip.bounds.maxY == fixture.document.frame.maxY)
        }

        @Test func heightChangesAboveAndAPrependKeepTheReadingPlace() {
            let fixture = make()
            defer { fixture.close() }
            install(fixture)
            fixture.clip.scroll(to: NSPoint(x: 0, y: 350))
            fixture.controller.setHeights(["row-0": 200])
            #expect(fixture.clip.bounds.minY == 450)

            let older = ["older-a", "older-b"].map { TranscriptRow(id: $0, kind: .notice(title: $0, text: nil)) }
            fixture.controller.setRows(
                older + fixture.controller.rows, measuredHeights: ["older-a": 20, "older-b": 50])
            #expect(fixture.clip.bounds.minY == 520)

            // A resize can move the clip's origin without the reader; it is
            // not a new reading position.
            var bounds = fixture.clip.bounds
            bounds.size.width -= 30
            bounds.size.height -= 30
            bounds.origin.y += 5.5
            fixture.clip.bounds = bounds
            #expect(abs(fixture.clip.bounds.minY - 520) < 0.000_001)
        }

        @Test func remeasurementDuringReaderScrollingKeepsTheReadersNewPosition() {
            let fixture = make()
            defer { fixture.close() }
            install(fixture, heights: Array(repeating: 100, count: 10))
            fixture.clip.scroll(to: NSPoint(x: 0, y: 250))
            fixture.controller.setHeights(["row-0": 200])
            fixture.clip.scroll(to: NSPoint(x: 0, y: 700))
            #expect(fixture.clip.bounds.minY == 700)
            fixture.controller.setHeights(["row-0": 250])
            #expect(fixture.clip.bounds.minY == 750)
        }

        /// A growing reply keeps the row after it pinned to the end in the
        /// same pass: no frame shows it displaced.
        @Test func aGrowingReplyKeepsTheWorkingRowPinnedInTheSamePass() {
            let fixture = make()
            defer { fixture.close() }
            let rows = ["reply", "working", "end"].map { TranscriptRow(id: $0, kind: .notice(title: $0, text: nil)) }
            fixture.controller.setRows(rows, measuredHeights: ["reply": 600, "working": 20, "end": 1])
            let workingY = fixture.controller.geometry.offset(at: 1) - fixture.clip.bounds.minY
            for height in [CGFloat(630), 950, 780, 1100] {
                fixture.controller.setHeights(["reply": height])
                #expect(fixture.controller.geometry.offset(at: 1) - fixture.clip.bounds.minY == workingY)
                #expect(fixture.clip.bounds.maxY == fixture.document.frame.maxY)
            }
        }

        /// The transcript scrolls vertically only: after any width change the
        /// document matches the clip, and a sideways offset goes.
        @Test func widthChangesKeepTheDocumentAsWideAsTheClip() {
            let fixture = make(width: 1_000, height: 300)
            defer { fixture.close() }
            install(fixture)
            for width in [CGFloat(720), 1_000, 1_280, 720] {
                fixture.scroll.setFrameSize(NSSize(width: width, height: 300))
                fixture.scroll.tile()
                #expect(fixture.document.frame.width == fixture.scroll.contentSize.width)
                #expect(fixture.controller.columnWidth == TranscriptController.columnWidth(for: fixture.scroll.contentSize.width))
            }
            fixture.clip.setBoundsOrigin(NSPoint(x: 40, y: 120))
            #expect(fixture.clip.bounds.origin.x == 0)
        }
    }
#endif
