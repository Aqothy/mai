#if DEBUG
    import CoreGraphics
    import Foundation

    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif

    /// `-ChatAutoBenchmark markdown` (PLAN 6.12): replays long replies through
    /// the stream worker as streaming feeds it, a growing prefix per update,
    /// and times each update (parse, layout and, with `draws`, the changed
    /// bands), plus the one-shot parse. One `CHAT_BENCHMARK_RESULT` line per
    /// fixture, chunk size and mode.
    enum ChatMarkdownReplayBenchmark {
        @MainActor static func run() async {
            if UserDefaults.standard.bool(forKey: "ChatMarkdownReplayEngine") {
                await runExtremeEngineBenchmarks()
                return
            }
            // `-ChatMarkdownReplayExtreme YES`: replies far past normal, to
            // find where the per-update cost stops being acceptable.
            let isExtreme = UserDefaults.standard.bool(forKey: "ChatMarkdownReplayExtreme")
            let fixtures: [(name: String, text: String)] =
                isExtreme
                ? [
                    ("fence-3000-lines", longFence(lines: 3000)),
                    ("wide-fence-3000-lines", longFence(lines: 3000, wide: true)),
                    ("paragraph-60kb", longParagraph(words: 10_000)),
                    ("table-400-rows", longTable(rows: 400)),
                    ("reply-200kb", String(repeating: ChatMarkdownFixtures.longMarkdown + "\n\n", count: 12)),
                ]
                : [
                    ("code-heavy", ChatMarkdownFixtures.codeHeavy),
                    ("long-markdown", ChatMarkdownFixtures.longMarkdown),
                    ("essay", ChatMarkdownFixtures.essay(wordCount: 3000)),
                    ("long-fence", longFence(lines: 800)),
                    ("long-paragraph", longParagraph(words: 2500)),
                ]
            let style = TextStyle.current()
            #if os(macOS)
                let palette = TextPalette.resolve(for: NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing())
            #else
                let palette = TextPalette.resolve(for: UITraitCollection(userInterfaceStyle: .dark))
            #endif
            let drawing = TranscriptStreamWorker.Drawing(palette: palette, scale: 2, colorSpace: RowLayer.colorSpace)
            for fixture in fixtures {
                let bytes = fixture.text.utf8.count
                let started = ContinuousClock.now
                _ = MarkdownPlanner.blocks(from: fixture.text)
                let parse = milliseconds(started.duration(to: .now))
                print(result(["fixture": fixture.name, "mode": "one-shot parse", "bytes": bytes, "totalMilliseconds": parse,
                    "mebibytesPerSecond": Double(bytes) / 1_048_576 / max(parse / 1000, 1e-9)]))
                for chunk in isExtreme ? [256] : [24, 256] {
                    for draws in isExtreme ? [true] : [false, true] {
                        let times = await replay(
                            fixture.text, chunk: chunk, style: style, drawing: draws ? drawing : nil)
                        let sorted = times.sorted()
                        let tail = Array(times.suffix(max(1, times.count / 10))).sorted()
                        print(result([
                            "fixture": fixture.name, "mode": draws ? "parse+layout+draw" : "parse+layout",
                            "chunkBytes": chunk, "bytes": bytes, "updates": times.count,
                            "totalMilliseconds": times.reduce(0, +),
                            "medianMilliseconds": sorted[sorted.count / 2],
                            "p95Milliseconds": sorted[min(sorted.count - 1, sorted.count * 95 / 100)],
                            "maxMilliseconds": sorted.last ?? 0,
                            "lastTenthMedianMilliseconds": tail[tail.count / 2],
                        ]))
                    }
                }
            }
        }

        /// Per-update durations of streaming `text` in `chunk`-byte appends
        /// (whole characters), ending with the final parse.
        private static func replay(
            _ text: String, chunk: Int, style: TextStyle, drawing: TranscriptStreamWorker.Drawing?
        ) async -> [Double] {
            let worker = TranscriptStreamWorker()
            let utf8 = text.utf8
            var times: [Double] = []
            var end = utf8.startIndex
            while true {
                let isFinished = end == utf8.endIndex
                if !isFinished {
                    end = utf8.index(end, offsetBy: chunk, limitedBy: utf8.endIndex) ?? utf8.endIndex
                    while end < utf8.endIndex, end.samePosition(in: text) == nil { utf8.formIndex(after: &end) }
                }
                let update = TranscriptStreamWorker.Update(
                    messageID: "replay", text: String(text[..<end]), isFinished: isFinished, width: 700, style: style,
                    codeColors: [:], isDark: true, drawing: drawing)
                let started = ContinuousClock.now
                _ = await worker.run(update)
                times.append(milliseconds(started.duration(to: .now)))
                if isFinished { return times }
            }
        }

        private static func longFence(lines: Int, wide: Bool = false) -> String {
            var text = "Here is the whole module:\n\n```go\n"
            let extra = wide ? " // " + String(repeating: "wide-payload-", count: 10) : ""
            for line in 0..<lines {
                text += "\tvalue\(line) := compute(input[\(line)], \"step \(line)\") // keep \(line % 7)\(extra)\n"
            }
            return text + "```\n\nThat is all."
        }

        private static func longTable(rows: Int) -> String {
            var text = "| Option | Default | Effect |\n| --- | --- | --- |\n"
            for row in 0..<rows { text += "| `option\(row)` | \(row % 5) | changes **step \(row)** of the stream |\n" }
            return text + "\nThat is the table."
        }

        private static func longParagraph(words: Int) -> String {
            let vocabulary = ["stream", "layout", "the", "band", "**bold**", "`code`", "text", "frame", "of", "and"]
            return (0..<words).map { vocabulary[$0 % vocabulary.count] }.joined(separator: " ")
        }

        private static func milliseconds(_ duration: Duration) -> Double {
            let parts = duration.components
            return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
        }

        private static func result(_ fields: [String: Any]) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
            return "CHAT_BENCHMARK_RESULT " + String(decoding: data, as: UTF8.self)
        }

        /// `-ChatAutoBenchmark markdown -ChatMarkdownReplayEngine YES`:
        /// optimized `-O` measurements of every Part 1 extreme workload.
        @MainActor private static func runExtremeEngineBenchmarks() async {
            let style = TextStyle.current()
            #if os(macOS)
                let palette = TextPalette.resolve(for: NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing())
            #else
                let palette = TextPalette.resolve(for: UITraitCollection(userInterfaceStyle: .dark))
            #endif

            func emit(_ name: String, ms: Double, extra: [String: Any] = [:]) {
                var fields: [String: Any] = [
                    "fixture": name, "mode": "one-shot parse", "totalMilliseconds": ms,
                    "mebibytesPerSecond": 0.0,
                ]
                for (k, v) in extra { fields[k] = v }
                print(result(fields))
            }

            // 1. 256 KB & 1 MB single unbroken paragraph (normal spaces + zero spaces).
            for (label, bytes, spaced) in [
                ("para-256kb-spaced", 256 * 1024, true),
                ("para-256kb-unspaced", 256 * 1024, false),
                ("para-1mb-spaced", 1024 * 1024, true),
            ] {
                let unit = spaced ? "performance " : "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
                let text = String(repeating: unit, count: bytes / unit.utf8.count)
                let start = ContinuousClock.now
                let layout = RowLayoutBuilder.prose([.paragraph([MarkdownInline(text: text)])], width: 728, style: style)
                let ms = milliseconds(start.duration(to: .now))
                emit(label, ms: ms, extra: ["lines": layout.lines.count, "bytes": text.utf8.count])
            }

            // 2. 100 KB single code line: layout + single 768x512 tile raster @ 2x.
            do {
                let unit = #"{"id":12345,"name":"transcript-engine","ok":true},"#
                let longLine = "[" + String(repeating: unit, count: 100_000 / unit.utf8.count) + "]"
                let key = RowLayoutKey(contentVersion: 0, width: 700, styleVersion: style.version)
                let layoutStart = ContinuousClock.now
                let layout = RowLayoutBuilder.layout(
                    RowLayoutRequest(
                        rowID: "wide", kind: .markdownBlock(.code(language: "json", code: longLine), .single),
                        key: key, style: style))
                let layoutMs = milliseconds(layoutStart.duration(to: .now))
                let tileStart = ContinuousClock.now
                var tileBytes = 0
                if let wide = layout.content.wideBody {
                    let tile = CGRect(x: 50_000, y: 0, width: RowLayer.bandWidth, height: wide.frame.height)
                    let bmp = BandRasterizer.bitmap(
                        BandRaster(
                            content: wide.content, palette: palette, drawsWideBody: true, rect: tile, scale: 2,
                            colorSpace: RowLayer.colorSpace))
                    tileBytes = bmp?.surface.allocationSize ?? 0
                }
                let tileMs = milliseconds(tileStart.duration(to: .now))
                emit("code-100kb-line-layout", ms: layoutMs)
                emit("code-100kb-line-tile-raster", ms: tileMs, extra: ["surfaceBytes": tileBytes])
            }

            // 3. 20,000-line code block chunking + single visible chunk layout.
            do {
                let code = (0..<20_000).map { "let line\($0) = \($0) * 2" }.joined(separator: "\n")
                let start = ContinuousClock.now
                let rows = TranscriptRowChunker.assistantRows(
                    messageID: "c", turnID: "t", blocks: [.code(language: "swift", code: code)])
                let key = RowLayoutKey(contentVersion: 0, width: 700, styleVersion: style.version)
                _ = RowLayoutBuilder.layout(RowLayoutRequest(rowID: rows[0].id, kind: rows[0].kind, key: key, style: style))
                let ms = milliseconds(start.duration(to: .now))
                emit("code-20k-chunk-and-first-row", ms: ms, extra: ["chunks": rows.count])
            }

            // 4. 500 KB user message chunking + accessibility query.
            do {
                let line = "[2026-11-23 22:00:00] INFO worker=3 processed batch_id=987654321 duration_ms=12\n"
                let big = String(repeating: line, count: 500_000 / line.utf8.count)
                let start = ContinuousClock.now
                let rows = TranscriptRowChunker.userRows(messageID: "u", turnID: "t", source: big)
                let controller = TranscriptController(configuration: .testing)
                controller.setRows(rows)
                let accessible = controller.accessibleRows(minY: 0, maxY: 900, columnX: 0)
                let ms = milliseconds(start.duration(to: .now))
                emit("user-500kb-chunk-and-a11y", ms: ms, extra: ["chunks": rows.count, "a11yRows": accessible.count])
            }

            // 5. 5 MB 40-turn chat + 200 live tool events.
            do {
                let base = Date(timeIntervalSince1970: 1_800_000_000)
                let summary = ThreadFixtures.summary(
                    id: "bench-5mb", title: "5 MB", cwd: "/tmp", agent: ("a", "A"), status: .running,
                    createdAt: base, updatedAt: base)
                let payload = String(repeating: "Detailed analysis of the subsystem state and logs.\n", count: 2_500)
                var turns = (0..<40).map { t in
                    ThreadFixtures.turn(
                        id: "turn-\(t)", participant: summary.participants[0].id, state: .completed,
                        startedAt: base.addingTimeInterval(Double(t) * 60),
                        settledAt: base.addingTimeInterval(Double(t) * 60 + 10),
                        entries: [
                            ThreadFixtures.entry(ref: "u", kind: .userMessage, text: "Prompt \(t)"),
                            ThreadFixtures.entry(ref: "a", kind: .assistantMessage, text: payload + "turn-\(t)"),
                        ])
                }
                let liveTurn = ThreadFixtures.turn(
                    id: "turn-live", participant: summary.participants[0].id, state: .running,
                    startedAt: base.addingTimeInterval(3_000), settledAt: nil,
                    entries: [ThreadFixtures.entry(ref: "u", kind: .userMessage, text: "Run")])
                turns.append(liveTurn)
                var detail = ThreadFixtures.detail(summary: summary, turns: turns)
                let store = ThreadStore(previewThreads: [summary], selectedThread: detail)
                let controller = TranscriptController(configuration: .testing)
                controller.start(store: store, threadID: detail.id)
                let start = ContinuousClock.now
                for step in 0..<200 {
                    let event = ThreadEvent(
                        delivery: nil,
                        entry: ThreadFixtures.entry(ref: "tool-\(step)", kind: .toolCall, title: "Read \(step)"),
                        kind: MaidThreadEventKind.entry.rawValue,
                        participant: nil, plan: nil, request: nil, resolved: nil,
                        seq: detail.seq + 1, summary: nil, text: nil, thread: detail.id, turn: liveTurn)
                    _ = detail.apply(event)
                    let tailIndex = detail.turns.count - 1
                    controller.turns[tailIndex] = TranscriptTurn(detail.turns[tailIndex])
                    controller.turnRevisions = detail.turnRevisions
                    controller.rebuildRows(fromTurnIndex: tailIndex)
                }
                let ms = milliseconds(start.duration(to: .now))
                emit("chat-5mb-200-live-events", ms: ms, extra: ["msPerEvent": ms / 200.0])
            }

            // 6. 50 replaceRows splices on 10,000 rows (ReadingPlace COW check).
            do {
                var geometry = TranscriptGeometry()
                let ids = (0..<10_000).map { "r-\($0)" }
                geometry.replace(ids: ids, sources: ids) { _ in 40 }
                let start = ContinuousClock.now
                for i in 0..<50 {
                    let range = 9_900..<9_901
                    let place = geometry.readingPlace(atViewportTop: 20_000, replacingRange: range)
                    geometry.replaceRows(range, ids: ["s-\(i)"], sources: ["s-\(i)"], heights: [42])
                    _ = place.flatMap(geometry.offset(for:))
                }
                let ms = milliseconds(start.duration(to: .now))
                emit("geometry-10k-50-splices", ms: ms)
            }
        }
    }
#endif
