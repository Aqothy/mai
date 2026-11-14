import SwiftUI

/// The active row reports its ideal height without rebuilding the transcript.
struct ChatMeasuredTranscriptRow<Content: View>: View {
    /// The row's revision in the document; see `ChatTranscriptRowRevisions`.
    let revision: Int
    let content: Content
    let heightChanged: (CGFloat) -> Void

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: ChatMeasuredTranscriptRowReport.self) { [revision] geometry in
                ChatMeasuredTranscriptRowReport(
                    height: ceil(geometry.size.height), revision: revision)
            } action: { report in
                heightChanged(report.height)
            }
            // A growing row can briefly be taller than its allocated AppKit
            // frame. Keep its origin stable while the extent catches up.
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
    }
}
