#if os(iOS)
    import SwiftUI

    /// Keeps thread navigation responsive while preparing uncached Markdown
    /// segmentation before the transcript mounts. TextKit warming continues
    /// in the mounted timeline, and leaving releases its active layout store.
    struct ChatTimelineColdOpenGate: View {
        let threadID: String
        let timeline: [TimelineEntry]
        let timelineRevision: Int
        let plan: Plan?
        let latestTurn: Turn?
        let streamingTurnID: String?
        let segmentCache: ChatMarkdownSegmentCache
        let store: ThreadStore
        let scrollState: ChatScrollState

        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        var body: some View {
            ChatTimelineColdOpenGateContent(
                threadID: threadID,
                timeline: timeline,
                timelineRevision: timelineRevision,
                plan: plan,
                latestTurn: latestTurn,
                streamingTurnID: streamingTurnID,
                segmentCache: segmentCache,
                store: store,
                scrollState: scrollState
            )
            // Preferred fonts are baked into TextKit layouts.
            .id(dynamicTypeSize)
        }
    }

    private struct ChatTimelineColdOpenGateContent: View {
        let threadID: String
        let timeline: [TimelineEntry]
        let timelineRevision: Int
        let plan: Plan?
        let latestTurn: Turn?
        let streamingTurnID: String?
        let segmentCache: ChatMarkdownSegmentCache
        let store: ThreadStore
        let scrollState: ChatScrollState

        @State private var preparedSections: [ChatTimelineLayout.Section]?
        @State private var pendingSections: [ChatTimelineLayout.Section]?
        @State private var textLayoutStore = ChatTextLayoutStore()

        var body: some View {
            Group {
                if let preparedSections {
                    ChatTimeline(
                        threadID: threadID,
                        sections: preparedSections,
                        timelineEntryCount: timeline.count,
                        plan: plan,
                        latestTurn: latestTurn,
                        streamingTurnID: streamingTurnID,
                        segmentCache: segmentCache,
                        store: store,
                        scrollState: scrollState,
                        textLayoutStore: textLayoutStore
                    )
                } else {
                    ProgressView("Loading Chat…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task(id: threadID) {
                await prepareInitialPresentation()
            }
            .onChange(of: timelineRevision) { _, _ in
                let updatedSections = ChatTimelineLayout.sections(timeline: timeline)
                if preparedSections == nil {
                    // Streaming updates must not repeatedly cancel an expensive
                    // cold open. Mount the latest projection when it is ready.
                    pendingSections = updatedSections
                } else {
                    preparedSections = updatedSections
                }
            }
        }

        private func prepareInitialPresentation() async {
            guard preparedSections == nil else { return }

            await Task.yield()
            guard !Task.isCancelled else { return }

            let sections = ChatTimelineLayout.sections(timeline: timeline)
            let timelineRows = ChatTimelineLayout.rows(
                sections: sections,
                streamingTurnID: streamingTurnID,
                latestTurn: latestTurn,
                expandedSectionIDs: []
            )
            await segmentCache.prepare(
                requests: ChatTimeline.segmentationRequests(
                    in: timelineRows,
                    streamingTurnID: streamingTurnID
                )
            )
            guard !Task.isCancelled else { return }

            preparedSections = pendingSections ?? sections
            pendingSections = nil
        }
    }

#endif
