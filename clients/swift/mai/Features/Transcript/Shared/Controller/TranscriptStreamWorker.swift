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
        /// Precomputed text metrics per block (counted off-main).
        let metrics: [TextMetrics]
        /// The width and style version the rows were laid out at.
        let width: CGFloat
        let styleVersion: Int
        /// The rows that changed.
        let rows: [Row]
    }

    private struct ShownState {
        let width: CGFloat
        let styleVersion: Int
        let rows: [(kind: TranscriptRowKind, layout: RowLayout)]
    }

    private var parsers: [String: StreamingMarkdownParser] = [:]
    private var shown: [String: ShownState] = [:]

    func run(_ update: Update) -> Result {
        var parser = parsers[update.messageID] ?? StreamingMarkdownParser()
        let blocks: [MarkdownBlock]
        if update.isFinished {
            blocks = parser.finish(update.text)
            parsers[update.messageID] = nil
        } else {
            let snapshot = parser.update(update.text)
            blocks = snapshot.blocks
            parsers[update.messageID] = parser
        }
        let kinds = TranscriptBlockFlattener.kinds(for: blocks, kind: .assistant)
        let state = shown[update.messageID].flatMap {
            $0.width == update.width && $0.styleVersion == update.style.version ? $0 : nil
        }
        let previous = state?.rows ?? []
        var current: [(kind: TranscriptRowKind, layout: RowLayout)] = []
        current.reserveCapacity(kinds.count)
        var changed: [Row] = []
        for index in 0..<kinds.count {
            let kind = kinds[index]
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
            if case .markdownBlock(.code(_, let code), _, let ctx) = kind, !ctx.isNestedInContainer,
                let isDark = update.isDark,
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
            shown[update.messageID] = ShownState(
                width: update.width, styleVersion: update.style.version, rows: current)
        }
        let metrics = kinds.map(TextMetrics.init)
        return Result(
            messageID: update.messageID, textLength: update.text.utf8.count, isFinished: update.isFinished,
            blocks: blocks, metrics: metrics, width: update.width, styleVersion: update.style.version, rows: changed)
    }
}
