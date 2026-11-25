import CoreGraphics
import Foundation

/// A row's selectable text without its layout: what copy reads for rows far
/// from the viewport, whose layouts were dropped. Built by the same code the
/// layout's text comes from, so offsets agree (`RowContentLayout.selectableString`).
nonisolated enum RowSelectableText {
    static func string(for kind: TranscriptRowKind, style: TextStyle) -> String? {
        switch kind {
        case .markdownBlock(.code(_, let code), _):
            return code
        case .markdownBlock(.table(let table), _):
            return TableLayout.tabSeparatedText(table)
        case .markdownBlock(let block, _):
            return AttributedTextBuilder.build([block], style: style).string.string
        case .userMessage(let source, _):
            return AttributedTextBuilder.build(MarkdownPlanner.blocks(from: source), style: style).string.string
        case .pendingMessage(let source):
            return source
        case .thought(let text):
            return text
        case .notice(let title, let text):
            guard let text, !text.isEmpty else { return title }
            return title + "\n" + text
        case .activity, .turnHeader, .turnActions, .working:
            return nil
        }
    }
}
