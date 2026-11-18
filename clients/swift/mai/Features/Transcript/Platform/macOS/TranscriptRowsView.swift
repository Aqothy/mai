#if os(macOS)
    import AppKit
    import QuartzCore

    /// Holds the transcript's row layers, as tall as the document. A
    /// layer-hosting view (its layer set before `wantsLayer`): AppKit keeps a
    /// layer-backed view's sublayers in step with its subviews, which dropped
    /// row layers added beside the code scrollers, while a hosted layer tree
    /// is ours. Events pass through to the document.
    final class TranscriptRowsView: NSView {
        let rowsLayer = CALayer()

        // Constant, so AppKit's frequent calls skip the main-actor check.
        nonisolated override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            // A layer's own flag orders its sublayers: rows top-down.
            rowsLayer.isGeometryFlipped = true
            rowsLayer.actions = ["sublayers": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer = rowsLayer
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
#endif
