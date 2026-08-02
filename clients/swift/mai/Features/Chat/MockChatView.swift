#if DEBUG
    import Observation
    import SwiftUI

    private enum MockChatStressTranscriptSize: Int, CaseIterable, Hashable, Identifiable {
        case oneThousand = 1_000
        case fiveThousand = 5_000
        case tenThousand = 10_000

        var id: Self { self }

        var label: String {
            "\(rawValue.formatted()) rows"
        }
    }

    /// Debug-only screen for exercising the composer against a scrollable
    /// message timeline before the real chat timeline exists.
    struct MockChatView: View {
        @State private var messages: [MockChatMessage]
        @State private var prompt = ""
        @State private var replyTask: Task<Void, Never>?
        @State private var feedTask: Task<Void, Never>?
        @State private var loadingTask: Task<Void, Never>?
        @State private var activeStream: MockChatActiveStream?
        @State private var scrollState = MockChatScrollState()
        @State private var isLoading = false
        @State private var stressTranscriptSize = MockChatStressTranscriptSize.fiveThousand
        @State private var streamProfile = MockChatStreamProfile.readableTokens
        @State private var showsMessageDiagnostics = true
        @State private var showsRawMarkdown = false

        init(
            initialMessages: [MockChatMessage] = MockChatMessage.shortConversation,
            showsMessageDiagnostics: Bool = true
        ) {
            _messages = State(initialValue: initialMessages)
            _showsMessageDiagnostics = State(initialValue: showsMessageDiagnostics)
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
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
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

                Menu("Sandbox", systemImage: "wrench.and.screwdriver") {
                    Toggle("Show Message Diagnostics", isOn: $showsMessageDiagnostics)
                    Toggle("Show Raw Markdown", isOn: $showsRawMarkdown)

                    Divider()

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
            .onDisappear {
                stopReply()
                feedTask?.cancel()
                feedTask = nil
                loadingTask?.cancel()
                loadingTask = nil
                isLoading = false
            }
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
            loadingTask = Task { @MainActor in
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

            let reply = MockChatMessage(
                role: .agent,
                text: "",
                isStreaming: true,
                label: label,
                renderThrottle: streamProfile.renderThrottle
            )
            messages.append(reply)
            activeStream = MockChatActiveStream(
                messageID: reply.id,
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

            replyTask = Task { @MainActor in
                while let currentStream = activeStream,
                    currentStream.id == streamID,
                    currentStream.nextChunkIndex < currentStream.chunks.count
                {
                    let chunk = currentStream.chunks[currentStream.nextChunkIndex]
                    do {
                        try await Task.sleep(for: currentStream.profile.delay)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled,
                        var refreshedStream = activeStream,
                        refreshedStream.id == streamID,
                        let messageIndex = messages.lastIndex(
                            where: { $0.id == refreshedStream.messageID }
                        )
                    else { return }

                    messages[messageIndex].text += chunk
                    messages[messageIndex].updateCount += 1
                    refreshedStream.nextChunkIndex += 1
                    activeStream = refreshedStream
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
            guard let stream = activeStream,
                let messageIndex = messages.lastIndex(where: { $0.id == stream.messageID })
            else { return }

            pauseStream()

            let replacementPrefix = """
                # Source replaced while streaming

                This is a non-prefix edit. The streaming parser should discard its
                incremental assumption, perform a safe full parse, and then continue.

                """
            messages[messageIndex].text = replacementPrefix
            messages[messageIndex].updateCount += 1
            messages[messageIndex].label = "Replacement then append"
            activeStream = MockChatActiveStream(
                messageID: stream.messageID,
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
            if let messageIndex = messages.lastIndex(where: { $0.id == stream.messageID }) {
                messages[messageIndex].isStreaming = false
            }
            activeStream = nil
            replyTask = nil
        }

        private func stopReply() {
            replyTask?.cancel()
            replyTask = nil
            if let messageID = activeStream?.messageID,
                let messageIndex = messages.lastIndex(where: { $0.id == messageID })
            {
                messages[messageIndex].isStreaming = false
                messages[messageIndex].label =
                    (messages[messageIndex].label.map { "\($0) · " } ?? "") + "stopped"
            }
            activeStream = nil
        }

        private func toggleFeed() {
            if let feedTask {
                feedTask.cancel()
                self.feedTask = nil
                return
            }
            feedTask = Task { @MainActor in
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

    private struct MockChatActiveStream {
        let id = UUID()
        let messageID: UUID
        let chunks: [String]
        let profile: MockChatStreamProfile
        var nextChunkIndex = 0
    }

    /// Scroll state shared between the timeline and the composer overlay.
    /// It records the user's pinned intent separately from transient layout
    /// changes so keyboard movement cannot disable bottom following.
    @Observable
    final class MockChatScrollState {
        /// Scroll requests are state rather than a stored closure: the
        /// timeline's onChange runs them inside the update that follows the
        /// content change, and no captured ScrollViewProxy can go stale when
        /// the timeline is recreated.
        struct BottomScrollRequest: Equatable {
            var count = 0
            var animated = false
        }

        var isNearBottom = true
        private(set) var shouldFollowBottom = true
        private var isEndZoneVisible = true
        private var isUserScrolling = false
        private(set) var bottomScrollRequest = BottomScrollRequest()

        func requestScrollToBottom(animated: Bool = false) {
            shouldFollowBottom = true
            bottomScrollRequest = BottomScrollRequest(
                count: bottomScrollRequest.count + 1,
                animated: animated
            )
        }

        func noteEndVisibility(_ isVisible: Bool) {
            isEndZoneVisible = isVisible

            if isUserScrolling {
                // Keep the button tied to the actual end-zone visibility while
                // scrolling, so it neither appears on touch-down nor waits for
                // deceleration to finish before disappearing.
                isNearBottom = isVisible
            } else if isVisible {
                // Keyboard and safe-area changes can briefly hide the end zone.
                // Only restore pinned intent here; a layout change must not
                // cancel it when the zone temporarily disappears.
                isNearBottom = true
                shouldFollowBottom = true
            }
        }

        func noteUserScrollActivity(isActive: Bool) {
            isUserScrolling = isActive
            if isActive {
                // Stop token updates from fighting the drag immediately, while
                // leaving button visibility to the buffered end zone.
                shouldFollowBottom = false
            } else if isEndZoneVisible {
                isNearBottom = true
                shouldFollowBottom = true
            }
        }

        func reset() {
            isNearBottom = true
            shouldFollowBottom = true
            isEndZoneVisible = true
            isUserScrolling = false
        }
    }

    private struct MockChatTimeline: View {
        private static let bottomID = "mock-chat-list-bottom"

        let messages: [MockChatMessage]
        let scrollState: MockChatScrollState
        let showsMessageDiagnostics: Bool
        let showsRawMarkdown: Bool

        @State private var chunkCache = ChatMarkdownChunkCache()

        #if os(iOS)
            @State private var proseWarmWidth: CGFloat = 0
        #endif

        var body: some View {
            let rows = timelineRows()

            ScrollViewReader { proxy in
                List {
                    ForEach(rows) { row in
                        switch row {
                        case .message(let message):
                            MockChatListRow(
                                message: message,
                                showsDiagnostics: showsMessageDiagnostics,
                                showsRawMarkdown: showsRawMarkdown
                            )
                        case .messageChunk(let chunk):
                            MockChatChunkRow(
                                chunk: chunk,
                                showsDiagnostics: showsMessageDiagnostics,
                                showsRawMarkdown: showsRawMarkdown
                            )
                        case .messageProse(let chunk):
                            #if os(iOS)
                                MockChatProseRow(
                                    chunk: chunk,
                                    showsDiagnostics: showsMessageDiagnostics
                                )
                            #else
                                EmptyView()
                            #endif
                        }
                    }

                    MockChatEndMarker()
                        .id(Self.bottomID)
                        .listRowInsets(.init())
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 0)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                #if os(iOS)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.width - 32
                    } action: { width in
                        proseWarmWidth = width
                        warmProseLayouts(width: width)
                    }
                    .onChange(of: messages.count) { _, _ in
                        warmProseLayouts(width: proseWarmWidth)
                    }
                #endif
                .modifier(
                    MockChatListScrollBehaviorModifier(
                        scrollState: scrollState,
                        proxy: proxy,
                        bottomID: Self.bottomID
                    )
                )
            }
        }

        #if os(iOS)
            private func warmProseLayouts(width: CGFloat) {
                guard width > 0 else { return }
                var sources: [String] = []
                for message in messages {
                    guard message.role == .agent,
                        !message.isStreaming,
                        message.fileChangesFixture == nil,
                        ChatMarkdownChunker.isOversized(message.text),
                        let segments = chunkCache.segments(
                            messageID: message.id.uuidString,
                            source: message.text
                        )
                    else { continue }
                    sources.append(
                        contentsOf: segments.filter { $0.kind == .prose }.map(\.source)
                    )
                }
                ChatProseLayoutStore.shared.warm(sources: sources, width: width)
            }
        #endif

        /// Mirrors ChatTimeline: oversized settled agent messages expand into
        /// segment rows (iOS: pre-laid-out prose plus MarkdownView rich
        /// blocks) or size-based chunk rows, so the giant-essay fixtures
        /// exercise the same per-row costs as the real timeline.
        private func timelineRows() -> [MockChatRowModel] {
            messages.flatMap { message -> [MockChatRowModel] in
                guard message.role == .agent,
                    !message.isStreaming,
                    message.fileChangesFixture == nil,
                    ChatMarkdownChunker.isOversized(message.text)
                else {
                    return [.message(message)]
                }

                #if os(iOS)
                    if !showsRawMarkdown,
                        let segments = chunkCache.segments(
                            messageID: message.id.uuidString,
                            source: message.text
                        )
                    {
                        return segments.indices.map { index in
                            let chunk = MockChatMessageChunk(
                                message: message,
                                index: index,
                                text: segments[index].source,
                                isFirst: index == 0,
                                isLast: index == segments.count - 1
                            )
                            return segments[index].kind == .prose
                                ? .messageProse(chunk)
                                : .messageChunk(chunk)
                        }
                    }
                #endif

                let chunks = chunkCache.chunks(
                    messageID: message.id.uuidString,
                    source: message.text
                )
                guard chunks.count > 1 else { return [.message(message)] }
                return chunks.indices.map { index in
                    .messageChunk(
                        MockChatMessageChunk(
                            message: message,
                            index: index,
                            text: chunks[index],
                            isFirst: index == 0,
                            isLast: index == chunks.count - 1
                        )
                    )
                }
            }
        }
    }

    private enum MockChatRowModel: Identifiable {
        case message(MockChatMessage)
        case messageChunk(MockChatMessageChunk)
        case messageProse(MockChatMessageChunk)

        var id: String {
            switch self {
            case .message(let message):
                message.id.uuidString
            case .messageChunk(let chunk), .messageProse(let chunk):
                "\(chunk.message.id.uuidString)#chunk-\(chunk.index)"
            }
        }
    }

    private struct MockChatMessageChunk {
        let message: MockChatMessage
        let index: Int
        let text: String
        let isFirst: Bool
        let isLast: Bool
    }

    #if os(iOS)
        private struct MockChatProseRow: View {
            let chunk: MockChatMessageChunk
            let showsDiagnostics: Bool

            var body: some View {
                VStack {
                    ChatProseMessageText(source: chunk.text)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if chunk.isLast, showsDiagnostics {
                        MockChatMessageDiagnostics(message: chunk.message)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, chunk.isFirst ? 10 : 0)
                .padding(.bottom, chunk.isLast ? 10 : 8)
                .listRowInsets(
                    .init(top: 0, leading: 16, bottom: 0, trailing: 16)
                )
                .listRowSeparator(.hidden)
            }
        }
    #endif

    private struct MockChatChunkRow: View {
        let chunk: MockChatMessageChunk
        let showsDiagnostics: Bool
        let showsRawMarkdown: Bool

        var body: some View {
            VStack {
                if showsRawMarkdown {
                    Text(chunk.text)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ChatMarkdownMessageView(
                        messageID: "\(chunk.message.id.uuidString)#chunk-\(chunk.index)",
                        source: chunk.text,
                        presentation: ChatMarkdownPresentation(
                            isStreaming: false,
                            showsDiagnostics: showsDiagnostics
                        )
                    )
                }

                if chunk.isLast, showsDiagnostics {
                    MockChatMessageDiagnostics(message: chunk.message)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, chunk.isFirst ? 10 : 0)
            .padding(.bottom, chunk.isLast ? 10 : 8)
            .listRowInsets(
                .init(top: 0, leading: 16, bottom: 0, trailing: 16)
            )
            .listRowSeparator(.hidden)
        }
    }

    private struct MockChatListRow: View {
        let message: MockChatMessage
        let showsDiagnostics: Bool
        let showsRawMarkdown: Bool

        var body: some View {
            MockChatMessageRow(
                message: message,
                showsDiagnostics: showsDiagnostics,
                showsRawMarkdown: showsRawMarkdown
            )
            .listRowInsets(
                .init(top: 0, leading: 16, bottom: 0, trailing: 16)
            )
            .listRowSeparator(.hidden)
        }
    }

    private struct MockChatListScrollBehaviorModifier: ViewModifier {
        private static let nearBottomDistance: CGFloat = 24

        let scrollState: MockChatScrollState
        let proxy: ScrollViewProxy
        let bottomID: String

        func body(content: Content) -> some View {
            content
                .scrollDismissesKeyboard(.interactively)
                .modifier(
                    MockChatBottomScrollRequestModifier(
                        scrollState: scrollState,
                        proxy: proxy,
                        bottomID: bottomID
                    )
                )
                .onScrollGeometryChange(for: MockChatScrollGeometry.self) { geometry in
                    MockChatScrollGeometry(
                        isNearBottom: geometry.contentSize.height
                            + geometry.contentInsets.bottom
                            - geometry.visibleRect.maxY <= Self.nearBottomDistance,
                        containerHeight: geometry.containerSize.height,
                        bottomInset: geometry.contentInsets.bottom,
                        contentHeight: geometry.contentSize.height
                    )
                } action: { oldGeometry, newGeometry in
                    scrollState.noteEndVisibility(newGeometry.isNearBottom)
                    // Keyboard and composer growth land as inset/container
                    // changes; keep the bottom pinned through them. Content
                    // growth pins here too because it fires after layout.
                    let viewportShrank =
                        newGeometry.bottomInset > oldGeometry.bottomInset
                        || newGeometry.containerHeight < oldGeometry.containerHeight
                    let contentGrew = newGeometry.contentHeight > oldGeometry.contentHeight
                    if viewportShrank || contentGrew, scrollState.shouldFollowBottom {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
                .onScrollPhaseChange { _, newPhase in
                    let isUserDriven =
                        switch newPhase {
                        case .tracking, .interacting, .decelerating:
                            true
                        case .idle, .animating:
                            false
                        }

                    scrollState.noteUserScrollActivity(isActive: isUserDriven)
                }
        }
    }

    /// Owns the `bottomScrollRequest` read so scroll-to-bottom requests
    /// re-evaluate only this modifier, not the whole timeline container body.
    private struct MockChatBottomScrollRequestModifier: ViewModifier {
        let scrollState: MockChatScrollState
        let proxy: ScrollViewProxy
        let bottomID: String

        func body(content: Content) -> some View {
            content
                .onChange(of: scrollState.bottomScrollRequest) { _, request in
                    if request.animated {
                        withAnimation(.smooth) {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    } else {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
        }
    }

    private struct MockChatScrollGeometry: Equatable {
        let isNearBottom: Bool
        let containerHeight: CGFloat
        let bottomInset: CGFloat
        let contentHeight: CGFloat
    }

    private struct MockChatMessageRow: View {
        let message: MockChatMessage
        let showsDiagnostics: Bool
        let showsRawMarkdown: Bool

        var body: some View {
            VStack {
                MockChatBubble(
                    message: message,
                    showsRawMarkdown: showsRawMarkdown,
                    showsDiagnostics: showsDiagnostics
                )

                if let fileChangesFixture = message.fileChangesFixture {
                    UnifiedDiffLauncherView(
                        changes: MockChatDiffFixtures.changes(for: fileChangesFixture)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if showsDiagnostics {
                    MockChatMessageDiagnostics(message: message)
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
        }
    }

    private struct MockChatMessageDiagnostics: View {
        let message: MockChatMessage

        var body: some View {
            HStack {
                Text(message.role == .user ? "user" : "assistant")

                if let label = message.label {
                    Text(label)
                }

                Text("\(message.text.count.formatted()) chars")

                if message.updateCount > 0 {
                    Text("\(message.updateCount.formatted()) updates")
                }

                if message.isStreaming {
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
            if #available(iOS 26.0, macOS 26.0, *) {
                content.safeAreaBar(edge: .bottom, spacing: 0) {
                    MockChatComposerBar(
                        prompt: $prompt,
                        isRunning: isRunning,
                        send: send,
                        stop: stop
                    )
                }
            } else {
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
        let scrollState: MockChatScrollState
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
            if #available(iOS 26.0, macOS 26.0, *) {
                content
                    .buttonStyle(.glass)
            } else {
                content
                    .background(.regularMaterial, in: .circle)
                    .buttonStyle(.plain)
            }
        }
    }

    private struct MockChatBubble: View {
        let message: MockChatMessage
        let showsRawMarkdown: Bool
        let showsDiagnostics: Bool

        var body: some View {
            Group {
                if message.isStreaming, message.text.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Waiting for streamed Markdown")
                } else if showsRawMarkdown {
                    Text(message.text)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                } else {
                    ChatMarkdownMessageView(
                        messageID: message.id.uuidString,
                        source: message.text,
                        presentation: ChatMarkdownPresentation(
                            isStreaming: message.isStreaming,
                            streamingThrottle: message.renderThrottle,
                            showsDiagnostics: showsDiagnostics
                        )
                    )
                }
            }
            .padding(.horizontal, message.role == .user ? 14 : 0)
            .padding(.vertical, message.role == .user ? 10 : 0)
            .background(
                message.role == .user ? Color.accentColor.opacity(0.15) : Color.clear,
                in: .rect(cornerRadius: 18)
            )
            .frame(
                maxWidth: .infinity,
                alignment: message.role == .user ? .trailing : .leading
            )
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

        init(
            id: UUID = UUID(),
            role: Role,
            text: String,
            isStreaming: Bool = false,
            updateCount: Int = 0,
            label: String? = nil,
            fileChangesFixture: FileChangesFixture? = nil,
            renderThrottle: Duration = .milliseconds(50)
        ) {
            self.id = id
            self.role = role
            self.text = text
            self.isStreaming = isStreaming
            self.updateCount = updateCount
            self.label = label
            self.fileChangesFixture = fileChangesFixture
            self.renderThrottle = renderThrottle
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
#endif
