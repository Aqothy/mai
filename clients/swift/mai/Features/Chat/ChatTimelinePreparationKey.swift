import Foundation

struct ChatTimelinePreparationKey: Equatable {
    let timelineEntryCount: Int
    let streamingTurnID: String?
    let rowWidth: CGFloat
    /// Highlighted code is prepared per appearance.
    let codeTheme: ChatCodeHighlightTheme
    /// Layouts bake their fonts in; a new store means none of them exist.
    let layoutStore: ObjectIdentifier
    let expandedSectionIDs: Set<String>
    /// Loading earlier history changes which rows exist without changing the
    /// counts above; preparation must re-run over the widened window or a
    /// later width change only prepares the rows captured at the old window.
    let oldestLoadedSectionID: String?
}
