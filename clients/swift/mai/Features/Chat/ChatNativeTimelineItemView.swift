#if os(macOS)
    import SwiftUI

    struct ChatNativeTimelineItemView: View {
        let item: ChatNativeTimelineItem
        let streamingTurnID: String?
        let threadID: String
        let store: ThreadStore
        let foldModel: ChatTimelineFoldModel
        let scrollState: ChatScrollState
        let textLayoutStore: ChatTextLayoutStore

        var body: some View {
            switch item {
            case .historyMarker:
                Color.clear.frame(height: ChatTimelineMetrics.historyMarkerHeight)
            case .plan(let plan):
                ChatPlanRow(plan: plan).padding(.vertical, ChatTimelineMetrics.rowVerticalInset)
            case .row(let row):
                ChatTimelineRenderRowView(
                    row: row, streamingTurnID: streamingTurnID,
                    threadID: threadID, store: store, foldModel: foldModel,
                    scrollState: scrollState, textLayoutStore: textLayoutStore)
            case .working(let key):
                ChatWorkingIndicator(activityKey: key).padding(
                    .vertical, ChatTimelineMetrics.rowVerticalInset)
            case .endMarker:
                ChatEndMarker()
            }
        }
    }
#endif
