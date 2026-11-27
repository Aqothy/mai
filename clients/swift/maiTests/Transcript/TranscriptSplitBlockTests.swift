import CoreGraphics
import Foundation
import Testing

#if os(macOS)
    import AppKit
#endif

@testable import mai

/// A wide code block keeps its sideways scroll offset across remounts, as a
/// browser keeps an element's `scrollLeft`, without leaking into pooled
/// scrollers reused for other blocks.
nonisolated struct TranscriptSplitBlockTests {
    #if os(macOS)
        @MainActor @Test func wideCodeBlockKeepsSidewaysOffsetAcrossRemounts() {
            let controller = TranscriptController(configuration: .testing)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 600))
            scroll.automaticallyAdjustsContentInsets = false
            let document = TranscriptDocumentView(controller: controller)
            scroll.documentView = document
            let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            defer {
                window.contentView = nil
                window.close()
            }
            let code = (0..<12).map { "line \($0) " + String(repeating: "x", count: 10_000) }.joined(separator: "\n")
            let row = TranscriptRow(
                id: "m#0", sourceID: "m", kind: .markdownBlock(.code(language: nil, code: code), .single),
                messageID: "m", role: .assistant, turnID: "t")
            controller.setRows([row])
            let layout = RowLayoutBuilder.layout(controller.request(row))
            controller.storeLayout(layout)
            controller.setHeights([row.id: layout.height])
            controller.alignInitialEndIfPossible()
            document.layoutSubtreeIfNeeded()
            guard let scroller = document.wideBlocks[row.id] else {
                Issue.record("expected wide block scroller")
                return
            }
            #expect(scroller.hasHorizontalScroller)

            scroller.contentView.scroll(to: NSPoint(x: 700, y: 0))
            #expect(controller.wideBlockOffsets[row.id] == 700)

            // Unmounted and mounted again, the block starts where it was left.
            let body = layout.content.wideBody
            document.removeWideBlock(rowID: row.id)
            if let body {
                document.showWideBlock(
                    rowID: row.id, body: body, key: layout.key,
                    origin: .zero, drawn: .null, visible: .null, streamed: nil)
            }
            #expect(document.wideBlocks[row.id]?.scrollX == 700)

            // Reusing that pooled scroller for a narrower block must not leak
            // its clamped old offset into the new block's stored offset.
            let narrow = TranscriptRow(
                id: "narrow#0",
                kind: .markdownBlock(.code(language: nil, code: String(repeating: "x", count: 120)), .single))
            let narrowLayout = RowLayoutBuilder.layout(controller.request(narrow))
            document.removeWideBlock(rowID: row.id)
            if let narrowBody = narrowLayout.content.wideBody {
                document.showWideBlock(
                    rowID: narrow.id, body: narrowBody, key: narrowLayout.key,
                    origin: .zero, drawn: .null, visible: .null, streamed: nil)
            }
            #expect(controller.wideBlockOffsets[narrow.id] == nil)
            #expect(document.wideBlocks[narrow.id]?.scrollX == 0)
        }
    #endif
}
