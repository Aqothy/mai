#if os(macOS)
    import AppKit
    import CoreGraphics
    import Foundation
    import Testing

    @testable import mai

    /// Mac selection through the document's own mouse handling (PLAN 5): a
    /// drag across rows, a double-click, a click without a drag. The events
    /// are queued first, so the document's tracking loop reads them as it
    /// would the reader's.
    @MainActor
    struct TranscriptMacSelectionTests {
        private struct Fixture {
            let window: NSWindow
            let document: TranscriptDocumentView
            let controller: TranscriptController

            func close() {
                window.contentView = nil
                window.close()
            }
        }

        private func make() -> Fixture {
            var configuration = TranscriptConfiguration(laysOutRows: true, cachesEnabled: false)
            configuration.concurrency = 1
            let controller = TranscriptController(configuration: configuration)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            scroll.hasVerticalScroller = false
            scroll.automaticallyAdjustsContentInsets = false
            let document = TranscriptDocumentView(controller: controller)
            scroll.documentView = document
            let window = NSWindow(
                contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            let blocks: [MarkdownBlock] = [
                .paragraph([MarkdownInline(text: "Alpha one two three")]),
                .paragraph([MarkdownInline(text: "Beta four five six")]),
            ]
            let rows = blocks.indices.map { index in
                TranscriptRow(
                    id: "m#\(index)", sourceID: "m", kind: .markdownBlock(blocks[index], .of(index, in: blocks)),
                    messageID: "m", role: .assistant)
            }
            controller.setRows(rows, measuredHeights: ["m#0": 60, "m#1": 60])
            document.layoutSubtreeIfNeeded()
            return Fixture(window: window, document: document, controller: controller)
        }

        /// A point on row `index`'s text, `fraction` along its first line, in
        /// window coordinates.
        private func point(_ fixture: Fixture, row index: Int, fraction: CGFloat) -> NSPoint {
            let controller = fixture.controller
            guard let layout = controller.layout(forRowAt: index, synchronously: true),
                let segment = layout.content.textSegments.first, let line = segment.layout.lines.first
            else { return .zero }
            let columnX = max(0, ((fixture.document.bounds.width - controller.columnWidth) / 2).rounded(.down))
            let documentPoint = NSPoint(
                x: columnX + segment.origin.x + line.x + line.width * fraction,
                y: controller.geometry.offset(at: index) + segment.origin.y + line.top + line.height / 2)
            return fixture.document.convert(documentPoint, to: nil)
        }

        private func event(_ type: NSEvent.EventType, _ window: NSWindow, at point: NSPoint, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }

        /// Queues `rest` and sends `down` to the document, which tracks them.
        private func click(_ fixture: Fixture, down: NSEvent, then rest: [NSEvent]) {
            for event in rest { NSApp.postEvent(event, atStart: false) }
            fixture.document.mouseDown(with: down)
        }

        @Test func aDragSelectsAcrossRows() {
            let fixture = make()
            defer { fixture.close() }
            let start = point(fixture, row: 0, fraction: 0.3)
            let end = point(fixture, row: 1, fraction: 0.5)
            click(
                fixture, down: event(.leftMouseDown, fixture.window, at: start),
                then: [
                    event(.leftMouseDragged, fixture.window, at: end), event(.leftMouseUp, fixture.window, at: end),
                ])
            let text = fixture.controller.selectedText()
            #expect(text.contains("two three\nBeta"))
            #expect(fixture.controller.selectedRange(inRowAt: 0) != nil)
            #expect(fixture.controller.selectedRange(inRowAt: 1) != nil)
        }

        @Test func aDoubleClickSelectsAWordAndAClickClearsIt() {
            let fixture = make()
            defer { fixture.close() }
            let word = point(fixture, row: 1, fraction: 0.35)
            click(
                fixture, down: event(.leftMouseDown, fixture.window, at: word, clicks: 2),
                then: [event(.leftMouseUp, fixture.window, at: word, clicks: 2)])
            #expect(["four", "five"].contains(fixture.controller.selectedText()))

            click(
                fixture, down: event(.leftMouseDown, fixture.window, at: word),
                then: [event(.leftMouseUp, fixture.window, at: word)])
            #expect(fixture.controller.selection == nil)
        }
    }
#endif
