import CoreGraphics
import Foundation

/// Parses streaming messages and lays out and draws the blocks that
/// changed, off the main thread, one update per frame at most. Each message
/// keeps its own parser, so finished blocks are parsed once (PLAN 6). A
/// block's new layout comes with its changed bands drawn: the main thread
/// shows both in one frame, as a browser lays out and paints a frame
/// together, so a block never shows its old text in its new size.
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
        /// What to draw with; nil until the host has a palette (the rows
        /// then draw their bands themselves).
        let drawing: Drawing?
    }

    struct Drawing: Sendable {
        let palette: TextPalette
        let scale: CGFloat
        let colorSpace: CGColorSpace
    }

    struct Row: Sendable {
        let index: Int
        let kind: TranscriptRowKind
        let layout: RowLayout
        let drawn: DrawnBands?
    }

    struct Result: Sendable {
        let messageID: String
        /// The text this result shows, so a newer one is never replaced by
        /// an older.
        let textLength: Int
        let isFinished: Bool
        let blocks: [MarkdownBlock]
        /// The width and style version the rows were laid out at.
        let width: CGFloat
        let styleVersion: Int
        /// The rows that changed.
        let rows: [Row]
    }

    private struct ShownState {
        let width: CGFloat
        let styleVersion: Int
        /// Committed blocks whose `isLast` position is already settled (never
        /// change on later appends at the same width/style).
        let stableCount: Int
        let parserResetCount: Int
        let rows: [(kind: TranscriptRowKind, layout: RowLayout)]
    }

    private var parsers: [String: StreamingMarkdownParser] = [:]
    private var shown: [String: ShownState] = [:]

    func run(_ update: Update) -> Result {
        var parser = parsers[update.messageID] ?? StreamingMarkdownParser()
        let blocks: [MarkdownBlock]
        let committedCount: Int
        if update.isFinished {
            blocks = parser.finish(update.text)
            committedCount = blocks.count
            parsers[update.messageID] = nil
        } else {
            let snapshot = parser.update(update.text)
            blocks = snapshot.blocks
            committedCount = snapshot.committed.count
            parsers[update.messageID] = parser
        }
        let state = shown[update.messageID].flatMap {
            $0.width == update.width && $0.styleVersion == update.style.version ? $0 : nil
        }
        let previous = state?.rows ?? []
        // Committed blocks strictly before the last block of the previous
        // update cannot change unless the parser reset them (a replaced
        // message, or a reference definition resolving an earlier link).
        let canSkipCommitted = state.map { $0.parserResetCount == parser.committedResetCount } ?? false
        let skipPrefix =
            canSkipCommitted
            ? min(state?.stableCount ?? 0, max(0, committedCount - 1), previous.count, max(0, blocks.count - 1))
            : 0
        var current: [(kind: TranscriptRowKind, layout: RowLayout)] = []
        current.reserveCapacity(blocks.count)
        if skipPrefix > 0 { current.append(contentsOf: previous[..<skipPrefix]) }
        var changed: [Row] = []
        for index in skipPrefix..<blocks.count {
            let block = blocks[index]
            let kind = TranscriptRowKind.markdownBlock(block, .of(index, in: blocks))
            let before = index < previous.count ? previous[index] : nil
            if let before, before.kind == kind {
                current.append(before)
                continue
            }
            let rowID = "\(update.messageID)#\(index)"
            var request = RowLayoutRequest(
                rowID: rowID, kind: kind,
                key: RowLayoutKey(contentVersion: -1, width: update.width, styleVersion: update.style.version),
                style: update.style)
            if let before { request.previous = before }
            if case .markdownBlock(.code(_, let code), _) = kind, let isDark = update.isDark,
                let colors = update.codeColors[rowID], colors.matches(code: code, isDark: isDark)
            {
                request.codeColors = colors
            }
            let layout = RowLayoutBuilder.layout(request)
            let drawn = update.drawing.map {
                DrawnBands.draw(
                    layout, after: before?.layout, palette: $0.palette, scale: $0.scale, colorSpace: $0.colorSpace)
            }
            current.append((kind, layout))
            changed.append(Row(index: index, kind: kind, layout: layout, drawn: drawn))
        }
        if update.isFinished {
            shown[update.messageID] = nil
        } else {
            let nextStable = max(0, min(committedCount, blocks.count - 1))
            shown[update.messageID] = ShownState(
                width: update.width, styleVersion: update.style.version, stableCount: nextStable,
                parserResetCount: parser.committedResetCount, rows: current)
        }
        return Result(
            messageID: update.messageID, textLength: update.text.utf8.count, isFinished: update.isFinished,
            blocks: blocks, width: update.width, styleVersion: update.style.version, rows: changed)
    }
}
