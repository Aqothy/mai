import SwiftUI

/// The active row reports its ideal height without rebuilding the transcript.
struct ChatMeasuredTranscriptRow<Content: View>: View {
    /// The row shown. A pooled hosting view keeps this view's identity
    /// across rows, and `onGeometryChange` reports only a change: a row
    /// that happens to be as tall as the previous one would never report,
    /// and an offscreen measurement that missed would stand.
    let id: String
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
            .id(id)
    }
}
