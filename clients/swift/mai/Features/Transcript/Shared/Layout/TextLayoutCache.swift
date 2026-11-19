import CoreGraphics
import Foundation
import Synchronization

/// Finished row layouts by content, width and style, process-wide and
/// bounded by size: a row scrolled back to, or the same reply shown again,
/// skips its layout. Only saves background work: everything works with it
/// off (`-ChatTranscriptCaches off`, PLAN 3.1 rule 9), and it can drop
/// anything at any time.
nonisolated final class TextLayoutCache: Sendable {
    static let shared = TextLayoutCache(budget: 48 * 1_024 * 1_024)

    private struct Key: Hashable {
        let kind: TranscriptRowKind
        let width: CGFloat
        let styleVersion: Int
        let highlightTheme: Bool?
    }

    private struct Entry {
        let height: CGFloat
        let content: RowContentLayout
        let bytes: Int
        var lastUse: UInt64
    }

    private struct State {
        var entries: [Key: Entry] = [:]
        var bytes = 0
        var clock: UInt64 = 0
    }

    private let budget: Int
    private let state = Mutex(State())

    init(budget: Int) {
        self.budget = budget
    }

    func layout(for request: RowLayoutRequest) -> RowLayout? {
        let key = Self.key(request)
        return state.withLock { state in
            guard var entry = state.entries[key] else { return nil }
            state.clock += 1
            entry.lastUse = state.clock
            state.entries[key] = entry
            return RowLayout(rowID: request.rowID, key: request.key, height: entry.height, content: entry.content)
        }
    }

    func insert(_ layout: RowLayout, for request: RowLayoutRequest) {
        let key = Self.key(request)
        let bytes = Self.bytes(of: layout.content)
        guard bytes < budget / 8 else { return }
        state.withLock { state in
            state.clock += 1
            if let old = state.entries[key] { state.bytes -= old.bytes }
            state.entries[key] = Entry(height: layout.height, content: layout.content, bytes: bytes, lastUse: state.clock)
            state.bytes += bytes
            guard state.bytes > budget else { return }
            // Evict the least recently used quarter at once, so eviction's
            // sort is rare.
            let victims = state.entries.sorted { $0.value.lastUse < $1.value.lastUse }.prefix(state.entries.count / 4 + 1)
            for (key, entry) in victims {
                state.entries[key] = nil
                state.bytes -= entry.bytes
            }
        }
    }

    private static func key(_ request: RowLayoutRequest) -> Key {
        Key(
            kind: request.kind, width: request.key.width, styleVersion: request.key.styleVersion,
            highlightTheme: request.codeColors?.isDark)
    }

    private static func bytes(of content: RowContentLayout) -> Int {
        func text(_ layout: TextLayout) -> Int {
            let glyphs = layout.runs.reduce(0) { $0 + $1.glyphs.count }
            let carets = layout.lines.reduce(0) { $0 + $1.caretOffsets.count }
            return glyphs * 18 + carets * 8 + layout.lines.count * 96 + layout.runs.count * 96
                + layout.string.utf8.count + 256
        }
        switch content {
        case .text(let layout, _), .bubble(let layout, _, _), .header(let layout, _, _), .notice(let layout, _, _):
            return text(layout)
        case .code(let layout, _), .codeBody(let layout):
            return text(layout.body) + text(layout.label)
        case .table(let layout, _), .tableBody(let layout):
            return layout.cells.reduce(512) { $0 + text($1.layout) }
        case .actions, .empty:
            return 64
        }
    }
}
