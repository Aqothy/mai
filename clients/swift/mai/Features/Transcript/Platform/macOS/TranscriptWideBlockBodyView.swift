#if os(macOS)
    import AppKit

    /// A wide block's body (code lines or a table's grid) inside its
    /// horizontal scroller.
    final class TranscriptWideBlockBodyView: NSView {
        private let row = RowLayer()

        // Constant, so AppKit's frequent calls skip the main-actor check.
        nonisolated override var isFlipped: Bool { true }

        /// Layer-hosting, like the transcript's rows view: the row layer is
        /// ours to manage.
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            let host = CALayer()
            host.isGeometryFlipped = true
            host.addSublayer(row)
            layer = host
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func show(
            rowID: String, body: WideBlockBody, key: RowLayoutKey, palette: TextPalette, scale: CGFloat,
            colorSpace: CGColorSpace, drawsOffMain: Bool, isVisible: Bool
        ) {
            let height = body.frame.height
            let layout = RowLayout(rowID: rowID, key: key, height: height, content: body.content)
            row.frame = CGRect(x: 0, y: 0, width: body.contentWidth, height: height)
            row.show(
                rowID: rowID, layout: layout, palette: palette, drawsWideBody: true, scale: scale, colorSpace: colorSpace)
            // On screen already, it draws now rather than show a blank block.
            row.drawBands(in: row.bounds, visible: isVisible ? row.bounds : .null, offMain: drawsOffMain)
        }

        /// Clicks select text in the transcript, whose document is the
        /// scroller's superview: selection spans rows, not one block.
        private var transcriptDocument: NSView? { enclosingScrollView?.superview }

        override func mouseDown(with event: NSEvent) {
            transcriptDocument?.mouseDown(with: event) ?? super.mouseDown(with: event)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            transcriptDocument?.menu(for: event)
        }

        func showSelection(_ range: Range<Int>?, color: CGColor) {
            row.showSelection(range, color: color)
        }

        func resetForReuse() {
            row.resetForReuse()
        }
    }
#endif
