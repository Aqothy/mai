#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing
    @testable import mai

    struct ChatMeasuredTranscriptRowTests {
        @Test @MainActor func growingContentDoesNotMoveAboveItsHostWhileHeightUpdateIsPending()
            async throws
        {
            var contentRect: CGRect?
            var reportedHeight: CGFloat?
            let content = Color.clear.frame(height: 300)
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    contentRect = $0
                }
            let hosting = NSHostingView(
                rootView: ChatMeasuredTranscriptRow(content: content) { reportedHeight = $0 })
            hosting.sizingOptions = []
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 400),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView?.addSubview(hosting)
            hosting.frame = NSRect(x: 0, y: 100, width: 380, height: 300)
            let deadline = ContinuousClock.now + .seconds(2)
            while contentRect == nil, ContinuousClock.now < deadline {
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let initialRect = try #require(contentRect)
            contentRect = nil
            // Keep the host's top edge fixed while its allocated height lags content.
            hosting.frame = NSRect(x: 0, y: 340, width: 380, height: 60)
            let changedDeadline = ContinuousClock.now + .seconds(2)
            while contentRect == nil, ContinuousClock.now < changedDeadline {
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let rect = contentRect ?? initialRect
            #expect(rect.minY == initialRect.minY)
            #expect(reportedHeight == 300)
        }
    }
#endif
