#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing

    @testable import mai

    @MainActor
    struct ChatNativeViewportWidthTests {
        /// The outer transcript scrolls vertically only: after any viewport
        /// width change, document and mounted rows must match the clip width,
        /// including widths above the capped content width.
        @Test
        func viewportWidthChangesKeepDocumentAndMountedRowsAligned() {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
            let document = ChatNativeTranscript<Text>.VirtualDocument()
            scroll.documentView = document
            document.observeViewport(of: scroll)
            defer {
                NotificationCenter.default.removeObserver(document)
                document.preparationTask?.cancel()
                document.geometryNotificationTask?.cancel()
            }
            document.nativeRowFactory = { _, reused in reused ?? NSView() }
            document.install(heights: [400], width: 760, ids: ["row"]) { _ in Text("Fixture") }

            for width in [CGFloat(720), 1000, 1280, 720] {
                scroll.setFrameSize(NSSize(width: width, height: 300))
                scroll.tile()
                let expected = scroll.contentSize.width
                #expect(document.frame.width == expected)
                #expect(document.hosts[0]?.frame.width == expected)
            }
        }

        /// Above the content cap a wider viewport does not re-prepare rows, so a
        /// prepared row must recenter its body when only its width changes.
        @Test
        func preparedRowsRecenterAboveTheContentWidthCap() throws {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1020, height: 300))
            let document = ChatNativeTranscript<Text>.VirtualDocument()
            scroll.documentView = document
            document.observeViewport(of: scroll)
            defer {
                NotificationCenter.default.removeObserver(document)
                document.preparationTask?.cancel()
                document.geometryNotificationTask?.cancel()
            }
            let store = ChatTextLayoutStore()
            document.nativeRowFactory = { _, reused in
                let row = reused as? ChatNativePreparedRow ?? ChatNativePreparedRow(frame: .zero)
                row.update(
                    .init(id: "prose", content: .prose(.source("Centered prose")), top: 0, bottom: 0),
                    width: 760, store: store, theme: .light)
                return row
            }
            document.install(heights: [80], width: 760, ids: ["prose"]) { _ in Text("Fixture") }

            for width in [CGFloat(1020), 1232, 1020, 1400] {
                scroll.setFrameSize(NSSize(width: width, height: 300))
                scroll.tile()
                let row = try #require(document.hosts[0])
                row.layoutSubtreeIfNeeded()
                let body = try #require(row.subviews.first { $0 is ChatSelectableTextHostView })
                #expect(body.frame.width == 760)
                #expect(body.frame.minX == (scroll.contentSize.width - 760) / 2)
            }
        }

        @Test
        func staleHorizontalClipOriginReturnsToLeadingEdge() {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
            let document = ChatNativeTranscript<Text>.VirtualDocument()
            scroll.documentView = document
            defer {
                document.preparationTask?.cancel()
                document.geometryNotificationTask?.cancel()
            }
            document.nativeRowFactory = { _, reused in reused ?? NSView() }
            document.install(heights: [400, 400], width: 760, ids: ["a", "b"]) { _ in Text("Fixture") }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))

            // A clip moved sideways while the document was wider than it.
            scroll.setFrameSize(NSSize(width: 720, height: 300))
            scroll.tile()
            scroll.contentView.setBoundsOrigin(NSPoint(x: 40, y: 120))
            document.viewportChanged()

            #expect(document.frame.width == scroll.contentSize.width)
            #expect(scroll.contentView.bounds.origin.x == 0)
            #expect(scroll.contentView.bounds.origin.y == 120)
        }
    }
#endif
