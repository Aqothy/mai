#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing
    @testable import mai

    struct ChatNativeSelectionReuseTests {
        /// The live reply tail renders in TextKit, so a reader's selection
        /// must survive every streamed append into that same text view.
        @Test @MainActor
        func liveProseKeepsSelectionWhileTextAppends() throws {
            let layouts = ChatTextLayoutStore()
            let host = ChatSelectableTextHostView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
            var planner = ChatIncrementalMarkdownRenderPlanner()
            func stream(_ source: String) throws -> NSTextView {
                let snapshot = planner.snapshot(source: source, sourceIsAppendOnly: true)
                let prose: ChatMarkdownProseRun? =
                    if case .prose(let live)? = snapshot.plan.blocks.last { live } else { nil }
                let live = try #require(prose, "Live tail is not prose")
                host.update(layoutID: "live", content: .rendered(live.text), layoutStore: layouts)
                host.layoutSubtreeIfNeeded()
                return try #require(host.subviews.compactMap { $0 as? NSTextView }.first)
            }
            let text = try stream("Streaming **bold** reply")
            text.setSelectedRange(NSRange(location: 0, length: 9))
            let grown = try stream("Streaming **bold** reply that keeps *grow")
            #expect(grown === text)
            #expect(text.string == "Streaming bold reply that keeps grow")
            #expect(text.selectedRange() == NSRange(location: 0, length: 9))
        }

        @Test @MainActor
        func referenceSelectionSurvivesRealVirtualizationAndRejectsStaleMenus() async throws {
            let model = ChatAnnotationModel()
            let layouts = ChatTextLayoutStore()
            let cache = ChatMarkdownSegmentCache()
            let messages = (0..<40).map { index in
                Message(
                    annotations: nil, attachments: nil, createdAt: .now,
                    id: "reference-message-\(index)", role: "assistant",
                    text: "Quote \(index) café 👩🏽‍💻 [Guide][ref].\n\n[ref]: https://example.com/guide/\(index)",
                    turnID: nil, updatedAt: .now)
            }
            let rows = ChatTimeline.renderRows(messages.map(ChatTimelineRowModel.message), streamingTurnID: nil, segmentCache: cache)
            let descriptors = try rows.map { try #require(ChatNativePreparedRow.descriptor(for: $0)) }
            #expect(rows.count == messages.count)
            let document = ChatNativeTranscript<EmptyView>.VirtualDocument()
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 200))
            scroll.documentView = document
            var reusedCount = 0
            document.nativeRowFactory = { index, reused in
                if reused is ChatNativePreparedRow { reusedCount += 1 }
                let host = reused as? ChatNativePreparedRow ?? ChatNativePreparedRow(frame: .zero)
                host.update(descriptors[index], width: 360, store: layouts, theme: .light,
                            annotationContext: rows[index].annotationContext(model: model))
                return host
            }
            document.install(heights: Array(repeating: 120, count: rows.count), width: 360, ids: rows.map(\.id)) { _ in EmptyView() }
            defer {
                document.preparationTask?.cancel()
                document.heightUpdateTask?.cancel()
                document.geometryNotificationTask?.cancel()
            }
            await document.preparationTask?.value

            @MainActor func textView(at index: Int) throws -> ChatAnnotationTextView {
                let host = try #require(document.hosts[index] as? ChatNativePreparedRow)
                host.layoutSubtreeIfNeeded()
                let body = try #require(host.subviews.compactMap { $0 as? ChatSelectableTextHostView }.first)
                return try #require(body.subviews.compactMap { $0 as? ChatAnnotationTextView }.first)
            }
            @MainActor func menuItem(for text: ChatAnnotationTextView, index: Int) throws -> NSMenuItem {
                let quote = "Quote \(index) café 👩🏽‍💻"
                let range = (text.string as NSString).range(of: quote)
                try #require(range.location != NSNotFound)
                text.setSelectedRange(range)
                let guide = (text.string as NSString).range(of: "Guide")
                try #require(guide.location != NSNotFound)
                let link = text.textStorage?.attribute(.link, at: guide.location, effectiveRange: nil) as? URL
                #expect(link?.absoluteString == "https://example.com/guide/\(index)")
                let menu = NSMenu()
                text.appendComment(to: menu)
                return try #require(menu.items.last)
            }

            let original = try textView(at: 0)
            let stale = try menuItem(for: original, index: 0)
            original.comment(stale)
            #expect(model.editorDraft?.messageID == messages[0].id)
            #expect(model.editorDraft?.quote == "Quote 0 café 👩🏽‍💻")
            model.cancelEditor()

            for index in [20, 35, 5, 28, 0] {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(index) * 120))
                document.viewportChanged()
                await document.preparationTask?.value
                let text = try textView(at: index)
                #expect(text.selectedRange().length == 0)
                if index != 0 {
                    original.comment(stale)
                    #expect(model.editorDraft == nil)
                }
                let item = try menuItem(for: text, index: index)
                text.comment(item)
                #expect(model.editorDraft?.messageID == messages[index].id)
                #expect(model.editorDraft?.quote == "Quote \(index) café 👩🏽‍💻")
                #expect(model.editorDraft?.role == "assistant")
                model.editorDraft?.note = " Explain \(index) "
                model.addEditorDraft()
                #expect(model.annotations.last?.note == "Explain \(index)")
            }
            #expect(reusedCount > 0)
            #expect(document.hosts.count < rows.count)
            #expect(model.annotations.count == 5)

            // Native provider item IDs can repeat in another chat. The model
            // identity prevents an old menu from adding to that chat's draft.
            let current = try textView(at: 0)
            let oldChatMenu = try menuItem(for: current, index: 0)
            let otherChat = ChatAnnotationModel()
            let host = try #require(document.hosts[0] as? ChatNativePreparedRow)
            host.update(descriptors[0], width: 360, store: layouts, theme: .light,
                        annotationContext: rows[0].annotationContext(model: otherChat))
            current.comment(oldChatMenu)
            #expect(model.editorDraft == nil)
            #expect(otherChat.editorDraft == nil)
            current.comment(try menuItem(for: current, index: 0))
            #expect(otherChat.editorDraft?.messageID == messages[0].id)
            #expect(otherChat.editorDraft?.quote == "Quote 0 café 👩🏽‍💻")
        }
    }
#endif
