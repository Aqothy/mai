import Foundation

/// What a native prepared row shows and how tall it is. Both platforms'
/// `ChatNativePreparedRow` present the same descriptor, so a row is native
/// on one exactly when it is on the other.
extension ChatNativePreparedRow {
    struct Descriptor: Equatable {
        let id: String
        let content: Content
        let top: CGFloat
        let bottom: CGFloat
    }

    static func descriptor(for row: ChatTimelineRenderRow) -> Descriptor? {
        let id: String
        let content: Content
        switch row {
        case .prose(let segment):
            guard segment.role == "assistant", segment.attachments?.isEmpty != false,
                segment.annotations?.isEmpty != false
            else { return nil }
            id = segment.rowID
            content = .prose(.source(segment.source))
        case .resolvedMarkdown(let block):
            guard block.attachments?.isEmpty != false else { return nil }
            id = block.rowID
            switch block.content {
            case .proseRun(let prose): content = .prose(.rendered(prose.text))
            case .code(let code): content = .code(code)
            case .table(let table): content = .table(table)
            }
        case .richMarkdown(let segment):
            guard segment.role == "assistant", segment.attachments?.isEmpty != false,
                segment.annotations?.isEmpty != false,
                let plan = ChatMarkdownRenderCache.shared.cachedPlan(
                    messageID: segment.rowID, source: segment.source),
                plan.blocks.count == 1, let block = plan.blocks.first
            else { return nil }
            // The SwiftUI renderer keys this block's layout the same way.
            id = "\(segment.rowID)-block-0"
            switch block {
            case .prose: return nil
            case .code(let code): content = .code(code)
            case .table(let table): content = .table(table)
            }
        case .standard: return nil
        }
        let insets = row.verticalInsets
        return Descriptor(id: id, content: content, top: insets.top, bottom: insets.bottom)
    }

    /// The prepared layouts already contain exact geometry, and the chrome
    /// around them is fixed metrics, so no native row is measured by
    /// building its SwiftUI counterpart.
    static func preparedHeight(
        for descriptor: Descriptor, width: CGFloat, store: ChatTextLayoutStore,
        theme: ChatCodeHighlightTheme
    ) -> CGFloat {
        let bodyHeight: CGFloat
        switch descriptor.content {
        case .prose(let text):
            bodyHeight = store.layout(
                id: descriptor.id, content: text, width: width).height
        case .table(let table):
            bodyHeight = store.tableLayout(id: descriptor.id, table: table).size.height
                + ChatRichBlockStyle.tableToolbarHeight
        case .code(let code):
            bodyHeight = ChatRichBlockStyle.codeHeaderHeight
                + store.codeLayout(id: descriptor.id, block: code, theme: theme).layout.height
                + ChatCodeBlockStyle.bottomInset
        }
        return ceil(bodyHeight + descriptor.top + descriptor.bottom)
    }
}
