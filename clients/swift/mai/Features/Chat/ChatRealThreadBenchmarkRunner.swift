#if DEBUG
import OSLog
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Runs the auto-benchmark plans against the production chat transcript:
///
///     -ChatAutoBenchmark suite -ChatBenchmarkSyntheticTurns 1000
///     -ChatAutoBenchmark stream -ChatBenchmarkSyntheticTurns 20
///     -ChatAutoBenchmark markdown
///
/// `suite` runs the entire regression suite (cold opens, cold→warm scroll,
/// fast fling, high-rate stream, stream-while-scrolling, live resize, and
/// physical memory footprint) in a single app launch.
struct ChatRealThreadBenchmarkRunner: ViewModifier {
    let store: ThreadStore
    let selectThread: (String) -> Void

    @State private var benchmark = ChatBenchmarkModel()
    @State private var didRun = false

    func body(content: Content) -> some View {
        content
            #if os(macOS)
                .background {
                    if ChatBenchmarkAutoRun.plan != nil {
                        BenchmarkWindowConfigurator()
                    }
                }
            #endif
            .task {
                guard !didRun,
                    let plan = ChatBenchmarkAutoRun.plan,
                    let query = ChatBenchmarkAutoRun.threadTitleQuery
                else { return }
                didRun = true
                await run(plan: plan, query: query)
            }
    }

    private func run(plan: String, query: String) async {
        if plan == "markdown" {
            await ChatMarkdownReplayBenchmark.run()
            finish("CHAT_BENCHMARK_COMPLETE")
            return
        }
        if plan == "export" {
            exportSyntheticBenchmarks()
            finish("CHAT_BENCHMARK_COMPLETE")
            return
        }

        // Prevent App Nap, timer coalescing, and background QoS throttling so
        // unfocused benchmark runs stay on full-speed cores.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Chat benchmark"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        ChatBenchmarkAutoRun.trace("benchmark start: plan=\(plan) query=\(query)")
        guard await pinWindowForDeterministicRuns() else {
            finish("invalid measurement: benchmark window did not reach the requested size or is occluded")
            return
        }

        guard let entry = await waitForThread(matching: query) else {
            finish("invalid measurement: no thread matching \"\(query)\"")
            return
        }
        selectThread(entry.id)
        guard await waitForSelectedThreadLoaded() else {
            finish("invalid measurement: thread failed to load")
            return
        }

        switch plan {
        case "stream":
            await runStandaloneStream()
        case "giant":
            await runGiantSuite()
        case "bare-resize":
            await runBareResizeIsolation(threadID: entry.id)
        default:
            await runSuite()
        }
        finish("CHAT_BENCHMARK_COMPLETE")
    }

    /// Isolates transcript live-resize cost in a bare AppKit `NSWindow`
    /// (`NSScrollView` + `TranscriptDocumentView`, no SwiftUI chrome) and
    /// compares it directly against the full SwiftUI chat window on the same
    /// 1,000-turn transcript.
    private func runBareResizeIsolation(threadID: String) async {
        #if os(macOS)
            guard let appWindow = ChatBenchmarkModel.appWindow() else { return }
            let targetFrame = appWindow.frame
            let targetContent = appWindow.contentRect(forFrameRect: targetFrame).size
            let background = ChatBenchmarkAutoRun.runsInBackground

            let bareController = TranscriptController(configuration: .launch)
            let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: targetContent))
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            let document = TranscriptDocumentView(controller: bareController)
            scrollView.documentView = document
            let bareWindow = NSWindow(
                contentRect: NSRect(origin: .zero, size: targetContent),
                styleMask: [.titled], backing: .buffered, defer: false)
            bareWindow.isReleasedWhenClosed = false
            bareWindow.setAccessibilitySubrole(.dialog)
            bareWindow.contentMinSize = targetContent
            bareWindow.contentMaxSize = targetContent
            bareWindow.setFrame(targetFrame, display: false)
            bareWindow.contentView = scrollView
            appWindow.orderOut(nil)
            if background {
                bareWindow.collectionBehavior.insert(.canJoinAllSpaces)
                bareWindow.orderBack(nil)
            } else {
                bareWindow.makeKeyAndOrderFront(nil)
            }
            bareController.start(store: store, threadID: threadID)

            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while bareController.isAwaitingInitialEnd || !bareWindow.occlusionState.contains(.visible),
                ContinuousClock.now < deadline
            {
                try? await Task.sleep(for: .milliseconds(25))
            }
            try? await Task.sleep(for: .milliseconds(150))
            _ = await benchmark.runResizeBenchmark(
                in: bareWindow, minimumWidth: 600, seconds: 2, label: "bare-resize-2s")
            bareWindow.contentView = nil
            bareWindow.orderOut(nil)
            bareWindow.close()

            if background { appWindow.orderBack(nil) } else { appWindow.makeKeyAndOrderFront(nil) }
            let restoreDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !appWindow.occlusionState.contains(.visible), ContinuousClock.now < restoreDeadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            try? await Task.sleep(for: .milliseconds(150))
            _ = await benchmark.runResizeBenchmark(
                in: appWindow, minimumWidth: 600, seconds: 2, label: "swiftui-resize-2s")
        #endif
    }

    /// Exports the 1,000-turn and 5 MB synthetic benchmark transcripts to JSON
    /// for the head-to-head browser harness (`-ChatAutoBenchmark export
    /// -ChatBenchmarkExportDir <path>`).
    private func exportSyntheticBenchmarks() {
        let dir =
            UserDefaults.standard.string(forKey: "ChatBenchmarkExportDir")
            ?? ".scratch/chat-rewrite/bench/web/fixtures"
        let baseURL = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let threads: [(file: String, detail: ThreadDetail)] = [
            ("synthetic-1000.json", ChatSyntheticBenchmarkThread.thread(turnCount: 1_000, uniqueAnswers: true)),
            ("synthetic-5mb.json", ChatSyntheticBenchmarkThread.largeThread()),
        ]
        for (file, detail) in threads {
            let turns: [[String: Any]] = detail.turns.map { turn in
                let entries: [[String: Any]] = turn.entries.map { entry in
                    [
                        "ref": entry.ref,
                        "kind": entry.kind,
                        "text": entry.text ?? "",
                        "title": entry.title ?? "",
                    ]
                }
                return ["id": turn.id, "entries": entries]
            }
            let payload: [String: Any] = ["id": detail.id, "title": detail.summary.title, "turns": turns]
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                let target = baseURL.appending(path: file)
                if (try? data.write(to: target)) != nil {
                    ChatBenchmarkAutoRun.trace("exported \(file) path=\(target.path) bytes=\(data.count) turns=\(turns.count)")
                } else {
                    let fallback = FileManager.default.temporaryDirectory.appending(path: file)
                    try? data.write(to: fallback)
                    ChatBenchmarkAutoRun.trace("exported \(file) path=\(fallback.path) bytes=\(data.count) turns=\(turns.count)")
                }
            }
        }
    }

    /// Measures time to visible, footprint, scrolling frame pacing, and live
    /// resize on the 4 giant single-block fixtures (Phase 2 Step 1).
    private func runGiantSuite() async {
        for (name, detail) in ChatSyntheticBenchmarkThread.giantFixtureThreads() {
            let buildStarted = ContinuousClock.now
            store.insertSyntheticBenchmarkThread(detail)
            let buildMs = Self.milliseconds(buildStarted.duration(to: .now))

            ChatBenchmarkAutoRun.isTranscriptWarm = false
            ChatBenchmarkAutoRun.isInitialAlignmentComplete = false
            let started = ContinuousClock.now
            selectThread(detail.id)

            guard await waitUntilAligned(timeoutSeconds: 30) else {
                ChatBenchmarkAutoRun.trace("invalid measurement: open-\(name) initial alignment timed out")
                return
            }
            let visibleMs = Self.milliseconds(started.duration(to: .now))
            await ChatBenchmarkAutoRun.awaitTranscriptWarm(timeoutSeconds: 60)
            let settledMs = Self.milliseconds(started.duration(to: .now))
            let memory = ChatBenchmarkModel.processMemoryMB()
            emitJSON([
                "label": "open-\(name)",
                "measurementKind": "openCheckpoint",
                "visibleMilliseconds": visibleMs,
                "settledMilliseconds": settledMs,
                "threadBuildMilliseconds": buildMs,
                "footprintMB": memory.footprint,
                "peakFootprintMB": memory.peakFootprint,
                "residentMB": memory.resident,
                "aligned": ChatBenchmarkAutoRun.isInitialAlignmentComplete,
                "visible": isAppWindowVisible,
            ])

            try? await Task.sleep(for: .milliseconds(32))
            _ = await benchmark.runScrollBenchmark(
                pointsPerSecond: 3_000, maximumSweepSeconds: 3, label: "scroll-\(name)")
            #if os(macOS)
                if let window = ChatBenchmarkModel.appWindow() {
                    _ = await benchmark.runResizeBenchmark(
                        in: window, minimumWidth: 600, seconds: 2, label: "resize-\(name)")
                    try? await Task.sleep(for: .milliseconds(100))
                    await ChatBenchmarkAutoRun.awaitTranscriptWarm(timeoutSeconds: 30)
                }
            #endif
        }
        emitMemoryCheckpoint(label: "memory-final")
    }

    /// Single-launch full benchmark covering every transcript hotspot:
    /// 1. Cold opens across unique 1000-turn chats + memory checkpoints
    /// 2. Cold→warm 3000 pps scroll + 8000 pps fling (0 ms warmup sleep)
    /// 3. High-rate 4000 chars/s streaming + exact-source verification
    /// 4. Stream-while-scrolling contention at 3000 pps
    /// 5. Live 1280→600→1280 resize reflow (macOS)
    /// 6. Final physical footprint / peak footprint / RSS checkpoint
    private func runSuite() async {
        let turns = ChatBenchmarkAutoRun.syntheticThreadTurnCount ?? 1_000
        guard let activeThreadID = await runColdOpens(turnCount: turns) else { return }

        // Let the freshly aligned end screen finish its first raster pass
        // (all off-screen turns remain cold and unparsed), then scroll at once.
        try? await Task.sleep(for: .milliseconds(32))
        _ = await benchmark.runScrollBenchmark(
            pointsPerSecond: 3_000, maximumSweepSeconds: 3, label: "cold-scroll-3000pps")
        _ = await benchmark.runScrollBenchmark(
            pointsPerSecond: 8_000, maximumSweepSeconds: 2, label: "cold-fling-8000pps")

        await runStreamPhase(
            threadID: activeThreadID, turnID: "suite-stream-turn", label: "stream-4000cps", scroll: false)
        await runStreamPhase(
            threadID: activeThreadID, turnID: "suite-stream-scroll-turn", label: "stream-scroll-3000pps", scroll: true)

        #if os(macOS)
            if let window = ChatBenchmarkModel.appWindow() {
                _ = await benchmark.runResizeBenchmark(
                    in: window, minimumWidth: 600, seconds: 2, label: "live-resize-2s")
                try? await Task.sleep(for: .milliseconds(100))
                await ChatBenchmarkAutoRun.awaitTranscriptWarm(timeoutSeconds: 30)
            }
        #endif

        emitMemoryCheckpoint(label: "memory-final")
    }

    /// Opens two fresh unique threads after the initial thread (3 resident
    /// chats total), measuring cold open latency and memory footprint.
    /// Returns the last selected thread ID, still cold and freshly aligned.
    private func runColdOpens(turnCount: Int) async -> String? {
        var lastID = ChatSyntheticBenchmarkThread.threadID
        for step in 1...2 {
            let identity = "synthetic-benchmark-\(step + 1)"
            let buildStarted = ContinuousClock.now
            let thread = ChatSyntheticBenchmarkThread.thread(turnCount: turnCount, identity: identity)
            store.insertSyntheticBenchmarkThread(thread)
            let buildMs = Self.milliseconds(buildStarted.duration(to: .now))

            ChatBenchmarkAutoRun.isTranscriptWarm = false
            ChatBenchmarkAutoRun.isInitialAlignmentComplete = false
            let started = ContinuousClock.now
            selectThread(identity)

            guard await waitUntilAligned(timeoutSeconds: 30) else {
                ChatBenchmarkAutoRun.trace("invalid measurement: open-\(step) initial alignment timed out")
                return nil
            }
            let visibleMs = Self.milliseconds(started.duration(to: .now))
            await ChatBenchmarkAutoRun.awaitTranscriptWarm(timeoutSeconds: 60)
            let settledMs = Self.milliseconds(started.duration(to: .now))
            let memory = ChatBenchmarkModel.processMemoryMB()
            emitJSON([
                "label": "open-\(step)",
                "measurementKind": "openCheckpoint",
                "loadedChats": step + 1,
                "visibleMilliseconds": visibleMs,
                "settledMilliseconds": settledMs,
                "threadBuildMilliseconds": buildMs,
                "footprintMB": memory.footprint,
                "peakFootprintMB": memory.peakFootprint,
                "residentMB": memory.resident,
                "aligned": ChatBenchmarkAutoRun.isInitialAlignmentComplete,
                "visible": isAppWindowVisible,
            ])
            lastID = identity
        }
        return lastID
    }

    private func runStreamPhase(threadID: String, turnID: String, label: String, scroll: Bool) async {
        let configuredRate = UserDefaults.standard.double(forKey: "ChatBenchmarkStreamCharactersPerSecond")
        let rate = configuredRate > 0 ? configuredRate : 4_000
        let driver = ChatSyntheticStreamingBenchmark(
            store: store, threadID: threadID,
            includesActivity: UserDefaults.standard.bool(forKey: "ChatBenchmarkStreamActivity"),
            charactersPerSecond: rate, characterCount: 12_000, turnID: turnID)
        driver.prepare()
        try? await Task.sleep(for: .milliseconds(100))
        let stream = Task { await driver.run() }
        if scroll {
            _ = await benchmark.runScrollBenchmark(
                pointsPerSecond: 3_000, maximumSweepSeconds: 1.5, label: label)
        } else {
            _ = await benchmark.runStreamingBenchmark(
                label: label, maximumSeconds: 30, isDone: { driver.isFinished })
        }
        await stream.value
        ChatBenchmarkAutoRun.trace(
            "stream \(label) sourceMatches=\(driver.sourceMatches) completed=\(driver.isFinished)")
    }

    /// Standalone stream plan used by `record-chat-stream.py` and stream-only runs.
    private func runStandaloneStream() async {
        await ChatBenchmarkAutoRun.awaitTranscriptWarm(timeoutSeconds: 60)
        let configuredRate = UserDefaults.standard.double(forKey: "ChatBenchmarkStreamCharactersPerSecond")
        let driver = ChatSyntheticStreamingBenchmark(
            store: store,
            includesActivity: UserDefaults.standard.bool(forKey: "ChatBenchmarkStreamActivity"),
            charactersPerSecond: configuredRate > 0 ? configuredRate : 1_000,
            characterCount: UserDefaults.standard.integer(forKey: "ChatBenchmarkStreamCharacters") > 0
                ? UserDefaults.standard.integer(forKey: "ChatBenchmarkStreamCharacters") : 20_000)
        driver.prepare()
        try? await Task.sleep(for: .milliseconds(200))
        await ChatBenchmarkAutoRun.awaitTranscriptWarm(timeoutSeconds: 60)
        let stream = Task { await driver.run() }
        _ = await benchmark.runStreamingBenchmark(
            label: "stream-standalone", maximumSeconds: 60, isDone: { driver.isFinished })
        await stream.value
        ChatBenchmarkAutoRun.trace(
            "stream sourceMatches=\(driver.sourceMatches) completed=\(driver.isFinished)")
    }

    private func emitMemoryCheckpoint(label: String) {
        let memory = ChatBenchmarkModel.processMemoryMB()
        emitJSON([
            "label": label,
            "measurementKind": "memoryCheckpoint",
            "footprintMB": memory.footprint,
            "peakFootprintMB": memory.peakFootprint,
            "residentMB": memory.resident,
            "visible": isAppWindowVisible,
        ])
    }

    private func emitJSON(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let line = String(data: data, encoding: .utf8)
        else { return }
        print("CHAT_BENCHMARK_RESULT \(line)")
        ChatBenchmarkAutoRun.trace("CHAT_BENCHMARK_RESULT \(line)")
    }

    private var isAppWindowVisible: Bool {
        #if os(macOS)
            ChatBenchmarkModel.appWindow()?.occlusionState.contains(.visible) ?? false
        #else
            ChatBenchmarkModel.appWindow().map { !$0.isHidden } ?? false
        #endif
    }

    private func waitUntilAligned(timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        while !ChatBenchmarkAutoRun.isInitialAlignmentComplete, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return ChatBenchmarkAutoRun.isInitialAlignmentComplete
    }

    private func waitForThread(matching query: String) async -> ThreadSummary? {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if let match = store.threads.first(where: { $0.title.localizedCaseInsensitiveContains(query) }) {
                return match
            }
            if !store.threads.isEmpty, store.connectionState == .connected { return nil }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private func waitForSelectedThreadLoaded() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            if store.selectedThreadLoadErrorMessage != nil { return false }
            if let thread = store.selectedThread, !thread.turns.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    private func finish(_ message: String) {
        ChatBenchmarkAutoRun.logger.notice("\(message, privacy: .public)")
        ChatBenchmarkAutoRun.trace(message)
        print(message)
        if message != "CHAT_BENCHMARK_COMPLETE" {
            ChatBenchmarkAutoRun.trace("CHAT_BENCHMARK_COMPLETE")
            print("CHAT_BENCHMARK_COMPLETE")
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    /// Pins a deterministic 1280×900 window. In background mode it prefers a
    /// secondary display if attached and orders behind active windows without
    /// stealing focus.
    private func pinWindowForDeterministicRuns() async -> Bool {
        #if os(macOS)
            let background = ChatBenchmarkAutoRun.runsInBackground
            if !background { NSApplication.shared.activate() }
            guard let window = ChatBenchmarkModel.appWindow() else { return false }
            let target = NSSize(width: 1_280, height: 900)
            let screen =
                (background ? NSScreen.screens.first { $0 != NSScreen.main } : nil)
                ?? window.screen ?? NSScreen.main ?? NSScreen.screens.first
            func placeWindow() {
                window.styleMask.remove(.resizable)
                window.standardWindowButton(.zoomButton)?.isEnabled = false
                window.setAccessibilitySubrole(.dialog)
                window.contentMinSize = target
                window.contentMaxSize = target
                window.setContentSize(target)
                if let screen {
                    let visible = screen.visibleFrame
                    let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: target)).size
                    let origin =
                        background
                        ? NSPoint(x: screen.frame.minX, y: screen.frame.minY)
                        : NSPoint(
                            x: (visible.midX - frameSize.width / 2).rounded(),
                            y: (visible.midY - frameSize.height / 2).rounded())
                    window.setFrameOrigin(origin)
                } else {
                    window.center()
                }
                if background {
                    window.collectionBehavior.insert(.canJoinAllSpaces)
                    window.orderBack(nil)
                } else {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            placeWindow()
            let deadline = ContinuousClock.now + .seconds(10)
            var stableSince = ContinuousClock.now
            while ContinuousClock.now < deadline {
                let actual = window.contentRect(forFrameRect: window.frame).size
                let onScreen = window.screen?.frame.contains(window.frame) == true
                    && window.isOnActiveSpace && window.occlusionState.contains(.visible)
                let presentedWindows = CGWindowListCopyWindowInfo(
                    .optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]]
                let presented = presentedWindows?.first
                let bounds = presented?[kCGWindowBounds as String] as? [String: Double]
                let presentationMatches = presented?[kCGWindowIsOnscreen as String] as? Bool == true
                    && bounds?["Width"].map { abs($0 - window.frame.width) <= 1 } == true
                    && bounds?["Height"].map { abs($0 - window.frame.height) <= 1 } == true
                if abs(actual.width - target.width) <= 1,
                    abs(actual.height - target.height) <= 1, onScreen, presentationMatches,
                    !window.styleMask.contains(.fullScreen)
                {
                    if stableSince.duration(to: .now) >= .milliseconds(250) {
                        ChatBenchmarkAutoRun.trace(
                            "benchmark viewport verified windowNumber=\(window.windowNumber) background=\(background) content=\(actual) frame=\(window.frame)")
                        return true
                    }
                } else {
                    stableSince = .now
                    placeWindow()
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
            let occlusionNote = window.occlusionState.contains(.visible)
                ? "" : " (window completely covered; leave a strip visible, use a second display, or pass --foreground)"
            ChatBenchmarkAutoRun.trace(
                "invalid measurement: actual window frame=\(window.frame) visible=\(window.occlusionState.contains(.visible))\(occlusionNote)")
            return false
        #else
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene,
                    let restrictions = windowScene.sizeRestrictions
                else { continue }
                restrictions.minimumSize = CGSize(width: 1_280, height: 900)
                restrictions.maximumSize = CGSize(width: 1_280, height: 900)
            }
            return true
        #endif
    }
}

#if os(macOS)
    /// Configures the benchmark window before WindowServer/tiling WMs
    /// (AeroSpace, yabai) inspect it so it is classified as a floating dialog
    /// rather than tiled into the user's workspace, while still allowing
    /// programmatic `setContentSize` during `live-resize-2s`.
    private struct BenchmarkWindowConfigurator: NSViewRepresentable {
        func makeNSView(context: Context) -> ConfigView { ConfigView() }
        func updateNSView(_ nsView: ConfigView, context: Context) {}

        final class ConfigView: NSView {
            override func viewWillMove(toWindow newWindow: NSWindow?) {
                super.viewWillMove(toWindow: newWindow)
                guard let window = newWindow else { return }
                window.styleMask.remove(.resizable)
                window.standardWindowButton(.zoomButton)?.isEnabled = false
                window.setAccessibilitySubrole(.dialog)
                if ChatBenchmarkAutoRun.runsInBackground {
                    window.collectionBehavior.insert(.canJoinAllSpaces)
                    window.orderBack(nil)
                }
            }
        }
    }
#endif
#endif
