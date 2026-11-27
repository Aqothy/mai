import Foundation

/// The size of a row's text, which its estimated height is made from
/// (`HeightEstimator`): counted once off the main thread where message rows
/// are parsed (`LayoutQueue`, `TranscriptStreamWorker`), so estimating a row
/// on the main thread is O(1) and never scans text.
nonisolated struct TextMetrics: Hashable, Sendable {
    var bytes = 0
    var lines = 0
    var blocks = 0
    /// Exact selectable UTF-16 length, precomputed off-main for parsed rows so
    /// `TranscriptController.offset(from:to:)` stays O(1) per row.
    var selectableUTF16: Int?

    init(_ kind: TranscriptRowKind) {
        switch kind {
        case .markdownBlock(let block, _):
            add(block)
            blocks = 1
            selectableUTF16 = RowSelectableText.utf16Length(for: kind)
        case .userMessage(let blocks), .thought(let blocks):
            for block in blocks { add(block) }
            self.blocks = blocks.count
            selectableUTF16 = RowSelectableText.utf16Length(for: kind)
        case .pendingMessage(_, let source):
            bytes = source.utf8.count
        case .notice(let title, let text):
            bytes = title.utf8.count + (text?.utf8.count ?? 0)
            selectableUTF16 = RowSelectableText.utf16Length(for: kind)
        case .activity, .turnHeader, .turnActions, .working:
            break
        }
    }

    func wrappedLines(perLine: Double) -> Double {
        max(Double(max(1, lines)), Double(bytes) / perLine + Double(lines) / 2)
    }

    private mutating func add(_ block: MarkdownBlock) {
        switch block {
        case .paragraph(let inlines), .heading(_, let inlines):
            lines += 1
            for inline in inlines { add(inline.text) }
        case .code(_, let code):
            lines += 1
            add(code)
        case .list(let list):
            for item in list.items {
                for child in item.blocks { add(child) }
            }
        case .quote(let children):
            for child in children { add(child) }
        case .table(let table):
            lines += table.rows.count + 1
        case .rule:
            lines += 1
        }
    }

    private mutating func add(_ text: String) {
        var newlines = 0
        for byte in text.utf8 where byte == 0x0A { newlines += 1 }
        lines += newlines
        bytes += text.utf8.count - newlines
    }
}
