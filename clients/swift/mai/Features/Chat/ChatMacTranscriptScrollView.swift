#if os(macOS)
    import AppKit

    /// The transcript's scroll view. Tiling is where AppKit applies a new
    /// size or new content insets to the clip view, and a change to either
    /// can leave the clip's bounds origin, and so its notifications, as they
    /// were.
    final class ChatMacTranscriptScrollView: NSScrollView {
        var onTile: (() -> Void)?

        override func tile() {
            super.tile()
            onTile?()
        }
    }
#endif
