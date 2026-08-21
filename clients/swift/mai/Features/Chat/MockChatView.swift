import Foundation
import OSLog
import Observation
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Keeps the profiling fixture reachable in optimized iOS builds without
/// exposing it during ordinary Release launches.
nonisolated enum ChatPerformanceLab {
    static let launchArgument = "-ChatPerformanceLab"

    static let isEnabled: Bool = {
        #if DEBUG
            true
        #else
            ProcessInfo.processInfo.arguments.contains(launchArgument)
        #endif
    }()
}

private enum MockChatStressTranscriptSize: Int, CaseIterable, Hashable, Identifiable {
    case oneThousand = 1_000
    case fiveThousand = 5_000
    case tenThousand = 10_000

    var id: Self { self }

    var label: String {
        "\(rawValue.formatted()) rows"
    }
}

/// Internal screen for profiling the production chat renderer with
/// deterministic transcripts.
struct MockChatView: View {
    @State private var messages: [MockChatMessage]
    @State private var prompt = ""
    @State private var replyTask: Task<Void, Never>?
    @State private var feedTask: Task<Void, Never>?
    @State private var loadingTask: Task<Void, Never>?
    @State private var activeStream: MockChatActiveStream?
    @State private var scrollState = ChatScrollState()
    @State private var isLoading = false
    @State private var stressTranscriptSize = MockChatStressTranscriptSize.fiveThousand
    @State private var streamProfile = MockChatStreamProfile.readableTokens
    @State private var showsMessageDiagnostics = true
    @State private var showsRawMarkdown = false
    @State private var benchmark = ChatBenchmarkModel()
    @State private var showsBenchmarkReport = false
    @State private var didAutoRunBenchmark = false

    init(
        initialMessages: [MockChatMessage] = MockChatMessage.shortConversation,
        showsMessageDiagnostics: Bool = true
    ) {
        _messages = State(initialValue: initialMessages)
        _showsMessageDiagnostics = State(initialValue: showsMessageDiagnostics)
        ChatBenchmarkAutoRun.trace("MockChatView init")
    }

    private var isRunning: Bool { activeStream != nil }
    private var isPaused: Bool { activeStream != nil && replyTask == nil }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading Chat…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MockChatTimeline(
                    messages: messages,
                    scrollState: scrollState,
                    showsMessageDiagnostics: showsMessageDiagnostics,
                    showsRawMarkdown: showsRawMarkdown
                )
            }
        }
        .overlay(alignment: .bottom) {
            MockChatScrollToBottomButton(scrollState: scrollState) {
                scrollState.requestScrollToBottom(animated: true)
            }
            .safeAreaPadding(.bottom)
        }
        .modifier(
            MockChatComposerSafeAreaBar(
                prompt: $prompt,
                isRunning: isRunning,
                send: send,
                stop: stopReply
            )
        )
        .navigationTitle("Mock Chat")
        .toolbar {
            Menu("Timeline", systemImage: "list.bullet") {
                Picker("Large Transcript Size", selection: $stressTranscriptSize) {
                    ForEach(MockChatStressTranscriptSize.allCases) { size in
                        Text(size.label)
                            .tag(size)
                    }
                }

                Button(
                    "Load Variable-height Transcript",
                    systemImage: "doc.text.magnifyingglass"
                ) {
                    loadLargeTranscript(startsStream: false)
                }

                Button(
                    "Load Transcript and Stream",
                    systemImage: "text.append"
                ) {
                    loadLargeTranscript(startsStream: true)
                }
            }

            Menu("Markdown stream", systemImage: "text.append") {
                Picker("Pacing", selection: $streamProfile) {
                    ForEach(MockChatStreamProfile.allCases) { profile in
                        Text(profile.label)
                            .tag(profile)
                    }
                }

                Text(streamProfile.detail)

                Divider()

                Button("Stream All Components", systemImage: "text.badge.plus") {
                    startFocusedStream(
                        source: MockChatMarkdownFixtures.componentCatalog,
                        label: "All components"
                    )
                }

                Button(
                    "Stream Code-heavy Response",
                    systemImage: "chevron.left.forwardslash.chevron.right"
                ) {
                    startFocusedStream(
                        source: MockChatMarkdownFixtures.codeHeavy,
                        label: "Code-heavy"
                    )
                }

                Button(
                    "Stream Swift Highlighting",
                    systemImage: "swift"
                ) {
                    startFocusedStream(
                        source: MockChatMarkdownFixtures.swiftHighlighting,
                        label: "Swift highlighting"
                    )
                }

                Button("Stream Long Response", systemImage: "doc.text") {
                    startFocusedStream(
                        source: MockChatMarkdownFixtures.longMarkdown,
                        label: "Long Markdown"
                    )
                }

                Button("Leave an Unclosed Fence", systemImage: "exclamationmark.triangle") {
                    startFocusedStream(
                        source: MockChatMarkdownFixtures.unclosedFence,
                        label: "Incomplete fence"
                    )
                }

                Button(
                    "Stream Unsupported Content",
                    systemImage: "exclamationmark.shield"
                ) {
                    startFocusedStream(
                        source: MockChatMarkdownFixtures.unsupportedMarkdown,
                        label: "Unsupported content"
                    )
                }

                Button(
                    "Stress Existing Transcript",
                    systemImage: "gauge.with.dots.needle.67percent"
                ) {
                    reset(to: MockChatMessage.stressConversation)
                    enqueueStream(
                        source: MockChatMarkdownFixtures.componentCatalog,
                        label: "Streaming row after stable history"
                    )
                }

                if activeStream != nil {
                    Divider()

                    if isPaused {
                        Button("Resume Stream", systemImage: "play.fill") {
                            resumeStream()
                        }
                    } else {
                        Button("Pause Stream", systemImage: "pause.fill") {
                            pauseStream()
                        }
                    }

                    Button(
                        "Replace Active Source",
                        systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
                    ) {
                        replaceActiveSource()
                    }

                    Button("Finish Here", role: .destructive) {
                        stopReply()
                    }
                }
            }

            Menu("Benchmark", systemImage: "speedometer") {
                Button("Scroll Sweep (3,000 pt/s)", systemImage: "arrow.up.arrow.down") {
                    runManualScrollBenchmark(
                        pointsPerSecond: 3_000,
                        label: "scroll-\(messages.count)rows-3000pps"
                    )
                }

                Button("Fling Sweep (8,000 pt/s)", systemImage: "hare") {
                    runManualScrollBenchmark(
                        pointsPerSecond: 8_000,
                        label: "fling-\(messages.count)rows-8000pps"
                    )
                }

                Button("Streaming Pass (rapid burst)", systemImage: "waveform") {
                    Task {
                        _ = await runStreamingBenchmark()
                        showsBenchmarkReport = benchmark.latestReport != nil
                    }
                }
            }
            .disabled(benchmark.isRunning)

            Menu("Sandbox", systemImage: "wrench.and.screwdriver") {
                Toggle("Show Message Diagnostics", isOn: $showsMessageDiagnostics)
                Toggle("Show Raw Markdown", isOn: $showsRawMarkdown)

                Divider()

                Button("Rich Blocks Comparison") {
                    reset(to: MockChatMessage.richBlocksConversation)
                }
                Button("Component Catalog") {
                    reset(to: MockChatMessage.componentConversation)
                }
                Button("Malformed and Partial") {
                    reset(to: MockChatMessage.malformedConversation)
                }
                Button("Unsupported and Unsafe") {
                    reset(to: MockChatMessage.unsupportedConversation)
                }
                Button("Code-heavy") {
                    reset(to: MockChatMessage.codeHeavyConversation)
                }
                Button("Swift Highlighting") {
                    reset(to: MockChatMessage.swiftHighlightingConversation)
                }
                Button("File-change Diff") {
                    reset(to: MockChatMessage.fileChangesConversation)
                }
                Button("Super-large Diff") {
                    reset(to: MockChatMessage.largeFileChangesConversation)
                }
                Button("Long Markdown") {
                    reset(to: MockChatMessage.longMarkdownConversation)
                }
                Button("Long Conversation") {
                    reset(to: MockChatMessage.longConversation)
                }
                Button("100-row Stress Transcript") {
                    reset(to: MockChatMessage.stressConversation)
                }
                Button("Giant Essays (3k · 5k · 10k words)") {
                    reset(to: MockChatMessage.giantEssayConversation)
                }
                Button("Giant Essays (assistant only)") {
                    reset(to: MockChatMessage.giantEssayAssistantOnlyConversation)
                }
                Button("Short Conversation") {
                    reset(to: MockChatMessage.shortConversation)
                }
                Button("Empty") {
                    reset(to: [])
                }
                Button("Simulate Loading") {
                    simulateLoading()
                }

                Divider()

                Button(
                    feedTask == nil ? "Start Incoming Feed" : "Stop Incoming Feed",
                    systemImage: feedTask == nil ? "play.circle" : "stop.circle"
                ) {
                    toggleFeed()
                }

                // Content shrink without a scroll request exercises the
                // scroll view's raw offset clamp.
                Button("Remove Last Message", role: .destructive) {
                    removeLastMessage()
                }
            }
        }
        .alert(
            "Frame Pacing",
            isPresented: $showsBenchmarkReport,
            presenting: benchmark.latestReport
        ) { _ in
            Button("OK") {}
        } message: { report in
            Text(report.summary)
        }
        .task {
            guard let plan = ChatBenchmarkAutoRun.plan, !didAutoRunBenchmark
            else { return }
            didAutoRunBenchmark = true
            ChatBenchmarkAutoRun.trace("auto benchmark task fired")
            await runAutoBenchmark(plan: plan)
        }
        .onDisappear {
            stopReply()
            feedTask?.cancel()
            feedTask = nil
            loadingTask?.cancel()
            loadingTask = nil
            isLoading = false
        }
    }

    private func runManualScrollBenchmark(
        pointsPerSecond: CGFloat,
        label: String
    ) {
        Task {
            _ = await benchmark.runScrollBenchmark(
                pointsPerSecond: pointsPerSecond,
                maximumSweepSeconds: 12,
                label: label
            )
            showsBenchmarkReport = benchmark.latestReport != nil
        }
    }

    /// Streams a long essay followed by the full component catalog at the
    /// harshest pacing while recording frame pacing at the pinned bottom.
    private func runStreamingBenchmark() async -> ChatFramePacingReport? {
        streamProfile = .rapidBurst
        startFocusedStream(
            source: MockChatMessage.essay(wordCount: 4_000)
                + "\n\n"
                + MockChatMarkdownFixtures.componentCatalog,
            label: "Benchmark stream"
        )
        guard let liveMessage = activeStream?.liveMessage else { return nil }
        // Give the reset a beat to mount before measurement starts.
        try? await Task.sleep(for: .milliseconds(300))
        return await benchmark.runStreamingBenchmark(
            label: "stream-essay+catalog-rapidBurst",
            maximumSeconds: 90,
            isDone: { !liveMessage.isStreaming }
        )
    }

    /// The headless pass: a markdown-heavy 10k-row transcript scrolled at two
    /// velocities, then the streaming pass. One JSON line prints per report.
    private func runAutoBenchmark(plan: String) async {
        ChatBenchmarkAutoRun.logger.notice(
            "auto benchmark plan: \(plan, privacy: .public)"
        )
        // Production rows carry no per-message debug labels.
        showsMessageDiagnostics = false
        // A deterministic window keeps runs comparable across launches.
        #if os(macOS)
            for window in NSApplication.shared.windows {
                window.setContentSize(NSSize(width: 1_280, height: 900))
                window.contentMinSize = NSSize(width: 1_280, height: 900)
                window.contentMaxSize = NSSize(width: 1_280, height: 900)
            }
        #else
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene,
                    let restrictions = windowScene.sizeRestrictions
                else { continue }
                restrictions.minimumSize = CGSize(width: 1_280, height: 900)
                restrictions.maximumSize = CGSize(width: 1_280, height: 900)
            }
        #endif
        stressTranscriptSize = .tenThousand
        loadLargeTranscript(startsStream: false)
        // Let initial mount and the bottom anchor settle, then wait for the
        // whole transcript to be prepared the way production pagination
        // prepares each page before showing it.
        try? await Task.sleep(for: .seconds(4))
        await ChatBenchmarkAutoRun.awaitTranscriptWarm(timeoutSeconds: 120)

        if plan == "scroll" || plan == "all" {
            _ = await benchmark.runScrollBenchmark(
                pointsPerSecond: 1_200,
                maximumSweepSeconds: 10,
                label: "cruise-10k-1200pps"
            )
            try? await Task.sleep(for: .seconds(1))
            _ = await benchmark.runScrollBenchmark(
                pointsPerSecond: 3_000,
                maximumSweepSeconds: 12,
                label: "scroll-10k-3000pps"
            )
            try? await Task.sleep(for: .seconds(1))
            _ = await benchmark.runScrollBenchmark(
                pointsPerSecond: 8_000,
                maximumSweepSeconds: 8,
                label: "fling-10k-8000pps"
            )
        }
        if plan == "stream" || plan == "all" {
            try? await Task.sleep(for: .seconds(1))
            _ = await runStreamingBenchmark()
        }
        ChatBenchmarkAutoRun.logger.notice("CHAT_BENCHMARK_COMPLETE")
        ChatBenchmarkAutoRun.trace("CHAT_BENCHMARK_COMPLETE")
        print("CHAT_BENCHMARK_COMPLETE")
    }

    private func loadLargeTranscript(startsStream: Bool) {
        reset(
            to: MockChatMessage.variableHeightStressConversation(
                count: stressTranscriptSize.rawValue
            )
        )
        guard startsStream else { return }
        enqueueStream(
            source: MockChatMarkdownFixtures.componentCatalog,
            label: "Stream after \(stressTranscriptSize.label)"
        )
    }

    private func simulateLoading() {
        // Mirrors ChatView's structure: the ProgressView branch replaces
        // the ScrollView entirely, so when messages land the ScrollView is
        // created fresh and its initialOffset anchor opens it at the
        // bottom.
        reset(to: [])
        isLoading = true
        loadingTask = Task {
            do {
                try await Task.sleep(for: .seconds(1.2))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            messages = MockChatMessage.longMarkdownConversation
            isLoading = false
            loadingTask = nil
        }
    }

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prompt = ""

        loadingTask?.cancel()
        loadingTask = nil
        isLoading = false
        messages.append(MockChatMessage(role: .user, text: text))
        enqueueStream(
            source: MockChatMarkdownFixtures.streamedReply(prompt: text),
            label: "Composer reply"
        )
    }

    private func startFocusedStream(source: String, label: String) {
        reset(
            to: [
                MockChatMessage(
                    role: .user,
                    text: "Exercise the **\(label)** Markdown streaming fixture."
                )
            ]
        )
        enqueueStream(source: source, label: label)
    }

    private func enqueueStream(source: String, label: String) {
        stopReply()

        let liveMessage = MockChatStreamingMessage(
            label: label,
            renderThrottle: streamProfile.renderThrottle
        )
        let reply = MockChatMessage(
            role: .agent,
            text: "",
            isStreaming: true,
            label: label,
            renderThrottle: streamProfile.renderThrottle,
            liveMessage: liveMessage
        )
        messages.append(reply)
        activeStream = MockChatActiveStream(
            messageID: reply.id,
            liveMessage: liveMessage,
            chunks: MockChatMarkdownStream.chunks(
                source: source,
                profile: streamProfile
            ),
            profile: streamProfile
        )
        resumeStream()
    }

    private func resumeStream() {
        guard replyTask == nil, let stream = activeStream else { return }
        let streamID = stream.id

        replyTask = Task {
            while activeStream === stream,
                stream.nextChunkIndex < stream.chunks.count
            {
                let chunk = stream.chunks[stream.nextChunkIndex]
                do {
                    try await Task.sleep(for: stream.profile.delay)
                } catch {
                    return
                }
                guard !Task.isCancelled, activeStream === stream else { return }

                stream.liveMessage.append(chunk)
                stream.nextChunkIndex += 1
            }

            guard !Task.isCancelled, activeStream?.id == streamID else { return }
            finishStream(streamID: streamID)
        }
    }

    private func pauseStream() {
        guard activeStream != nil else { return }
        replyTask?.cancel()
        replyTask = nil
    }

    private func replaceActiveSource() {
        guard let stream = activeStream else { return }

        pauseStream()

        let replacementPrefix = """
            # Source replaced while streaming

            This is a non-prefix edit. The streaming parser should discard its
            incremental assumption, perform a safe full parse, and then continue.

            """
        stream.liveMessage.replace(
            with: replacementPrefix,
            label: "Replacement then append"
        )
        activeStream = MockChatActiveStream(
            messageID: stream.messageID,
            liveMessage: stream.liveMessage,
            chunks: MockChatMarkdownStream.chunks(
                source: MockChatMarkdownFixtures.componentCatalog,
                profile: stream.profile
            ),
            profile: stream.profile
        )
        resumeStream()
    }

    private func finishStream(streamID: UUID) {
        guard let stream = activeStream, stream.id == streamID else { return }
        stream.liveMessage.finish()
        activeStream = nil
        replyTask = nil
    }

    private func stopReply() {
        replyTask?.cancel()
        replyTask = nil
        activeStream?.liveMessage.stop()
        activeStream = nil
    }

    private func toggleFeed() {
        if let feedTask {
            feedTask.cancel()
            self.feedTask = nil
            return
        }
        feedTask = Task {
            var count = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                count += 1
                messages.append(
                    MockChatMessage(
                        role: .agent,
                        text: """
                            ### Incoming feed #\(count)

                            A stable historical row arrived with **Markdown**, `inline code`,
                            and a [safe link](https://example.com). Scrolling up should preserve
                            your reading position; staying pinned should follow the new row.
                            """,
                        label: "Incoming feed"
                    )
                )
            }
            guard !Task.isCancelled else { return }
            feedTask = nil
        }
    }

    private func removeLastMessage() {
        guard let lastMessage = messages.last else { return }
        if activeStream?.messageID == lastMessage.id {
            replyTask?.cancel()
            replyTask = nil
            activeStream = nil
        }
        messages.removeLast()
    }

    private func reset(to conversation: [MockChatMessage]) {
        replyTask?.cancel()
        replyTask = nil
        activeStream = nil
        feedTask?.cancel()
        feedTask = nil
        loadingTask?.cancel()
        loadingTask = nil
        isLoading = false
        scrollState.reset()
        messages = conversation
        // Growth pins via scroll geometry; a reset can shrink the
        // content, which nothing else re-anchors.
        scrollState.requestScrollToBottom()
    }
}

/// Task-local stream progress. This is deliberately a reference type:
/// advancing a chunk must not invalidate `MockChatView` and rebuild its
/// 5,000-element timeline input.
private final class MockChatActiveStream {
    let id = UUID()
    let messageID: UUID
    let liveMessage: MockChatStreamingMessage
    let chunks: [String]
    let profile: MockChatStreamProfile
    var nextChunkIndex = 0

    init(
        messageID: UUID,
        liveMessage: MockChatStreamingMessage,
        chunks: [String],
        profile: MockChatStreamProfile
    ) {
        self.messageID = messageID
        self.liveMessage = liveMessage
        self.chunks = chunks
        self.profile = profile
    }
}

/// The only model that changes for each mock token. Views that display the
/// live row observe this reference directly; the enclosing message array
/// stays byte-for-byte stable throughout the stream.
@Observable
private final class MockChatStreamingMessage {
    private(set) var text = ""
    private(set) var isStreaming = true
    private(set) var updateCount = 0
    private(set) var label: String?
    let renderThrottle: Duration

    init(label: String?, renderThrottle: Duration) {
        self.label = label
        self.renderThrottle = renderThrottle
    }

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        text += chunk
        updateCount += 1
    }

    func replace(with text: String, label: String) {
        self.text = text
        self.label = label
        updateCount += 1
    }

    func finish() {
        isStreaming = false
    }

    func stop() {
        isStreaming = false
        label = (label.map { "\($0) · " } ?? "") + "stopped"
    }
}

private struct MockChatTimeline: View {
    private static let bottomID = "mock-chat-list-bottom"
    private static let textWarmupRequestCount = 256

    let messages: [MockChatMessage]
    let scrollState: ChatScrollState
    let showsMessageDiagnostics: Bool
    let showsRawMarkdown: Bool

    @State private var segmentCache = ChatMarkdownSegmentCache()

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var textLayoutStore = ChatTextLayoutStore()
    @State private var textWarmRowWidth: CGFloat = 0
    #if os(macOS)
        @State private var scrollPositionPreserver =
            ChatMacScrollPositionPreserver()
    #else
        @State private var bottomFollower = ChatListBottomFollower()
    #endif

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(messages) { message in
                    MockChatListRow(
                        message: message,
                        showsDiagnostics: showsMessageDiagnostics,
                        showsRawMarkdown: showsRawMarkdown,
                        segmentCache: segmentCache,
                        textLayoutStore: textLayoutStore
                    )
                }

                MockChatEndMarker()
                    .id(Self.bottomID)
                    .listRowInsets(.init())
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .background {
                #if os(macOS)
                    MacListTableViewIntrospector { tableView in
                        scrollPositionPreserver.configure(
                            isBottomFollowingEnabled: {
                                scrollState.shouldFollowBottom
                            },
                            noteUserScrollActivity: { isActive in
                                scrollState.noteUserScrollActivity(
                                    isActive: isActive
                                )
                            },
                            noteUserReachedEnd: {
                                scrollState.noteScrollReturnedToEnd()
                            },
                            noteKeyboardScrollIntent: { towardEnd in
                                if towardEnd {
                                    scrollState.noteScrollTowardEnd()
                                } else {
                                    scrollState.noteScrollAwayFromEnd()
                                }
                            }
                        )
                        scrollPositionPreserver.attach(to: tableView)
                    }
                    .allowsHitTesting(false)
                #else
                    ChatListCollectionViewIntrospector { collectionView in
                        bottomFollower.attach(to: collectionView)
                    }
                    .allowsHitTesting(false)
                #endif
            }
            .onGeometryChange(for: CGFloat.self) { geometry in
                ChatTimelineMetrics.rowWidth(in: geometry.size.width)
            } action: { width in
                textWarmRowWidth = width
                warmTextLayouts(rowWidth: width)
            }
            .onChange(of: messages.last?.id) { _, _ in
                warmTextLayouts(rowWidth: textWarmRowWidth)
            }
            .onChange(of: messages.last?.isStreaming) { _, _ in
                warmTextLayouts(rowWidth: textWarmRowWidth)
            }
            .onChange(of: dynamicTypeSize) { _, _ in
                textLayoutStore = ChatTextLayoutStore()
                warmTextLayouts(rowWidth: textWarmRowWidth)
            }
            .modifier(
                MockChatListScrollBehaviorModifier(
                    scrollState: scrollState,
                    proxy: proxy,
                    bottomID: Self.bottomID,
                    pinToBottom: { animated in
                        #if os(macOS)
                            return scrollPositionPreserver.pinToBottom()
                        #else
                            guard !animated else { return false }
                            return bottomFollower.pinToBottom()
                        #endif
                    }
                )
            )
            .task(id: "\(messages.count)-\(textWarmRowWidth)") {
                // A headless benchmark measures the production steady state:
                // every page is prepared off the main actor before display.
                guard ChatBenchmarkAutoRun.plan != nil,
                    messages.count >= 1_000, textWarmRowWidth > 0
                else { return }
                ChatBenchmarkAutoRun.noteTranscriptWarmStarted()
                await Self.warmEntireTranscript(
                    messages: messages,
                    rowWidth: textWarmRowWidth,
                    segmentCache: segmentCache,
                    textLayoutStore: textLayoutStore
                )
                guard !Task.isCancelled else { return }
                ChatBenchmarkAutoRun.noteTranscriptWarm()
            }
        }
    }

    /// Primes segmentation, render plans, and text layouts for every message,
    /// mirroring what production pagination does per page before insertion.
    private static func warmEntireTranscript(
        messages: [MockChatMessage],
        rowWidth: CGFloat,
        segmentCache: ChatMarkdownSegmentCache,
        textLayoutStore: ChatTextLayoutStore
    ) async {
        await segmentCache.prime(
            requests: messages.map {
                ChatMarkdownPrimeRequest(
                    messageID: $0.id.uuidString,
                    source: $0.displayedText
                )
            }
        )
        guard !Task.isCancelled else { return }

        var renderRequests: [(request: ChatMarkdownRenderRequest, width: CGFloat)] = []
        var layoutRequests: [ChatTextLayoutRequest] = []

        for message in messages {
            let messageID = message.id.uuidString
            let role = message.role == .user
                ? MaidMessageRole.user.rawValue
                : MaidMessageRole.assistant.rawValue
            // User bubbles inset their text; matching production's width rule
            // keeps every prepared layout an exact cache hit.
            let textWidth = ChatTimelineMetrics.proseTextWidth(
                role: role,
                in: rowWidth
            )
            let plan = ChatMessageTextPlanner.plan(
                messageID: messageID,
                role: role,
                messageTurnID: messageID,
                streamingTurnID: message.displayedIsStreaming ? messageID : nil,
                source: message.displayedText,
                segmentCache: segmentCache
            )
            switch plan {
            case .existingRenderer:
                renderRequests.append(
                    (
                        ChatMarkdownRenderRequest(
                            messageID: messageID,
                            source: message.displayedText
                        ),
                        textWidth
                    )
                )
            case .segmented(let segments):
                for (index, segment) in segments.enumerated() {
                    if segment.kind == .prose {
                        layoutRequests.append(
                            ChatTextLayoutRequest(
                                id: "mock-\(messageID)-\(index)-prose",
                                source: segment.source,
                                style: .markdownProse,
                                width: textWidth
                            )
                        )
                    } else {
                        renderRequests.append(
                            (
                                ChatMarkdownRenderRequest(
                                    messageID: "mock-\(messageID)-\(index)-rich",
                                    source: segment.source
                                ),
                                textWidth
                            )
                        )
                    }
                }
            }
        }
        await ChatMarkdownRenderCache.shared.prime(
            requests: renderRequests.map(\.request)
        )
        guard !Task.isCancelled else { return }

        // Rich plans resolve into per-block selectable prose layouts.
        for (request, width) in renderRequests {
            guard let plan = ChatMarkdownRenderCache.shared.cachedPlan(
                messageID: request.messageID,
                source: request.source
            ) else { continue }
            for (index, block) in plan.blocks.enumerated() {
                guard case .prose(let prose) = block else { continue }
                layoutRequests.append(
                    ChatTextLayoutRequest(
                        id: "\(request.messageID)-block-\(index)",
                        source: prose.source,
                        style: .markdownProse,
                        width: width
                    )
                )
            }
        }
        ChatBenchmarkAutoRun.trace(
            "warm widths row=\(rowWidth) layouts=\(layoutRequests.count)"
        )
        await textLayoutStore.prepare(requests: layoutRequests)
    }

    private func warmTextLayouts(rowWidth: CGFloat) {
        guard !showsRawMarkdown,
            messages.count >= 100, rowWidth > 0
        else { return }

        let requests = messages.suffix(
            Self.textWarmupRequestCount
        ).flatMap {
            message -> [ChatTextLayoutRequest] in
            let plan = textPlan(for: message)
            switch plan {
            case .existingRenderer:
                return []
            case .segmented(let segments):
                // User bubbles inset their text; matching production's width
                // rule keeps every prepared layout an exact cache hit.
                let textWidth = ChatTimelineMetrics.proseTextWidth(
                    role: message.role == .user
                        ? MaidMessageRole.user.rawValue
                        : MaidMessageRole.assistant.rawValue,
                    in: rowWidth
                )
                return segments.indices.compactMap { index in
                    guard segments[index].kind == .prose else { return nil }
                    return ChatTextLayoutRequest(
                        id: "mock-\(message.id.uuidString)-\(index)-prose",
                        source: segments[index].source,
                        style: .markdownProse,
                        width: textWidth
                    )
                }
            }
        }
        Task {
            await textLayoutStore.prepare(requests: requests)
        }
    }

    private func textPlan(for message: MockChatMessage) -> ChatMessageTextPlan {
        let turnID = message.id.uuidString
        return ChatMessageTextPlanner.plan(
            messageID: turnID,
            role: message.role == .user
                ? MaidMessageRole.user.rawValue
                : MaidMessageRole.assistant.rawValue,
            messageTurnID: turnID,
            streamingTurnID: message.displayedIsStreaming ? turnID : nil,
            source: message.displayedText,
            segmentCache: segmentCache
        )
    }

}

private struct MockChatListRow: View {
    let message: MockChatMessage
    let showsDiagnostics: Bool
    let showsRawMarkdown: Bool
    let segmentCache: ChatMarkdownSegmentCache
    let textLayoutStore: ChatTextLayoutStore

    var body: some View {
        Group {
            MockChatMessageRow(
                message: message,
                showsDiagnostics: showsDiagnostics,
                showsRawMarkdown: showsRawMarkdown,
                segmentCache: segmentCache,
                textLayoutStore: textLayoutStore
            )
        }
        // The production timeline caps its readable column; the lab must
        // measure the same geometry.
        .frame(maxWidth: ChatContentMetrics.maximumWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .listRowInsets(
            .init(
                top: 0,
                leading: ChatTimelineMetrics.rowHorizontalInset,
                bottom: 0,
                trailing: ChatTimelineMetrics.rowHorizontalInset
            )
        )
        .listRowSeparator(.hidden)
    }
}

private struct MockChatListScrollBehaviorModifier: ViewModifier {
    private static let scrollMovementTolerance: CGFloat = 0.5

    let scrollState: ChatScrollState
    let proxy: ScrollViewProxy
    let bottomID: String
    /// Constant-time direct-offset pin; returns false when the platform or
    /// unresolved backing view requires the proxy fallback.
    let pinToBottom: (_ animated: Bool) -> Bool

    func body(content: Content) -> some View {
        content
            .dismissesKeyboardInteractively()
            .modifier(
                ChatBottomScrollRequestModifier(
                    scrollState: scrollState,
                    proxy: proxy,
                    bottomID: bottomID,
                    pinToBottom: pinToBottom
                )
            )
            .onScrollGeometryChange(for: MockChatScrollGeometry.self) {
                    geometry in
                    MockChatScrollGeometry(
                        isNearBottom: geometry.contentSize.height
                            + geometry.contentInsets.bottom
                            - geometry.visibleRect.maxY
                            <= ChatTimelineMetrics.nearBottomDistance,
                        containerWidth: geometry.containerSize.width,
                        containerHeight: geometry.containerSize.height,
                        bottomInset: geometry.contentInsets.bottom,
                        contentHeight: geometry.contentSize.height,
                        contentOffsetY: geometry.contentOffset.y
                    )
                } action: { oldGeometry, newGeometry in
                    scrollState.noteEndVisibility(newGeometry.isNearBottom)
                    #if os(macOS)
                        if scrollState.shouldFollowBottom,
                            !newGeometry.isNearBottom,
                            !pinToBottom(false)
                        {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    #else
                        let viewportShrank =
                            newGeometry.bottomInset
                                > oldGeometry.bottomInset
                            || newGeometry.containerHeight
                                < oldGeometry.containerHeight
                        let contentGrew =
                            newGeometry.contentHeight
                                > oldGeometry.contentHeight
                        if !viewportShrank, !contentGrew,
                            newGeometry.contentOffsetY
                                < oldGeometry.contentOffsetY
                                    - Self.scrollMovementTolerance
                        {
                            scrollState.noteScrollAwayFromEnd()
                        }
                    #endif

                    #if !os(macOS)
                        let shouldPin = viewportShrank || contentGrew
                        if shouldPin, scrollState.shouldFollowBottom,
                            !pinToBottom(false)
                        {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    #endif
                }
            #if !os(macOS)
                .onScrollPhaseChange { _, newPhase in
                        let isUserDriven =
                            switch newPhase {
                            case .tracking, .interacting, .decelerating:
                                true
                            case .idle, .animating:
                                false
                            }

                        scrollState.noteUserScrollActivity(
                            isActive: isUserDriven
                        )
                }
            #endif
    }
}

private struct MockChatScrollGeometry: Equatable {
    let isNearBottom: Bool
    let containerWidth: CGFloat
    let containerHeight: CGFloat
    let bottomInset: CGFloat
    let contentHeight: CGFloat
    let contentOffsetY: CGFloat
}

private struct MockChatMessageRow: View {
    let message: MockChatMessage
    let showsDiagnostics: Bool
    let showsRawMarkdown: Bool
    let segmentCache: ChatMarkdownSegmentCache
    let textLayoutStore: ChatTextLayoutStore

    var body: some View {
        VStack {
            MockChatBubble(
                message: message,
                showsRawMarkdown: showsRawMarkdown,
                showsDiagnostics: showsDiagnostics,
                segmentCache: segmentCache,
                textLayoutStore: textLayoutStore
            )

            if let fileChangesFixture = message.fileChangesFixture {
                UnifiedDiffLauncherView(
                    changes: MockChatDiffFixtures.changes(for: fileChangesFixture)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if showsDiagnostics {
                MockChatMessageDiagnostics(
                    message: message,
                    renderingPath: renderingPath
                )
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: message.role == .user ? .trailing : .leading
        )
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            message.role == .user ? "User message" : "Assistant message"
        )
        #if DEBUG && os(iOS)
            .onAppear {
                ChatTextLayoutDiagnostics.rowAppeared(
                    id: message.id.uuidString,
                    role: message.role == .user ? "user" : "assistant",
                    path: renderingPath,
                    byteCount: message.displayedText.utf8.count
                )
            }
        #endif
    }

    private var renderingPath: String {
        if showsRawMarkdown { return "raw source" }

        let turnID = message.id.uuidString
        let plan = ChatMessageTextPlanner.plan(
            messageID: turnID,
            role: message.role == .user
                ? MaidMessageRole.user.rawValue
                : MaidMessageRole.assistant.rawValue,
            messageTurnID: turnID,
            streamingTurnID: message.displayedIsStreaming ? turnID : nil,
            source: message.displayedText,
            segmentCache: segmentCache
        )
        switch plan {
        case .existingRenderer:
            return "existing renderer"
        case .segmented(let segments):
            return segments.allSatisfy { $0.kind != .rich }
                ? "native prose"
                : "native mixed"
        }
    }
}

private struct MockChatMessageDiagnostics: View {
    let message: MockChatMessage
    let renderingPath: String

    var body: some View {
        HStack {
            Text(message.role == .user ? "user" : "assistant")

            if let label = message.displayedLabel {
                Text(label)
            }

            Text(renderingPath)

            Text("\(message.displayedText.count.formatted()) chars")

            if message.displayedUpdateCount > 0 {
                Text("\(message.displayedUpdateCount.formatted()) updates")
            }

            if message.displayedIsStreaming {
                Label("streaming", systemImage: "waveform")
            }
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
        .frame(
            maxWidth: .infinity,
            alignment: message.role == .user ? .trailing : .leading
        )
        .accessibilityElement(children: .combine)
    }
}

private struct MockChatEndMarker: View {
    var body: some View {
        Color.clear
            .frame(height: 24)
            .allowsHitTesting(false)
    }
}

private struct MockChatComposerSafeAreaBar: ViewModifier {
    @Binding var prompt: String
    let isRunning: Bool
    let send: () -> Void
    let stop: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
            if #available(macOS 26.0, *) {
                safeAreaBar(content)
            } else {
                safeAreaInset(content)
            }
        #else
            if #available(iOS 26.0, *) {
                safeAreaBar(content)
            } else {
                safeAreaInset(content)
            }
        #endif
    }

    @available(iOS 26.0, macOS 26.0, *)
    private func safeAreaBar(_ content: Content) -> some View {
        content.safeAreaBar(edge: .bottom, spacing: 0) {
            MockChatComposerBar(
                prompt: $prompt,
                isRunning: isRunning,
                send: send,
                stop: stop
            )
        }
    }

    private func safeAreaInset(_ content: Content) -> some View {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                MockChatComposerBar(
                    prompt: $prompt,
                    isRunning: isRunning,
                    send: send,
                    stop: stop
                )
            }
    }
}

private struct MockChatComposerBar: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Binding var prompt: String
    let isRunning: Bool
    let send: () -> Void
    let stop: () -> Void

    var body: some View {
        PromptComposer(
            text: $prompt,
            isEnabled: true,
            focusID: nil,
            canSend: !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            isSending: false,
            isRunning: isRunning,
            submitLabel: "Send",
            send: send,
            stop: stop,
            leadingControls: {
                ComposerAddMenu(
                    isImageAttachmentAvailable: true,
                    isImageAttachmentDisabled: false,
                    maximumImageSelectionCount: 8,
                    commands: [],
                    addImages: { _ in },
                    addPhotos: { _ in },
                    addCameraImage: { _ in },
                    insertCommand: { _ in },
                    showError: { _ in }
                )
            },
            trailingControls: {
                if !dynamicTypeSize.isAccessibilitySize {
                    Text("Sonnet 5 · High")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        )
    }
}

private struct MockChatScrollToBottomButton: View {
    let scrollState: ChatScrollState
    let scrollToBottom: () -> Void

    var body: some View {
        ZStack {
            if !scrollState.isNearBottom {
                Button {
                    scrollToBottom()
                } label: {
                    Label("Scroll to bottom", systemImage: "arrow.down")
                        .labelStyle(.iconOnly)
                        .font(.body.bold())
                        .frame(width: 24, height: 24)
                        .contentShape(.circle)
                }
                .buttonBorderShape(.circle)
                .modifier(MockChatScrollButtonStyle())
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy, value: scrollState.isNearBottom)
    }
}

private struct MockChatScrollButtonStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
            if #available(macOS 26.0, *) {
                content.buttonStyle(.glass)
            } else {
                fallback(content)
            }
        #else
            if #available(iOS 26.0, *) {
                content.buttonStyle(.glass)
            } else {
                fallback(content)
            }
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.regularMaterial, in: .circle)
            .buttonStyle(.plain)
    }
}

private struct MockChatBubble: View {
    let message: MockChatMessage
    let showsRawMarkdown: Bool
    let showsDiagnostics: Bool
    let segmentCache: ChatMarkdownSegmentCache
    let textLayoutStore: ChatTextLayoutStore

    var body: some View {
        Group {
            if message.displayedIsStreaming, message.displayedText.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Waiting for streamed Markdown")
            } else if showsRawMarkdown {
                Text(message.displayedText)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            } else {
                if textPlan == .existingRenderer {
                    MockChatExistingText(
                        message: message,
                        showsDiagnostics: showsDiagnostics,
                        textLayoutStore: textLayoutStore
                    )
                } else if case .segmented(let segments) = textPlan {
                    MockChatOptimizedText(
                        message: message,
                        segments: segments,
                        showsDiagnostics: showsDiagnostics,
                        textLayoutStore: textLayoutStore
                    )
                }
            }
        }
        .padding(
            .horizontal,
            message.role == .user
                ? ChatTimelineMetrics.userBubbleHorizontalPadding : 0
        )
        .padding(
            .vertical,
            message.role == .user
                ? ChatTimelineMetrics.userBubbleVerticalPadding : 0
        )
        .background(
            message.role == .user ? Color.accentColor.opacity(0.15) : Color.clear,
            in: .rect(cornerRadius: 18)
        )
        .frame(
            maxWidth: .infinity,
            alignment: message.role == .user ? .trailing : .leading
        )
    }

    private var textPlan: ChatMessageTextPlan {
        let turnID = message.id.uuidString
        return ChatMessageTextPlanner.plan(
            messageID: turnID,
            role: message.role == .user
                ? MaidMessageRole.user.rawValue
                : MaidMessageRole.assistant.rawValue,
            messageTurnID: turnID,
            streamingTurnID: message.displayedIsStreaming ? turnID : nil,
            source: message.displayedText,
            segmentCache: segmentCache
        )
    }

}

private struct MockChatExistingText: View {
    let message: MockChatMessage
    let showsDiagnostics: Bool
    let textLayoutStore: ChatTextLayoutStore

    var body: some View {
        ChatMarkdownMessageView(
            messageID: message.id.uuidString,
            source: message.displayedText,
            presentation: ChatMarkdownPresentation(
                isStreaming: message.displayedIsStreaming,
                showsDiagnostics: showsDiagnostics
            ),
            textLayoutStore: textLayoutStore
        )
    }
}

private struct MockChatOptimizedText: View {
    let message: MockChatMessage
    let segments: [ChatMarkdownSegment]
    let showsDiagnostics: Bool
    let textLayoutStore: ChatTextLayoutStore

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: ChatTimelineMetrics.interSegmentSpacing
        ) {
            ForEach(segments.indices, id: \.self) { index in
                let segment = segments[index]
                if segment.kind == .prose {
                    ChatSelectableText(
                        layoutID: "mock-\(message.id.uuidString)-\(index)-prose",
                        source: segment.source,
                        style: .markdownProse,
                        layoutStore: textLayoutStore
                    )
                } else {
                    ChatMarkdownMessageView(
                        messageID: "mock-\(message.id.uuidString)-\(index)-rich",
                        source: segment.source,
                        presentation: ChatMarkdownPresentation(
                            isStreaming: false,
                            showsDiagnostics: showsDiagnostics
                        ),
                        textLayoutStore: textLayoutStore
                    )
                }
            }
        }
    }
}

struct MockChatMessage: Identifiable, Equatable {
    enum FileChangesFixture: Equatable {
        case representative
        case superLarge
    }

    enum Role: Equatable {
        case user
        case agent
    }

    let id: UUID
    let role: Role
    var text: String
    var isStreaming: Bool
    var updateCount: Int
    var label: String?
    let fileChangesFixture: FileChangesFixture?
    let renderThrottle: Duration
    fileprivate let liveMessage: MockChatStreamingMessage?

    fileprivate init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        isStreaming: Bool = false,
        updateCount: Int = 0,
        label: String? = nil,
        fileChangesFixture: FileChangesFixture? = nil,
        renderThrottle: Duration = .milliseconds(50),
        liveMessage: MockChatStreamingMessage? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
        self.updateCount = updateCount
        self.label = label
        self.fileChangesFixture = fileChangesFixture
        self.renderThrottle = renderThrottle
        self.liveMessage = liveMessage
    }

    var displayedText: String {
        liveMessage?.text ?? text
    }

    var displayedIsStreaming: Bool {
        liveMessage?.isStreaming ?? isStreaming
    }

    var displayedUpdateCount: Int {
        liveMessage?.updateCount ?? updateCount
    }

    var displayedLabel: String? {
        liveMessage?.label ?? label
    }

    var displayedRenderThrottle: Duration {
        liveMessage?.renderThrottle ?? renderThrottle
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.role == rhs.role
            && lhs.text == rhs.text
            && lhs.isStreaming == rhs.isStreaming
            && lhs.updateCount == rhs.updateCount
            && lhs.label == rhs.label
            && lhs.fileChangesFixture == rhs.fileChangesFixture
            && lhs.renderThrottle == rhs.renderThrottle
            && lhs.liveMessage === rhs.liveMessage
    }

    static let shortConversation: [MockChatMessage] = [
        MockChatMessage(
            role: .user,
            text: "Can you summarize the daemon's **RPC layer**?"
        ),
        MockChatMessage(
            role: .agent,
            text: """
                The daemon exposes a `JSON-RPC` surface that the Swift client talks to
                over a local socket.

                - Threads carry the durable conversation.
                - Turns track one provider response.
                - Events update the timeline incrementally.
                """,
            label: "Representative prose"
        ),
    ]

    static let richBlocksConversation: [MockChatMessage] = [
        MockChatMessage(
            role: .user,
            text: "Render the same focused code, table, and HTML fixture."
        ),
        MockChatMessage(
            role: .agent,
            text: MockChatMarkdownFixtures.richBlocks,
            label: "Rich blocks comparison"
        ),
    ]

    static let componentConversation: [MockChatMessage] = [
        MockChatMessage(
            role: .user,
            text: "Render a catalog containing every supported Markdown component."
        ),
        MockChatMessage(
            role: .agent,
            text: MockChatMarkdownFixtures.componentCatalog,
            label: "All components"
        ),
    ]

    static let malformedConversation: [MockChatMessage] =
        [
            MockChatMessage(
                role: .user,
                text: "Show best-effort output for malformed and partial Markdown."
            )
        ]
        + MockChatMarkdownFixtures.malformedSamples.map { sample in
            MockChatMessage(
                role: .agent,
                text: sample.markdown,
                label: sample.label
            )
        }

    static let unsupportedConversation: [MockChatMessage] =
        [
            MockChatMessage(
                role: .user,
                text: "Exercise safe fallbacks for intentionally unsupported content."
            )
        ]
        + MockChatMarkdownFixtures.unsupportedSamples.map { sample in
            MockChatMessage(
                role: .agent,
                text: sample.markdown,
                label: sample.label
            )
        }

    static let codeHeavyConversation: [MockChatMessage] = [
        MockChatMessage(
            role: .user,
            text: "Exercise long code blocks, languages, copying, and horizontal scrolling."
        ),
        MockChatMessage(
            role: .agent,
            text: MockChatMarkdownFixtures.codeHeavy,
            label: "Code-heavy"
        ),
    ]

    static let fileChangesConversation: [MockChatMessage] = [
        MockChatMessage(
            role: .user,
            text: "Update the profile UI and supporting files."
        ),
        MockChatMessage(
            role: .agent,
            text:
                "I changed six files. Open the file changes below to exercise the diff viewer.",
            label: "Provider-neutral file changes",
            fileChangesFixture: .representative
        ),
    ]

    static let largeFileChangesConversation: [MockChatMessage] = [
        MockChatMessage(
            role: .user,
            text: "Show a very large set of file changes so I can stress-test scrolling."
        ),
        MockChatMessage(
            role: .agent,
            text: """
                This fixture contains 24 files and about 22,000 diff rows.
                Open it and test vertical and horizontal scrolling manually.
                """,
            label: "Super-large file changes",
            fileChangesFixture: .superLarge
        ),
    ]

    static let swiftHighlightingConversation: [MockChatMessage] = [
        MockChatMessage(
            role: .agent,
            text: MockChatMarkdownFixtures.swiftHighlighting,
            label: "Swift highlighting"
        )
    ]

    static let longMarkdownConversation: [MockChatMessage] = [
        MockChatMessage(role: .user, text: "Render one realistically long assistant response."),
        MockChatMessage(
            role: .agent,
            text: MockChatMarkdownFixtures.longMarkdown,
            label: "Long Markdown"
        ),
    ]

    static let longConversation: [MockChatMessage] =
        shortConversation
        + (1...12).map { index in
            MockChatMessage(
                role: index.isMultiple(of: 3) ? .user : .agent,
                text: """
                    ### Timeline update \(index)

                    The store applies event `\(index)` in place so stable rows keep their
                    identity. This message includes **emphasis**, a [link](https://example.com),
                    and enough prose to exercise transcript scrolling.
                    """,
                label: "Stable row \(index)"
            )
        }

    static let stressConversation: [MockChatMessage] =
        (1...100).map { index in
            MockChatMessage(
                role: index.isMultiple(of: 5) ? .user : .agent,
                text: """
                    **Stable message \(index)** — row identity should not change when a later
                    assistant response streams. Includes `inline-\(index)` and
                    [a safe link](https://example.com/messages/\(index)).
                    """,
                label: "Stress row \(index)"
            )
        }

    /// Creates the data once when the sandbox action runs. The height
    /// pattern is deterministic and deliberately uneven so List exercises
    /// platform virtualization across substantially different row sizes.
    static func variableHeightStressConversation(count: Int) -> [MockChatMessage] {
        let messageCount = max(0, count)
        let paragraphCounts = [1, 2, 4, 8, 3, 12, 5, 16, 6, 10]

        return (0..<messageCount).map { offset in
            let index = offset + 1
            let paragraphCount = paragraphCounts[offset % paragraphCounts.count]
            var sections = [
                "**Variable-height message \(index)** — \(paragraphCount) paragraph workload."
            ]
            sections.reserveCapacity(paragraphCount + 2)

            for paragraphIndex in 1...paragraphCount {
                sections.append(
                    "Paragraph \(paragraphIndex) for row \(index) has deterministic wrapping "
                        + "content, `inline-code-\(index)-\(paragraphIndex)`, and enough words "
                        + "to produce a useful range of measured row heights at compact and "
                        + "regular widths."
                )
            }

            if index.isMultiple(of: 11) {
                sections.append(
                    "- Stable identity: `\(index)`\n"
                        + "- Paragraphs: `\(paragraphCount)`\n"
                        + "- Renderer: List"
                )
            }

            if index.isMultiple(of: 29) {
                sections.append(
                    "```swift\n"
                        + "struct StressRow\(index) {\n"
                        + "    let index = \(index)\n"
                        + "    let paragraphCount = \(paragraphCount)\n"
                        + "}\n"
                        + "```"
                )
            }

            return MockChatMessage(
                role: index.isMultiple(of: 7) ? .user : .agent,
                text: sections.joined(separator: "\n\n"),
                label: "Variable row \(index) · \(paragraphCount) paragraphs"
            )
        }
    }

    /// A transcript shaped like real "write me an essay" threads: a
    /// handful of enormous single messages rather than many small rows.
    /// List virtualizes per row, so each essay is laid out in full the
    /// moment its row enters the viewport — the hitch profile this
    /// fixture exists to reproduce. Compare with the raw-markdown toggle
    /// on and off.
    static let giantEssayConversation: [MockChatMessage] =
        [3_000, 5_000, 10_000].flatMap { wordCount in
            [
                MockChatMessage(
                    role: .user,
                    text: "Write a \(wordCount.formatted())-word essay in one message."
                ),
                MockChatMessage(
                    role: .agent,
                    text: essay(wordCount: wordCount),
                    label: "\(wordCount.formatted())-word essay"
                ),
            ]
        }

    /// The same expensive rows without intervening user messages. This
    /// isolates native text-view realization from role-boundary effects.
    static let giantEssayAssistantOnlyConversation: [MockChatMessage] =
        [3_000, 5_000, 10_000].map { wordCount in
            MockChatMessage(
                role: .agent,
                text: essay(wordCount: wordCount),
                label: "assistant-only · \(wordCount.formatted()) words"
            )
        }

    /// Deterministic long-form prose: one string of sectioned paragraphs
    /// totaling roughly `wordCount` words, with no randomness so runs are
    /// comparable.
    static func essay(wordCount: Int) -> String {
        let vocabulary: [String] = [
            "timeline", "renderer", "layout", "scrolling", "message",
            "row", "virtualization", "streaming", "throughput", "latency",
            "profile", "measurement", "viewport", "buffer", "cadence",
            "identity", "invalidation", "diffing", "anchor", "composer",
            "transcript", "gesture", "frame", "budget",
        ]

        var paragraphs: [String] = []
        var wordsEmitted = 0
        var wordIndex = 0
        var paragraphIndex = 0

        while wordsEmitted < wordCount {
            paragraphIndex += 1
            if paragraphIndex % 6 == 1 {
                paragraphs.append("## Section \(1 + paragraphIndex / 6)")
            }

            var sentences: [String] = []
            for sentenceIndex in 0..<5 {
                let length = 9 + (paragraphIndex + sentenceIndex) % 7
                var words: [String] = []
                words.reserveCapacity(length)
                for _ in 0..<length {
                    words.append(vocabulary[wordIndex % vocabulary.count])
                    wordIndex += 1
                }
                words[0] = words[0].capitalized
                sentences.append(words.joined(separator: " ") + ".")
                wordsEmitted += length
            }
            paragraphs.append(sentences.joined(separator: " "))
        }

        return paragraphs.joined(separator: "\n\n")
    }
}

private enum MockChatDiffFixtures {
    static func changes(
        for fixture: MockChatMessage.FileChangesFixture
    ) -> [FileChange] {
        switch fixture {
        case .representative:
            representativeChanges
        case .superLarge:
            largeChanges
        }
    }

    private static let representativeChanges: [FileChange] = [
        FileChange(
            diff: """
                @@ -4,6 +4,7 @@ struct ProfileView: View {
                     let user: User
                -    let showsStatus = false
                +    let showsStatus: Bool
                +    let onEdit: () -> Void
                \u{20}
                     var body: some View {
                -        Text(user.name)
                +        ProfileHeader(user: user, showsStatus: showsStatus, onEdit: onEdit)
                     }
                @@ -22,2 +24,4 @@ struct ProfileView: View {
                     }
                 }
                +
                +private let previewDescription = "This intentionally long changed line lets you verify that the diff scrolls horizontally instead of wrapping."
                """,
            kind: MaidFileChangeKind.update.rawValue,
            movePath: nil,
            newText: nil,
            oldText: nil,
            path: "Sources/Features/Profile/ProfileView.swift"
        ),
        FileChange(
            diff: nil,
            kind: MaidFileChangeKind.update.rawValue,
            movePath: nil,
            newText: """
                struct UserPreferences: Codable {
                    var appearance = "system"
                    var showsActivity = true
                    var compactMode = false
                }
                """,
            oldText: """
                struct UserPreferences: Codable {
                    var appearance = "system"
                    var showsActivity = false
                }
                """,
            path: "Sources/Models/UserPreferences.swift"
        ),
        FileChange(
            diff: nil,
            kind: MaidFileChangeKind.add.rawValue,
            movePath: nil,
            newText: """
                import SwiftUI

                struct ProfileEmptyState: View {
                    var body: some View {
                        ContentUnavailableView("No profile", systemImage: "person.crop.circle")
                    }
                }
                """,
            oldText: nil,
            path: "Sources/Features/Profile/ProfileEmptyState.swift"
        ),
        FileChange(
            diff: nil,
            kind: MaidFileChangeKind.delete.rawValue,
            movePath: nil,
            newText: nil,
            oldText: """
                struct LegacyProfileBadge {
                    let title: String
                }
                """,
            path: "Sources/Features/Profile/LegacyProfileBadge.swift"
        ),
        FileChange(
            diff: nil,
            kind: MaidFileChangeKind.move.rawValue,
            movePath: "Sources/Features/Profile/ProfileHeader.swift",
            newText: """
                struct ProfileHeader {
                    let displayName: String
                }
                """,
            oldText: """
                struct UserHeader {
                    let displayName: String
                }
                """,
            path: "Sources/Features/Profile/UserHeader.swift"
        ),
        FileChange(
            diff:
                "Binary files a/Assets/profile-placeholder.png and b/Assets/profile-placeholder.png differ",
            kind: MaidFileChangeKind.update.rawValue,
            movePath: nil,
            newText: nil,
            oldText: nil,
            path: "Assets/profile-placeholder.png"
        ),
    ]

    private static let largeChanges: [FileChange] = (0..<24).map { fileIndex in
        var patchLines: [String] = []
        patchLines.reserveCapacity(18 * 51)
        var oldStart = 1
        var newStart = 1

        for hunkIndex in 0..<18 {
            var body: [String] = []
            body.reserveCapacity(50)
            var oldCount = 0
            var newCount = 0

            for lineIndex in 0..<50 {
                switch lineIndex % 3 {
                case 0:
                    let wideSuffix =
                        lineIndex == 0
                        ? String(repeating: " wide-content", count: 18)
                        : ""
                    body.append(
                        " context \(fileIndex)-\(hunkIndex)-\(lineIndex)"
                            + wideSuffix
                    )
                    oldCount += 1
                    newCount += 1
                case 1:
                    body.append("-deleted \(fileIndex)-\(hunkIndex)-\(lineIndex)")
                    oldCount += 1
                default:
                    body.append("+added \(fileIndex)-\(hunkIndex)-\(lineIndex)")
                    newCount += 1
                }
            }

            patchLines.append(
                "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) "
                    + "@@ synthetic hunk \(hunkIndex)"
            )
            patchLines.append(contentsOf: body)
            oldStart += oldCount + 3
            newStart += newCount + 3
        }

        return FileChange(
            diff: patchLines.joined(separator: "\n"),
            kind: MaidFileChangeKind.update.rawValue,
            movePath: nil,
            newText: nil,
            oldText: nil,
            path: "Sources/Synthetic/LargeFile\(fileIndex).swift"
        )
    }
}

#Preview("Mock Chat") {
    NavigationStack {
        MockChatView()
    }
}

#Preview("Mock Chat – Long") {
    NavigationStack {
        MockChatView(initialMessages: MockChatMessage.longConversation)
    }
}

#Preview("Markdown Rich Blocks – Dark") {
    NavigationStack {
        MockChatView(initialMessages: MockChatMessage.richBlocksConversation)
    }
    .preferredColorScheme(.dark)
}

#Preview("Markdown Components – Dark") {
    NavigationStack {
        MockChatView(initialMessages: MockChatMessage.componentConversation)
    }
    .preferredColorScheme(.dark)
}

#Preview("Markdown Components – Accessibility") {
    NavigationStack {
        MockChatView(
            initialMessages: MockChatMessage.componentConversation,
            showsMessageDiagnostics: false
        )
    }
    .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Markdown Code-heavy") {
    NavigationStack {
        MockChatView(initialMessages: MockChatMessage.codeHeavyConversation)
    }
}

#Preview("Mock Chat – File Changes") {
    NavigationStack {
        MockChatView(
            initialMessages: MockChatMessage.fileChangesConversation,
            showsMessageDiagnostics: false
        )
    }
}

#Preview("Mock Chat – Super-large Diff") {
    NavigationStack {
        MockChatView(
            initialMessages: MockChatMessage.largeFileChangesConversation,
            showsMessageDiagnostics: false
        )
    }
}

#Preview("Super-large Diff Viewer") {
    NavigationStack {
        UnifiedDiffView(
            changes: MockChatDiffFixtures.changes(for: .superLarge)
        )
    }
}

#Preview("Markdown Swift Highlighting") {
    NavigationStack {
        MockChatView(
            initialMessages: MockChatMessage.swiftHighlightingConversation
        )
    }
}
