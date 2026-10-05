#if os(macOS)
    import AppKit
    import Testing
    @testable import mai

    struct ChatNativePreparedRowTests {
        @Test @MainActor func reuseChangesContentAndClearsSelectionAcrossRowKinds() throws {
            let store = ChatTextLayoutStore()
            let host = ChatNativePreparedRow(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
            func render(_ content: ChatNativePreparedRow.Content, id: String) {
                host.update(
                    .init(id: id, content: content, top: 0, bottom: 0), width: 300, store: store,
                    theme: .light)
                host.layoutSubtreeIfNeeded()
            }
            render(.prose("First selectable message"), id: "first")
            let prose = try #require(host.subviews.first { $0 is ChatSelectableTextHostView })
            let text = try #require(prose.subviews.compactMap { $0 as? NSTextView }.first)
            text.setSelectedRange(NSRange(location: 0, length: 5))
            render(
                .code(.init(code: "let first = 1", language: "swift")), id: "code-a")
            let code = try #require(
                host.subviews.compactMap { $0 as? ChatMacCodeBlockHostView }.first)
            let children = try #require(host.accessibilityChildren())
            #expect(
                (children.first as? NSObject)
                    === (NSAccessibility.unignoredDescendant(of: host.subviews[0]) as? NSObject))
            #expect(children.count == 3)
            #expect(
                (children[1] as? NSObject)
                    === (NSAccessibility.unignoredDescendant(of: host.subviews[1]) as? NSObject))
            #expect((children[2] as? NSView) === code)

            render(
                .table(
                    .init(
                        alignments: [.leading], header: [AttributedString("Header")],
                        rows: [[AttributedString("Value")]])), id: "table")
            render(.prose("Second selectable message"), id: "second")
            #expect(host.subviews.contains { $0 === prose })
            #expect(text.string == "Second selectable message")
            #expect(
                NSAccessibility.unignoredChildren(from: [host]).contains {
                    ($0 as? NSObject) === text
                })
            #expect(text.selectedRange().length == 0)
            render(
                .code(.init(code: "let second = 2", language: "swift")), id: "code-b"
            )
            #expect(host.subviews.contains { $0 === code })
            let codeText = try #require(code.documentView as? NSTextView)
            #expect(codeText.string == "let second = 2")
            #expect(codeText.selectedRange().length == 0)
            #expect(code.contentView.bounds.minX == 0)
            code.dismantle()
        }
    }
#endif
