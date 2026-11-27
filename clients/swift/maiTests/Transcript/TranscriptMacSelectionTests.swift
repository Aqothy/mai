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
            var configuration = TranscriptConfiguration(laysOutRows: true)
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
            for row in controller.rows {
                let layout = RowLayoutBuilder.layout(controller.request(row))
                controller.storeLayout(layout)
            }
            controller.setHeights(Dictionary(uniqueKeysWithValues: controller.layouts.map { ($0.key, $0.value.height) }))
            controller.alignInitialEndIfPossible()
            document.layoutSubtreeIfNeeded()
            return Fixture(window: window, document: document, controller: controller)
        }

        /// A point on row `index`'s text, `fraction` along its first line, in
        /// window coordinates.
        private func point(_ fixture: Fixture, row index: Int, fraction: CGFloat) -> NSPoint {
            let controller = fixture.controller
            guard let layout = controller.layout(forRowAt: index),
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

        /// A click whose pointer wobbles a point or two is a click: it clears
        /// the selection (and opens a link) instead of selecting a character.
        @Test func aClickThatWobblesStillClearsTheSelection() {
            let fixture = make()
            defer { fixture.close() }
            let word = point(fixture, row: 1, fraction: 0.35)
            click(
                fixture, down: event(.leftMouseDown, fixture.window, at: word, clicks: 2),
                then: [event(.leftMouseUp, fixture.window, at: word, clicks: 2)])
            #expect(fixture.controller.selection != nil)
            guard let layout = fixture.controller.layout(forRowAt: 0),
                let textLayout = layout.content.textSegments.first?.layout,
                let line = textLayout.lines.first
            else { return }
            let carets = textLayout.caretOffsets(forLineAt: 0)
            // Across the midpoint between two characters' carets.
            let start = point(fixture, row: 0, fraction: 0)
            let x = start.x - line.x + (carets[2] + carets[3]) / 2
            let down = NSPoint(x: x - 0.75, y: start.y)
            let up = NSPoint(x: x + 0.75, y: start.y)
            click(
                fixture, down: event(.leftMouseDown, fixture.window, at: down),
                then: [event(.leftMouseDragged, fixture.window, at: up), event(.leftMouseUp, fixture.window, at: up)])
            #expect(fixture.controller.selection == nil)
        }

        /// Rows that go away take their layers with them, all of them too.
        @Test func clearingTheRowsUnmountsThem() {
            let fixture = make()
            defer { fixture.close() }
            func rowLayers() -> [RowLayer] {
                let rows = fixture.document.subviews.compactMap { $0 as? TranscriptRowsView }.first
                return rows?.rowsLayer.sublayers?.compactMap { $0 as? RowLayer } ?? []
            }
            fixture.document.needsLayout = true
            fixture.document.layoutSubtreeIfNeeded()
            #expect(!rowLayers().isEmpty)
            fixture.controller.setRows([])
            fixture.document.layoutSubtreeIfNeeded()
            #expect(rowLayers().isEmpty)
        }

        /// Right-clicking empty margin or chrome must not snap to an adjacent
        /// row and select its word; right-clicking a link offers Open Link and
        /// Copy Link alongside Copy/Look Up/Share.
        @Test func rightClickUsesStrictHitTestAndOffersLinkActions() throws {
            let fixture = make()
            defer { fixture.close() }
            let url = try #require(URL(string: "https://example.com/docs"))
            let linkBlock = MarkdownBlock.paragraph([
                MarkdownInline(text: "Visit "),
                MarkdownInline(text: "docs", style: [], link: url),
                MarkdownInline(text: " now"),
            ])
            let rows = [
                TranscriptRow(
                    id: "m#0", sourceID: "m", kind: .markdownBlock(linkBlock, .single),
                    messageID: "m", role: .assistant),
                TranscriptRow(id: "actions|t", kind: .turnActions(turnID: "t", hasReply: true)),
            ]
            fixture.controller.setRows(rows, measuredHeights: ["m#0": 60, "actions|t": 40])
            for row in fixture.controller.rows {
                fixture.controller.storeLayout(RowLayoutBuilder.layout(fixture.controller.request(row)))
            }
            fixture.controller.setHeights(
                Dictionary(uniqueKeysWithValues: fixture.controller.layouts.map { ($0.key, $0.value.height) }))
            fixture.document.layoutSubtreeIfNeeded()

            // Right-click over the actions row (chrome below text): must not select text.
            let chromePoint = fixture.document.convert(NSPoint(x: 100, y: fixture.controller.geometry.offset(at: 1) + 15), to: nil)
            let chromeMenu = fixture.document.menu(for: event(.rightMouseDown, fixture.window, at: chromePoint))
            #expect(chromeMenu == nil)
            #expect(fixture.controller.selection == nil)

            // Right-click directly over the link word "docs".
            let linkPoint = point(fixture, row: 0, fraction: 0.52)
            let linkMenu = try #require(fixture.document.menu(for: event(.rightMouseDown, fixture.window, at: linkPoint)))
            let titles = linkMenu.items.map(\.title)
            #expect(titles.contains("Open Link"))
            #expect(titles.contains("Copy Link"))
            #expect(titles.contains("Copy"))
            #expect(titles.contains("Look Up"))

            // Right-clicking the right edge of a multi-word selection must preserve
            // the whole selection instead of collapsing to the last word.
            fixture.controller.setSelection(
                TranscriptSelection(
                    anchor: TextPosition(rowID: "m#0", offset: 0),
                    focus: TextPosition(rowID: "m#0", offset: 14)))
            let endPoint = point(fixture, row: 0, fraction: 0.99)
            _ = fixture.document.menu(for: event(.rightMouseDown, fixture.window, at: endPoint))
            #expect(fixture.controller.selectedText() == "Visit docs now")
        }

        /// `NSViewContentSelectionInfo` exposes the selection's anchor rect,
        /// `NSServicesMenuRequestor` writes plain text (including legacy
        /// `NSStringPboardType`), and Escape clears the selection.
        @Test func selectionInfoServicesAndKeyboardNavigation() throws {
            let fixture = make()
            defer { fixture.close() }
            #expect(fixture.document.selectionAnchorRect.isNull)
            #expect(
                fixture.document.validRequestor(
                    forSendType: TranscriptDocumentView.legacyStringPboardType, returnType: nil) == nil)

            // Select text in row 0.
            let word = point(fixture, row: 0, fraction: 0.1)
            click(
                fixture, down: event(.leftMouseDown, fixture.window, at: word, clicks: 2),
                then: [event(.leftMouseUp, fixture.window, at: word, clicks: 2)])
            #expect(!fixture.document.selectionAnchorRect.isNull)
            #expect(
                fixture.document.validRequestor(
                    forSendType: TranscriptDocumentView.legacyStringPboardType, returnType: nil) != nil)
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            #expect(
                fixture.document.writeSelection(
                    to: pasteboard, types: [TranscriptDocumentView.legacyStringPboardType]))
            #expect(pasteboard.string(forType: .string) == fixture.controller.selectedText())

            // Escape clears selection.
            let esc = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                    context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                    isARepeat: false, keyCode: 53))
            fixture.document.keyDown(with: esc)
            #expect(fixture.controller.selection == nil)

            // Tab must forward to super.keyDown instead of being swallowed
            // inside `interpretKeyEvents`.
            fixture.window.makeFirstResponder(fixture.document)
            let tab = try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                    context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
                    isARepeat: false, keyCode: 48))
            fixture.document.keyDown(with: tab)
            #expect(!fixture.document.didHandleKeyCommand)
        }
    }
#endif
