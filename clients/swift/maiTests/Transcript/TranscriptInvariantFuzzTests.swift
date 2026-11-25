import CoreGraphics
import Foundation
import QuartzCore
import Testing

@testable import mai

/// Model-based fuzzers and pathological inputs: random operation sequences
/// checked against invariants after every step (Ghostty's stream fuzzer and
/// PageList integrity checks, CSS scroll anchoring's guarantee), and the
/// inputs that make Markdown parsers quadratic or overflow the stack (cmark
/// `test/pathological_tests.py`).
nonisolated struct TranscriptInvariantFuzzTests {

    // MARK: Chunking

    /// Chunked user messages and thoughts copy back exactly, every chunk
    /// within its limits, and no chunk boundary splits a grapheme cluster.
    @Test(arguments: 0..<2)
    func chunkedTextReassemblesExactlyAtGraphemeBoundaries(seed: Int) {
        var rng = FuzzRNG(seed: 0xC4A2_0000 &+ UInt64(seed))
        for iteration in 0..<(6 * TranscriptFuzz.scale) {
            let text: String
            switch rng.int(in: 0..<5) {
            case 0: text = TranscriptFuzz.adversarialText(&rng, utf16Length: rng.int(in: 0..<60_000), newlines: true)
            case 1: text = TranscriptFuzz.adversarialText(&rng, utf16Length: rng.int(in: 16_000..<60_000))
            case 2: text = (0..<rng.int(in: 1..<900)).map { _ in String(repeating: "x", count: rng.int(in: 0..<90)) }
                .joined(separator: rng.pick(["\n", "\r\n"]))
            case 3: text = String(repeating: rng.pick(["👩‍👩‍👧‍👦", "e\u{0301}", "🇦🇧", "漢"]), count: rng.int(in: 1..<9_000))
            default: text = String(repeating: rng.pick([" ", "\n", "\t", "a "]), count: rng.int(in: 1..<40_000))
            }
            let pieces = TranscriptRowChunker.markdownPieces(
                text, maxBytes: TranscriptRowChunker.maxUserMessageBytes, maxLines: TranscriptRowChunker.maxUserMessageLines)
            checkChunks(
                text, pieces: pieces.map { String($0.text) }, separators: pieces.map(\.separator),
                context: "user seed \(seed) iteration \(iteration)")
            let rows = TranscriptRowChunker.userRows(messageID: "m", turnID: "t", source: text)
            if rows.count > 1 {
                #expect(rows.count == pieces.count)
                for (index, (row, piece)) in zip(rows, pieces).enumerated() {
                    guard case .userMessage(let source, let position) = row.kind else { continue }
                    #expect(source == piece.prefix + piece.text && row.separatorBefore == piece.separator)
                    #expect(position.isFirst == (index == 0) && position.isLast == (index == rows.count - 1))
                    #expect(position.joinsAbove == (index > 0) && position.joinsBelow == (index < rows.count - 1))
                }
            }
            let thoughts = TranscriptRowChunker.thoughtRows(turnID: "t", ref: "r", text: text)
            let thoughtPieces = thoughts.map { row -> String in
                guard case .thought(let piece) = row.kind else { return "" }
                return piece
            }
            checkChunks(
                text, pieces: thoughtPieces, separators: thoughts.map(\.separatorBefore),
                context: "thought seed \(seed) iteration \(iteration)")
        }
    }

    /// Chunked paragraphs keep every character's style and link, chunked
    /// code its exact text, and chunked lists their items and numbering.
    @Test(arguments: 0..<2)
    func chunkedBlocksKeepTheirContent(seed: Int) {
        var rng = FuzzRNG(seed: 0xB10C_0000 &+ UInt64(seed))
        for iteration in 0..<(5 * TranscriptFuzz.scale) {
            var inlines: [MarkdownInline] = []
            var total = 0
            let target = rng.int(in: 1..<80_000)
            while total < target {
                let text = TranscriptFuzz.adversarialText(&rng, utf16Length: rng.int(in: 1..<3_000), newlines: rng.chance(20))
                let link = rng.chance(10) ? URL(string: "https://example.com/\(inlines.count)") : nil
                inlines.append(MarkdownInline(text: text, style: rng.pick([[], .strong, .code, .emphasis]), link: link))
                total += text.utf8.count
            }
            let code = (0..<rng.int(in: 1..<2_000)).map { _ in
                TranscriptFuzz.adversarialText(&rng, utf16Length: rng.int(in: 0..<(rng.chance(5) ? 40_000 : 120)))
            }.joined(separator: "\n")
            let items = (0..<rng.int(in: 1..<450)).map { MarkdownList.Item(blocks: [.paragraph([MarkdownInline(text: "item \($0)")])]) }
            let list = MarkdownList(startIndex: rng.chance(50) ? rng.int(in: 0..<9) : nil, items: items)
            let blocks: [MarkdownBlock] = [.paragraph(inlines), .code(language: "swift", code: code), .list(list)]
            let rows = TranscriptRowChunker.assistantRows(messageID: "m", turnID: "t", blocks: blocks)
            let context = "seed \(seed) iteration \(iteration)"
            #expect(Set(rows.map(\.id)).count == rows.count, "\(context) duplicate row IDs")

            var paragraph: [(Character, MarkdownInline.Style, URL?)] = []
            var codeParts: [String] = []
            var listItems: [MarkdownList.Item] = []
            for row in rows {
                guard case .markdownBlock(let block, _) = row.kind else { continue }
                switch block {
                case .paragraph(let chunk):
                    for inline in chunk { paragraph += inline.text.map { ($0, inline.style, inline.link) } }
                    #expect(chunk.reduce(0) { $0 + $1.text.utf8.count } <= TranscriptRowChunker.maxParagraphBytes + 64)
                case .code(_, let piece):
                    codeParts.append(piece)
                case .list(let chunk):
                    if let start = list.startIndex { #expect(chunk.startIndex == start + listItems.count, "\(context) numbering") }
                    listItems += chunk.items
                default:
                    break
                }
            }
            let expected = inlines.flatMap { inline in inline.text.map { ($0, inline.style, inline.link) } }
            #expect(paragraph.map(\.0) == expected.map(\.0), "\(context) paragraph text")
            #expect(paragraph.map(\.1) == expected.map(\.1), "\(context) paragraph styles")
            #expect(paragraph.map(\.2) == expected.map(\.2), "\(context) paragraph links")
            #expect(codeParts.joined(separator: "\n") == code, "\(context) code")
            #expect(listItems == items, "\(context) list items")
        }
    }

    /// `pieces` joined by `separators` (the first unused) are `text`, and
    /// every cut, with the separator it consumed, sits on grapheme cluster
    /// boundaries of the whole text; no piece is over its limits but one
    /// character or line that alone is.
    private func checkChunks(_ text: String, pieces: [String], separators: [String], context: String) {
        var joined = ""
        var cuts: [(at: Int, separator: String)] = []
        for (index, piece) in pieces.enumerated() {
            if index > 0 {
                cuts.append((joined.utf8.count, separators[index]))
                joined += separators[index]
            }
            joined += piece
        }
        #expect(joined == text, "\(context): reassembly differs")
        guard joined == text else { return }
        // A consumed newline may be a CRLF's LF: the CR stays at the end of
        // the chunk before, which lays it out as the line's terminator.
        let boundaries = Set(text.indices.map { text.utf8.distance(from: text.startIndex, to: $0) } + [text.utf8.count])
        let bytes = Array(text.utf8)
        for (index, cut) in cuts.enumerated() {
            let next = cut.at + cut.separator.utf8.count
            let valid =
                boundaries.contains(next)
                && (boundaries.contains(cut.at) || (cut.separator == "\n" && bytes[cut.at - 1] == 0x0D))
            guard valid else {
                let around = String(decoding: bytes[max(0, cut.at - 12)..<min(bytes.count, cut.at + 12)], as: UTF8.self)
                Issue.record("\(context): cut \(index) at byte \(cut.at) splits a cluster: \(around.unicodeScalars.map { String($0.value, radix: 16) })")
                return
            }
        }
        for piece in pieces where piece.count > 1 {
            #expect(piece.utf8.count <= TranscriptRowChunker.maxUserMessageBytes, "\(context): chunk over its byte limit")
            #expect(piece.utf8.reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) } <= TranscriptRowChunker.maxUserMessageLines + 1)
        }
    }

    // MARK: Tiling

    /// Drawn bands always cover what was asked, sit on the tile grid inside
    /// the painted area, and releasing leaves no bitmap outside what is kept.
    @MainActor @Test func bandsCoverRequestedRectsAndReleaseEverythingElse() {
        let style = TextStyle.current()
        var rng = FuzzRNG(seed: 0x711E)
        let palette = TextPalette.resolveForTests
        for iteration in 0..<(2 * TranscriptFuzz.scale) {
            // Each iteration's bitmaps go when the app lets them go, at the end
            // of a run loop turn: its autorelease pool drained and transaction
            // committed. A test that never returns to the run loop keeps them
            // all (23 GB by iteration 289 at scale 50, until IOSurfaces fail).
            autoreleasepool {
                let wide = rng.chance(50)
                let lines = (0..<rng.int(in: 1..<150)).map { index in
                    "line \(index)" + (wide ? String(repeating: " wide", count: rng.int(in: 0..<250)) : "")
                }
                let key = RowLayoutKey(contentVersion: 0, width: CGFloat(rng.int(in: 200..<760)), styleVersion: style.version)
                let layout = RowLayoutBuilder.layout(
                    RowLayoutRequest(
                        rowID: "r", kind: .markdownBlock(.code(language: nil, code: lines.joined(separator: "\n")), .single),
                        key: key, style: style))
                let row = RowLayer()
                let content: RowContentLayout
                let size: CGSize
                if let body = layout.content.wideBody {
                    content = body.content
                    size = CGSize(width: body.contentWidth, height: body.frame.height)
                } else {
                    content = layout.content
                    size = CGSize(width: key.width, height: layout.height)
                }
                row.frame = CGRect(origin: .zero, size: size)
                row.show(
                    rowID: "r", layout: RowLayout(rowID: "r", key: key, height: size.height, content: content),
                    palette: palette, drawsWideBody: true, scale: 1)
                let bounds = CGRect(origin: .zero, size: size)
                for step in 0..<12 {
                    let rect = CGRect(
                        x: CGFloat(rng.int(in: -500..<Int(size.width) + 500)), y: CGFloat(rng.int(in: -500..<Int(size.height) + 500)),
                        width: CGFloat(rng.int(in: 1..<2_000)), height: CGFloat(rng.int(in: 1..<2_000)))
                    row.drawBands(in: rect, visible: rect, offMain: false)
                    let bands = row.sublayers?.compactMap { $0 as? RowBandLayer } ?? []
                    let context = "iteration \(iteration) step \(step) wide \(wide)"
                    for band in bands {
                        #expect(bounds.contains(band.frame), "\(context): band \(band.frame) outside \(size)")
                        #expect(band.frame.minX.truncatingRemainder(dividingBy: RowLayer.bandWidth) == 0, "\(context)")
                        #expect(band.frame.minY.truncatingRemainder(dividingBy: RowLayer.bandHeight) == 0, "\(context)")
                    }
                    // Every point of the request inside the row has a current band.
                    let covered = rect.intersection(bounds)
                    if !covered.isNull, !covered.isEmpty {
                        for probe in [CGPoint(x: covered.minX, y: covered.minY), CGPoint(x: covered.midX, y: covered.midY),
                            CGPoint(x: covered.maxX - 0.5, y: covered.maxY - 0.5)]
                        {
                            let hit = bands.first { $0.frame.contains(probe) }
                            #expect(hit?.isCurrent == true && hit?.contents != nil, "\(context): \(probe) not drawn")
                        }
                    }
                    let keep = rect.insetBy(dx: -CGFloat(rng.int(in: 0..<800)), dy: -CGFloat(rng.int(in: 0..<800)))
                    row.releaseBands(outside: keep)
                    for band in row.sublayers?.compactMap({ $0 as? RowBandLayer }) ?? [] where band.contents != nil {
                        #expect(band.frame.intersects(keep), "\(context): bitmap kept outside \(keep)")
                    }
                }
            }
            CATransaction.flush()
        }
    }

    // MARK: Store updates

    /// Store updates rebuild only the turns that changed (`turnRevisions`,
    /// `rebuildRows(fromTurnIndex:)`); after any sequence of the daemon's
    /// events and expansions, the rows are exactly what a full rebuild makes
    /// and the controller's turns are the store's.
    @MainActor @Test(arguments: 0..<2)
    func incrementalStoreUpdatesEqualAFullRebuild(seed: Int) async {
        var rng = FuzzRNG(seed: 0x57_0BE0 &+ UInt64(seed))
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let summary = ThreadFixtures.summary(
            id: "synthetic-benchmark-fuzz-\(seed)", title: "Fuzz", cwd: "/tmp", agent: ("a", "A"), status: .running,
            createdAt: base, updatedAt: base)
        let agent = summary.participants[0].id
        func turn(_ index: Int, state: MaidTurnState, error: String? = nil) -> TurnView {
            ThreadFixtures.turn(
                id: "turn-\(index)", participant: agent, state: state, startedAt: base.addingTimeInterval(Double(index) * 60),
                settledAt: state == .running ? nil : base.addingTimeInterval(Double(index) * 60 + 30), error: error,
                entries: [])
        }
        let kinds: [MaidItemKind] = [.assistantMessage, .reasoning, .toolCall, .commandExecution, .warning, .error, .userMessage]
        func entry(_ ref: String) -> EntryView {
            let kind = rng.pick(kinds)
            let text = kind == .toolCall || kind == .commandExecution ? nil : TranscriptFuzz.markdownDocument(&rng, blocks: rng.int(in: 1..<3))
            return ThreadFixtures.entry(ref: ref, kind: kind, text: text, title: "step \(ref)")
        }
        var turns = (0..<rng.int(in: 1..<5)).map { index -> TurnView in
            var view = turn(index, state: .completed)
            view.entries = [ThreadFixtures.entry(ref: "u", kind: .userMessage, text: "Prompt \(index)")]
                + (0..<rng.int(in: 0..<5)).map { entry("e\($0)") }
            return view
        }
        turns.append(turn(turns.count, state: .running))
        let detail = ThreadFixtures.detail(summary: summary, turns: turns)
        let store = ThreadStore(previewThreads: [summary], selectedThread: detail)
        let controller = TranscriptController(configuration: .testing)
        controller.start(store: store, threadID: summary.id)
        var seq = detail.seq
        var nextRef = 100
        var running = turns.count - 1
        var checked = 0
        defer { #expect(checked > 25, "seed \(seed): only \(checked) steps reached the controller") }

        for step in 0..<(50 * TranscriptFuzz.scale) {
            guard let thread = store.selectedThread else { return }
            seq += 1
            let operation = rng.int(in: 0..<10)
            switch operation {
            case 0, 1, 2:
                // A new entry in the running turn.
                nextRef += 1
                store.applySyntheticBenchmarkEvent(
                    ThreadFixtures.event(.entry, thread: summary.id, seq: seq, turn: thread.turns[running], entry: entry("e\(nextRef)")))
            case 3:
                // An entry replaced in any turn (a finished tool, an edited message).
                let index = rng.int(in: 0..<thread.turns.count)
                guard let old = thread.turns[index].entries.last else { continue }
                store.applySyntheticBenchmarkEvent(
                    ThreadFixtures.event(.entry, thread: summary.id, seq: seq, turn: thread.turns[index], entry: entry(old.ref)))
            case 4, 5:
                // Text streamed onto an entry of any turn.
                let index = rng.int(in: 0..<thread.turns.count)
                guard let target = thread.turns[index].entries.last(where: { $0.text != nil }) else { continue }
                let append = TextAppend(
                    entry: target.ref, stream: "s", text: rng.pick([" more", "\n\n- item", " **bold**", "\n```\ncode"]),
                    turn: thread.turns[index].id)
                store.applySyntheticBenchmarkEvent(ThreadFixtures.event(.text, thread: summary.id, seq: seq, text: append))
            case 6:
                // The running turn ends, or a new one starts.
                if thread.turns[running].turnState == .running {
                    let ending = rng.chance(30) ? turn(running, state: .interrupted, error: "Stopped") : turn(running, state: .completed)
                    store.applySyntheticBenchmarkEvent(ThreadFixtures.event(.turn, thread: summary.id, seq: seq, turn: ending))
                } else {
                    running = thread.turns.count
                    store.applySyntheticBenchmarkEvent(
                        ThreadFixtures.event(.turn, thread: summary.id, seq: seq, turn: turn(running, state: .running)))
                }
            case 7:
                let finished = controller.turns.filter { !$0.isRunning }.map(\.id)
                if !finished.isEmpty { controller.toggleExpansion(turnID: rng.pick(finished)) }
            default:
                // Something besides the turns.
                store.applySyntheticBenchmarkEvent(
                    ThreadFixtures.event(.thread, thread: summary.id, seq: seq, summary: summary))
            }
            // Observation re-arms on the next main-actor turn.
            for _ in 0..<8 { await Task.yield() }
            guard let updated = store.selectedThread, controller.turnRevisions == updated.turnRevisions else {
                // Streamed text the store keeps live without publishing.
                continue
            }
            checked += 1
            let context = "seed \(seed) step \(step) op \(operation)"
            #expect(controller.turns.map(\.id) == updated.turns.map(\.id), "\(context): turns")
            #expect(
                controller.turns.map { $0.entries.map(\.text) } == updated.turns.map { $0.entries.map { $0.text ?? "" } },
                "\(context): entries")
            let incremental = controller.rows
            controller.rebuildRows()
            if controller.rows != incremental {
                let first =
                    zip(incremental, controller.rows).enumerated().first { $0.element.0 != $0.element.1 }?.offset
                    ?? min(incremental.count, controller.rows.count)
                Issue.record(
                    "\(context): row \(first) of \(incremental.count) is \(incremental.indices.contains(first) ? incremental[first].id : "-"), a full rebuild makes \(controller.rows.indices.contains(first) ? controller.rows[first].id : "-") of \(controller.rows.count)")
                return
            }
        }
    }

    // MARK: Scroll anchoring

    /// CSS scroll anchoring's guarantee under random row changes, reader
    /// scrolls, resizes and jumps: a reader who is not following keeps the
    /// row at their viewport's top exactly where it was (clamped to the
    /// content), a following reader stays at the end, and the document,
    /// rows and geometry agree after every step.
    @MainActor @Test(arguments: 0..<2)
    func readingPlaceHoldsUnderRandomOperations(seed: Int) {
        var rng = FuzzRNG(seed: 0xA2C4_0000 &+ UInt64(seed))
        let controller = TranscriptController(configuration: .testing)
        let host = FakeTranscriptHost()
        host.size = CGSize(width: 700, height: CGFloat(rng.int(in: 120..<900)))
        host.controller = controller
        controller.attach(host)
        var nextID = 0
        func makeRows(_ count: Int) -> ([TranscriptRow], [String: CGFloat]) {
            var rows: [TranscriptRow] = []
            var heights: [String: CGFloat] = [:]
            let source = "s\(nextID)"
            for _ in 0..<count {
                nextID += 1
                let id = "r\(nextID)"
                rows.append(TranscriptRow(id: id, sourceID: rng.chance(50) ? source : id, kind: .activity(summary: id)))
                heights[id] = CGFloat(rng.int(in: 1..<700))
            }
            return (rows, heights)
        }
        let (initial, initialHeights) = makeRows(rng.int(in: 1..<80))
        controller.setRows(initial, measuredHeights: initialHeights)
        controller.alignInitialEndIfPossible()

        for step in 0..<(150 * TranscriptFuzz.scale) {
            let following = controller.isFollowing
            let top = host.viewportTop
            let place = controller.geometry.readingPlace(atViewportTop: top)
            var isReaderMove = false
            let operation = rng.int(in: 0..<8)
            switch operation {
            case 0:
                var heights: [String: CGFloat] = [:]
                for _ in 0..<rng.int(in: 1..<8) where !controller.rows.isEmpty {
                    heights[controller.rows[rng.int(in: 0..<controller.rows.count)].id] = CGFloat(rng.int(in: 1..<900))
                }
                controller.setHeights(heights)
            case 1:
                let count = controller.rows.count
                let start = rng.int(in: 0..<(count + 1))
                let end = min(count, start + rng.int(in: 0..<6))
                let (rows, heights) = makeRows(rng.int(in: 0..<6))
                guard end > start || !rows.isEmpty, count - (end - start) + rows.count > 0 else { continue }
                controller.replaceRows(start..<end, with: rows, heights: heights)
            case 2:
                let (rows, heights) = makeRows(rng.int(in: 1..<20))
                controller.replaceRows(0..<0, with: rows, heights: heights)
            case 3:
                let (rows, heights) = makeRows(rng.int(in: 1..<4))
                controller.replaceRows(controller.rows.count..<controller.rows.count, with: rows, heights: heights)
            case 4:
                isReaderMove = true
                host.readerScroll(toTop: CGFloat(rng.int(in: -50..<(Int(controller.geometry.totalHeight) + 50))))
            case 5:
                isReaderMove = true
                host.resize(to: CGSize(width: CGFloat(rng.int(in: 300..<1_400)), height: CGFloat(rng.int(in: 100..<1_000))))
            case 6:
                isReaderMove = true
                controller.jumpToEnd(animated: false)
            default:
                guard let last = controller.rows.indices.last else { continue }
                controller.updateRows([(last, controller.rows[last])], heights: [controller.rows[last].id: CGFloat(rng.int(in: 1..<2_000))])
            }
            let context = "seed \(seed) step \(step) op \(operation)"
            let geometry = controller.geometry
            #expect(controller.rows.count == geometry.count, "\(context) count")
            #expect(controller.rows.indices.allSatisfy { geometry.index(for: controller.rows[$0].id) == $0 }, "\(context) index")
            #expect(host.documentHeight == geometry.totalHeight, "\(context) document height")
            guard let viewport = host.viewport else { continue }
            let endTop = controller.endTop(viewport)
            let newTop = host.viewportTop
            if !isReaderMove {
                if following {
                    #expect(newTop == endTop, "\(context): a following reader left the end (\(newTop) vs \(endTop))")
                } else if let place, let index = geometry.index(for: place.anchorID) {
                    let expected = min(max(0, geometry.offset(at: index) + min(place.offsetIntoRow, geometry.height(at: index))), endTop)
                    #expect(abs(newTop - expected) < 0.001, "\(context): anchor \(place.anchorID) moved \(newTop) vs \(expected)")
                }
            }
            let nearEnd = geometry.totalHeight - (newTop + viewport.visibleHeight) <= ScrollFollowPolicy.nearEndDistance
            #expect(controller.isEndVisible == nearEnd, "\(context) end visibility")
        }
    }

    // MARK: Layout cache budget

    /// Off-screen layouts are bounded by memory, not row or line count: a
    /// one-line row can hold megabytes of glyphs (Ghostty bounds scrollback
    /// in bytes, `max_scrollback_bytes`, for the same reason).
    @MainActor @Test func layoutCacheEvictsLongSingleLineRowsByTheirSize() async {
        let style = TextStyle.current()
        let controller = TranscriptController(configuration: .testing)
        let host = FakeTranscriptHost()
        host.size = CGSize(width: 800, height: 600)
        host.controller = controller
        controller.attach(host)
        let line = String(repeating: #"{"k":"value","n":12345},"#, count: 200 * 1024 / 24)
        let rows = (0..<4).map { index in
            TranscriptRow(id: "c\(index)", kind: .markdownBlock(.code(language: "json", code: line), .single))
        }
        let heights = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, CGFloat(2_000)) })
        controller.setRows(rows, measuredHeights: heights)
        let key = controller.currentKey(rows[0])
        let built = await Task.detached {
            rows.map { RowLayoutBuilder.layout(RowLayoutRequest(rowID: $0.id, kind: $0.kind, key: key, style: style)) }
        }.value
        for layout in built { controller.storeLayout(layout) }
        // Four rows of a 200 KB line: ~5.6 MB of glyph positions and carets
        // each (> 12 MB budget). Only the rows near the viewport may stay.
        controller.dropLayouts(outside: 0...2_000)
        #expect(controller.layouts.count <= 2, "kept \(controller.layouts.count) off-screen megabyte layouts")
    }

    // MARK: Pathological Markdown

    /// cmark's pathological inputs parse in linear time: four times the
    /// input takes well under sixteen times as long.
    @Test(arguments: [
        "nested strong emph", "emph closers", "emph openers", "link closers", "link openers", "mismatched",
        "multiple of 3", "link openers emph closers", "[ (](", "![[]()", "nested brackets", "backticks",
        "unclosed links A", "unclosed links B", "unclosed <!--", "many references", "table cells", "autolinks",
        "entities", "inline html",
    ])
    func pathologicalMarkdownParsesInLinearTime(name: String) {
        func input(_ n: Int) -> String {
            switch name {
            case "nested strong emph": String(repeating: "*a **a ", count: n) + "b" + String(repeating: " a** a*", count: n)
            case "emph closers": String(repeating: "a_ ", count: n)
            case "emph openers": String(repeating: "_a ", count: n)
            case "link closers": String(repeating: "a]", count: n)
            case "link openers": String(repeating: "[a", count: n)
            case "mismatched": String(repeating: "*a_ ", count: n)
            case "multiple of 3": "a**b" + String(repeating: "c* ", count: n)
            case "link openers emph closers": String(repeating: "[ a_", count: n)
            case "[ (](": String(repeating: "[ (](", count: n)
            case "![[]()": String(repeating: "![[]()", count: n)
            case "nested brackets": String(repeating: "[", count: n) + "a" + String(repeating: "]", count: n)
            case "backticks": (1..<max(2, n / 40)).map { "e" + String(repeating: "`", count: $0) }.joined()
            case "unclosed links A": String(repeating: "[a](<b", count: n)
            case "unclosed links B": String(repeating: "[a](b", count: n)
            case "unclosed <!--": "</" + String(repeating: "<!--", count: n)
            case "many references": (0..<n).map { "[\($0)]: u\n" }.joined() + String(repeating: "[0] ", count: n)
            case "table cells": "| a |\n| --- |\n" + String(repeating: "|", count: n) + "\n" + String(repeating: "| x ", count: n)
            case "autolinks": String(repeating: "www.a.com/(((", count: n)
            case "entities": String(repeating: "&#x", count: n) + String(repeating: "&amp", count: n)
            default: String(repeating: "<a b='", count: n)
            }
        }
        func seconds(_ n: Int) -> Double {
            let text = input(n)
            var best = Double.infinity
            for _ in 0..<3 {
                let start = ContinuousClock.now
                _ = MarkdownPlanner.blocks(from: text)
                var parser = StreamingMarkdownParser()
                _ = parser.update(text)
                let elapsed = start.duration(to: .now).components
                best = min(best, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            }
            return best
        }
        let small = seconds(5_000)
        let large = seconds(20_000)
        #expect(large < max(0.05, small * 9), "\(name): 4x input took \(large / max(small, 1e-9))x as long (\(large) s)")
    }

    /// The deepest nesting the parser builds survives every recursive pass
    /// (parse, chunk, estimate, lay out, compare, hash, free) on a worker
    /// thread's 512 KB stack, where the engine runs them.
    @Test func deepNestingSurvivesTheWholePipelineOnAWorkerStack() async {
        // Each past the parser's 250 levels: quotes, indented lists, and
        // quotes around lists around lists.
        let sources = [
            String(repeating: "> ", count: 300) + "deep",
            (0..<300).map { String(repeating: "  ", count: $0) + "* a" }.joined(separator: "\n"),
            String(repeating: "> ", count: 200) + String(repeating: "- 1. ", count: 40) + "x",
        ]
        let style = await TextStyle.current()
        let survived = await Task.detached(priority: .userInitiated) {
            for source in sources {
                let blocks = MarkdownPlanner.blocks(from: source)
                let rows = TranscriptRowChunker.assistantRows(messageID: "m", turnID: "t", blocks: blocks)
                var hasher = Hasher()
                for row in rows {
                    _ = HeightEstimator.estimate(row.kind, width: 700, style: style)
                    _ = RowLayoutBuilder.layout(
                        RowLayoutRequest(
                            rowID: row.id, kind: row.kind,
                            key: RowLayoutKey(contentVersion: 0, width: 700, styleVersion: style.version), style: style))
                    _ = RowSelectableText.string(for: row.kind, style: style)
                    hasher.combine(row.kind)
                }
                // Parsed again: equal values in other storage compare all the way down.
                let again = TranscriptRowChunker.assistantRows(
                    messageID: "m", turnID: "t", blocks: MarkdownPlanner.blocks(from: source))
                guard zip(rows, again).allSatisfy({ $0.kind == $1.kind }) else { return false }
                var parser = StreamingMarkdownParser()
                _ = parser.update(source)
                _ = parser.finish(source)
            }
            return true
        }.value
        #expect(survived)
    }
}
