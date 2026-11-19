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
            // `-ChatMarkdownReplayExtreme YES`: replies far past normal, to
            // find where the per-update cost stops being acceptable.
            let isExtreme = UserDefaults.standard.bool(forKey: "ChatMarkdownReplayExtreme")
            let fixtures: [(name: String, text: String)] =
                isExtreme
                ? [
                    ("fence-3000-lines", longFence(lines: 3000)),
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

        private static func longFence(lines: Int) -> String {
            var text = "Here is the whole module:\n\n```go\n"
            for line in 0..<lines {
                text += "\tvalue\(line) := compute(input[\(line)], \"step \(line)\") // keep \(line % 7)\n"
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
    }
#endif
