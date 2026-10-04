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
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                document, selector: #selector(document.viewportChanged),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView)
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
                document.viewportChanged()
                let expected = scroll.contentSize.width
                #expect(document.frame.width == expected)
                #expect(document.hosts[0]?.frame.width == expected)
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
