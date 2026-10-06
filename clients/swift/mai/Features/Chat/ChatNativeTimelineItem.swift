#if os(macOS)
    import SwiftUI

    enum ChatNativeTimelineItem: Identifiable {
        case historyMarker
        case plan(Plan)
        case row(ChatTimelineRenderRow)
        case working(String?)
        case endMarker

        var id: String {
            switch self {
            case .historyMarker: ChatTimelineBoundaryID.history
            case .plan: "chat-plan"
            case .row(let row): row.id
            case .working: "chat-working-indicator"
            case .endMarker: ChatTimelineBoundaryID.bottom
            }
        }

        var measurementKey: ChatNativeRowMeasurementKey? {
            if case .row(let row) = self { row.nativeMeasurementKey } else { nil }
        }

        static func items(
            rows: [ChatTimelineRenderRow], plan: Plan?, hasEarlierSections: Bool, isStreaming: Bool
        ) -> [Self] {
            var result: [Self] = []
            if hasEarlierSections { result.append(.historyMarker) }
            if !hasEarlierSections, let plan, !plan.entries.isEmpty { result.append(.plan(plan)) }
            result += rows.map(Self.row)
            if isStreaming { result.append(.working(rows.last?.id)) }
            result.append(.endMarker)
            return result
        }
    }
#endif
