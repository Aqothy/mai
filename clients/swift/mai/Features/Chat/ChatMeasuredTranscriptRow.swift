#if os(macOS)
    import SwiftUI

    /// The active row reports its ideal height without rebuilding the transcript.
    struct ChatMeasuredTranscriptRow<Content: View>: View {
        let content: Content
        let heightChanged: (CGFloat) -> Void

        var body: some View {
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    ceil(geometry.size.height)
                } action: { height in
                    heightChanged(height)
                }
                // A growing row can briefly be taller than its allocated AppKit
                // frame. Keep its origin stable while the extent catches up.
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        }
    }
#endif
