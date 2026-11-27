import CoreGraphics
import Foundation

/// What assistive technologies read for each row (PLAN 7): message text as
/// static text, a finished turn's header as a button that expands or
/// collapses its work. Platform hosts make elements from these for the rows
/// near the viewport; native buttons (copy, fork) are elements of their own.
extension TranscriptController {
    struct AccessibleRow {
        let id: String
        let index: Int
        /// The row's frame in the document.
        let frame: CGRect
        let text: String
        /// A disclosure: pressing it toggles this turn's work.
        let expandsTurnID: String?
        let isExpanded: Bool
    }

    /// The rows overlapping `minY..<maxY` that read as something.
    func accessibleRows(minY: CGFloat, maxY: CGFloat, columnX: CGFloat) -> [AccessibleRow] {
        guard let range = geometry.indices(overlapping: max(0, minY), maxY) else { return [] }
        var result: [AccessibleRow] = []
        for index in range {
            let row = rows[index]
            let (top, height) = geometry.frame(at: index)
            let frame = CGRect(x: columnX, y: top, width: columnWidth, height: height)
            switch row.kind {
            case .turnHeader(let header):
                result.append(
                    AccessibleRow(
                        id: row.id, index: index, frame: frame, text: header.title,
                        expandsTurnID: header.isRunning ? nil : header.turnID, isExpanded: header.isExpanded))
            case .activity(let summary):
                result.append(
                    AccessibleRow(
                        id: row.id, index: index, frame: frame, text: summary, expandsTurnID: nil, isExpanded: false))
            case .working:
                result.append(
                    AccessibleRow(
                        id: row.id, index: index, frame: frame, text: "Agent working", expandsTurnID: nil,
                        isExpanded: false))
            default:
                guard let text = selectableText(ofRowAt: index), !text.isEmpty else { continue }
                let speaker: String
                switch row.kind {
                case .userMessage: speaker = "You: "
                case .pendingMessage(let message, _) where message.kind == .user: speaker = "You: "
                default: speaker = ""
                }
                result.append(
                    AccessibleRow(
                        id: row.id, index: index, frame: frame, text: speaker + text, expandsTurnID: nil,
                        isExpanded: false))
            }
        }
        return result
    }
}
