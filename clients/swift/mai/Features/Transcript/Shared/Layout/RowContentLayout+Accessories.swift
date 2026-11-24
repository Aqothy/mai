import CoreGraphics
import Foundation

/// Where a row's native controls go (PLAN 4.5): a code block's copy button
/// on its header line, a table's in its toolbar, a finished turn's copy-reply
/// button and fork menu at the start of its action row.
nonisolated extension RowContentLayout {
    func accessories(forRowID rowID: String) -> [RowAccessory] {
        let size = RowAccessory.size
        switch self {
        case .code(let code, let frame):
            guard !code.position.joinsAbove else { return [] }
            let lineCenter = frame.minY + code.labelTop + code.label.size.height / 2
            let action: RowAccessory.Action =
                code.position.joinsBelow ? .copyChunkedCode(rowID: rowID) : .copy(text: code.code, label: "Copy code")
            return [
                RowAccessory(
                    action: action,
                    frame: CGRect(
                        x: frame.maxX - code.bodyOrigin.x + 4 - size, y: (lineCenter - size / 2).rounded(),
                        width: size, height: size))
            ]
        case .table(let table, let frame):
            return [
                RowAccessory(
                    action: .copy(text: selectableString, label: "Copy table"),
                    frame: CGRect(
                        x: frame.maxX - size, y: frame.minY + ((table.toolbarHeight - size) / 2).rounded(),
                        width: size, height: size))
            ]
        case .actions(let turnID, let hasReply, let origin):
            var accessories: [RowAccessory] = []
            var x = origin.x
            if hasReply {
                accessories.append(
                    RowAccessory(
                        action: .copyReply(turnID: turnID),
                        frame: CGRect(x: x, y: origin.y, width: size, height: size)))
                x += size + 4
            }
            accessories.append(
                RowAccessory(action: .fork(turnID: turnID), frame: CGRect(x: x, y: origin.y, width: size, height: size)))
            return accessories
        default:
            return []
        }
    }
}
