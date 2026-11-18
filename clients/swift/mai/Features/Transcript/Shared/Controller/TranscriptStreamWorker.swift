import CoreGraphics
import Foundation

/// Parses streaming messages and lays out the blocks that changed, off the
/// main thread, one update per frame at most. Each message keeps its own
/// parser, so finished blocks are parsed once (PLAN 6).
actor TranscriptStreamWorker {
    struct Update: Sendable {
        let messageID: String
        let text: String
        let isFinished: Bool
        let width: CGFloat
        let style: TextStyle
        /// The colors of the message's highlighted code rows, by row id, and
        /// the theme shown: a closed block laid out again keeps them.
        let codeColors: [String: CodeColors]
        let isDark: Bool?
    }

    struct Result: Sendable {
        let messageID: String
        /// The text this result shows, so a newer one is never replaced by
        /// an older.
        let textLength: Int
        let isFinished: Bool
        let blocks: [MarkdownBlock]
        /// Layouts of the rows that changed, with the row kind each is for.
        let layouts: [(index: Int, kind: TranscriptRowKind, layout: RowLayout)]
    }

    private var parsers: [String: StreamingMarkdownParser] = [:]
    private var lastKinds: [String: [TranscriptRowKind]] = [:]
    private var lastWidth: [String: CGFloat] = [:]

    func run(_ update: Update) -> Result {
        var parser = parsers[update.messageID] ?? StreamingMarkdownParser()
        let blocks = update.isFinished ? parser.finish(update.text) : parser.update(update.text).blocks
        parsers[update.messageID] = update.isFinished ? nil : parser
        let kinds = blocks.enumerated().map { index, block in
            TranscriptRowKind.markdownBlock(
                block, .of(index, in: blocks))
        }
        let previous = lastWidth[update.messageID] == update.width ? lastKinds[update.messageID] ?? [] : []
        var layouts: [(index: Int, kind: TranscriptRowKind, layout: RowLayout)] = []
        for (index, kind) in kinds.enumerated() where index >= previous.count || previous[index] != kind {
            let rowID = "\(update.messageID)#\(index)"
            var request = RowLayoutRequest(
                rowID: rowID, kind: kind,
                key: RowLayoutKey(contentVersion: -1, width: update.width, styleVersion: update.style.version),
                style: update.style)
            if case .markdownBlock(.code(_, let code), _) = kind, let isDark = update.isDark,
                let colors = update.codeColors[rowID], colors.matches(code: code, isDark: isDark)
            {
                request.codeColors = colors
            }
            layouts.append((index, kind, RowLayoutBuilder.layout(request)))
        }
        if update.isFinished {
            lastKinds[update.messageID] = nil
            lastWidth[update.messageID] = nil
        } else {
            lastKinds[update.messageID] = kinds
            lastWidth[update.messageID] = update.width
        }
        return Result(
            messageID: update.messageID, textLength: update.text.utf8.count, isFinished: update.isFinished,
            blocks: blocks, layouts: layouts)
    }
}
