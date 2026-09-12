#if os(macOS)
    import AppKit
    import Testing

    @testable import mai

    struct ChatSelectableTextViewConfigurationTests {
        @Test @MainActor
        func nativeCodeRemainsAccessible() {
            let host = ChatMacCodeBlockHostView(frame: .zero)
            let textView = host.documentView as? NSTextView
            #expect(textView != nil)
            #expect(textView?.isAccessibilityElement() == true)
            #expect(textView?.isSelectable == true)
        }

        @Test @MainActor
        func nativeTextViewOwnsOneSelectionTrackingArea() {
            let view = ChatSelectableTextViewConfiguration.makeTextView()
            view.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
            view.updateTrackingAreas()
            let original = view.trackingAreas.filter {
                $0.owner as AnyObject? === view
                    && $0.options.contains(.cursorUpdate)
                    && $0.options.contains(.inVisibleRect)
            }
            #expect(original.count == 1)

            for width in [500.0, 800.0, 700.0] {
                view.setFrameSize(NSSize(width: width, height: 400))
                view.updateTrackingAreas()
                view.resetCursorRects()
            }
            let updated = view.trackingAreas.filter {
                $0.owner as AnyObject? === view
                    && $0.options.contains(.cursorUpdate)
                    && $0.options.contains(.inVisibleRect)
            }
            #expect(updated.count == 1)
            #expect(view.isSelectable)
            #expect(!view.isEditable)
        }
    }
#endif
