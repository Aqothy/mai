#if os(macOS)
    import AppKit
    import SwiftUI
    import WebKit

    /// Opt-in seam for comparing one WebKit transcript against the native
    /// timeline without changing the production renderer.
    nonisolated enum ChatWebTranscriptRenderer {
        static let launchArgument = "-ChatWebTranscript"

        static var isEnabled: Bool {
            ProcessInfo.processInfo.arguments.contains(launchArgument)
                || UserDefaults.standard.bool(forKey: "ChatWebTranscript")
        }
    }

    /// One keyed semantic row sent to WebContent. The payload stays deliberately
    /// small: raw Markdown and collapsed tool details cross the bridge, while
    /// scrolling, selection, layout, and expansion rendering stay in WebKit.
    nonisolated struct ChatWebTranscriptRow: Codable, Equatable, Sendable {
        let id: String
        let kind: String
        let role: String?
        let markdown: String?
        let title: String?
        let detail: String?
        let label: String?
        let sectionID: String?
        let status: String?
        let isStreaming: Bool
        let isExpanded: Bool
        let isRunning: Bool
        let hasFailure: Bool
        let options: [ChatWebTranscriptOption]?

        init(
            id: String,
            kind: String = "message",
            role: String? = nil,
            markdown: String? = nil,
            title: String? = nil,
            detail: String? = nil,
            label: String? = nil,
            sectionID: String? = nil,
            status: String? = nil,
            isStreaming: Bool = false,
            isExpanded: Bool = false,
            isRunning: Bool = false,
            hasFailure: Bool = false,
            options: [ChatWebTranscriptOption]? = nil
        ) {
            self.id = id
            self.kind = kind
            self.role = role
            self.markdown = markdown
            self.title = title
            self.detail = detail
            self.label = label
            self.sectionID = sectionID
            self.status = status
            self.isStreaming = isStreaming
            self.isExpanded = isExpanded
            self.isRunning = isRunning
            self.hasFailure = hasFailure
            self.options = options
        }
    }

    nonisolated struct ChatWebTranscriptOption: Codable, Equatable, Sendable {
        let title: String
        let decision: String
        let optionID: String?
    }

    /// The WebContent process owns its animation clock, so its benchmark must
    /// report requestAnimationFrame pacing rather than borrowing the app
    /// process's display link.
    @MainActor
    protocol ChatWebTranscriptBenchmarkDriving: AnyObject {
        func runScrollBenchmark(
            pointsPerSecond: CGFloat,
            maximumSweepSeconds: TimeInterval,
            label: String,
            displayMaximumFPS: Int
        ) async -> ChatFramePacingReport?
    }

    @MainActor
    enum ChatWebTranscriptBenchmarkRegistry {
        static weak var activeDriver: (any ChatWebTranscriptBenchmarkDriving)?
    }

    struct MockChatWebTimeline: View {
        let messages: [MockChatMessage]
        let scrollState: ChatScrollState

        @State private var hasStartedBenchmarkWarmup = false

        var body: some View {
            ChatWebTranscriptView(
                rows: messages.map { message in
                    ChatWebTranscriptRow(
                        id: message.id.uuidString,
                        role: message.role == .user ? "user" : "assistant",
                        markdown: message.displayedText,
                        label: message.displayedLabel,
                        isStreaming: message.displayedIsStreaming
                    )
                },
                scrollState: scrollState,
                onRendered: transcriptDidRender
            )
            .onAppear {
                guard ChatBenchmarkAutoRun.plan != nil,
                    messages.count >= 1_000,
                    !hasStartedBenchmarkWarmup
                else { return }
                hasStartedBenchmarkWarmup = true
                ChatBenchmarkAutoRun.noteTranscriptWarmStarted()
            }
        }

        private func transcriptDidRender() {
            guard ChatBenchmarkAutoRun.plan != nil,
                messages.count >= 1_000
            else { return }
            ChatBenchmarkAutoRun.noteTranscriptWarm()
        }
    }

    /// Production-model adapter used by the real-thread A/B experiment. It
    /// deliberately reuses `ChatTimelineLayout` so native and WebKit receive
    /// the same turn folds, final messages, notices, approvals, and page
    /// boundaries instead of maintaining a second interpretation of history.
    struct ChatWebThreadTimeline: View {
        private static let initialTurnCount = 5
        private static let earlierTurnCount = 10

        let threadID: String
        let sections: [ChatTimelineLayout.Section]
        let plan: Plan?
        let latestTurn: Turn?
        let streamingTurnID: String?
        let store: ThreadStore
        let scrollState: ChatScrollState

        @State private var foldModel = ChatTimelineFoldModel()
        @State private var oldestLoadedSectionID: String?
        @State private var isLoadingEarlier = false
        @State private var didStartBenchmarkWarmup = false
        @State private var approvalError: String?

        var body: some View {
            let loadedSections = loadedSections
            let timelineRows = ChatTimelineLayout.rows(
                sections: loadedSections,
                streamingTurnID: streamingTurnID,
                latestTurn: latestTurn,
                expandedSectionIDs: foldModel.expandedSectionIDs
            )
            let hasEarlierSections =
                loadedSections.first?.id != sections.first?.id

            ChatWebTranscriptView(
                rows: transcriptRows(
                    timelineRows,
                    hasEarlierSections: hasEarlierSections
                ),
                scrollState: scrollState,
                onRendered: transcriptDidRender,
                onToggleSection: toggleSection,
                onLoadEarlier: loadEarlier,
                onApproval: respondToApproval
            )
            .overlay(alignment: .top) {
                if isLoadingEarlier {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 8)
                        .accessibilityLabel("Loading earlier messages")
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                if let approvalError {
                    Text(approvalError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(8)
                        .background(.regularMaterial, in: .rect(cornerRadius: 8))
                        .padding(.top, 8)
                }
            }
            .onAppear {
                guard isRealThreadBenchmark, !didStartBenchmarkWarmup else {
                    return
                }
                didStartBenchmarkWarmup = true
                ChatBenchmarkAutoRun.noteTranscriptWarmStarted()
            }
            .onChange(of: sections.first?.id) { _, firstSectionID in
                guard let oldestLoadedSectionID,
                    sections.contains(where: { $0.id == oldestLoadedSectionID })
                else {
                    self.oldestLoadedSectionID = firstSectionID
                    return
                }
            }
        }

        private var isRealThreadBenchmark: Bool {
            ChatBenchmarkAutoRun.plan != nil
                && ChatBenchmarkAutoRun.threadTitleQuery != nil
        }

        private var loadedSections: [ChatTimelineLayout.Section] {
            if isRealThreadBenchmark {
                return sections
            }
            if let oldestLoadedSectionID,
                let index = sections.firstIndex(where: {
                    $0.id == oldestLoadedSectionID
                })
            {
                return Array(sections[index...])
            }
            return ChatTimelineLayout.paginatedSections(
                sections,
                userMessageLimit: Self.initialTurnCount
            )
        }

        private func transcriptRows(
            _ rows: [ChatTimelineRowModel],
            hasEarlierSections: Bool
        ) -> [ChatWebTranscriptRow] {
            var result: [ChatWebTranscriptRow] = []
            result.reserveCapacity(rows.count + 3)

            if hasEarlierSections {
                result.append(
                    ChatWebTranscriptRow(
                        id: "chat-history-marker",
                        kind: "history",
                        title: "Load earlier messages"
                    )
                )
            } else if let plan, !plan.entries.isEmpty {
                result.append(planRow(plan))
            }

            result.append(contentsOf: rows.map(transcriptRow))

            if streamingTurnID != nil {
                result.append(
                    ChatWebTranscriptRow(
                        id: "chat-working-indicator",
                        kind: "working",
                        title: "Working",
                        isRunning: true
                    )
                )
            }
            return result
        }

        private func transcriptRow(
            _ row: ChatTimelineRowModel
        ) -> ChatWebTranscriptRow {
            switch row {
            case .message(let message):
                let isStreaming =
                    streamingTurnID != nil
                    && message.turnID == streamingTurnID
                    && message.role == MaidMessageRole.assistant.rawValue
                let streamedText = isStreaming
                    ? store.streamingMessageText(
                        threadID: threadID,
                        messageID: message.id
                    )?.text
                    : nil
                let attachments = message.attachments?.compactMap {
                    $0.name ?? $0.kind
                }.joined(separator: " · ")
                return ChatWebTranscriptRow(
                    id: row.id,
                    role: message.role == MaidMessageRole.user.rawValue
                        ? "user" : "assistant",
                    markdown: streamedText ?? message.text,
                    label: attachments?.isEmpty == false ? attachments : nil,
                    isStreaming: isStreaming
                )

            case .thought(let item):
                let streamedText = store.streamingReasoningText(
                    threadID: threadID,
                    itemID: item.id
                )?.text
                return ChatWebTranscriptRow(
                    id: row.id,
                    kind: "thought",
                    title: thoughtTitle(item),
                    detail: streamedText ?? ChatTimelineLayout.reasoningText(item),
                    isStreaming: item.itemStatus == .inProgress,
                    isExpanded: item.itemStatus == .inProgress
                )

            case .turnActivity(let activity):
                return ChatWebTranscriptRow(
                    id: row.id,
                    kind: "turnActivity",
                    title: activity.isRunning ? "Working" : activity.title,
                    sectionID: activity.sectionID,
                    isExpanded: activity.isExpanded,
                    isRunning: activity.isRunning,
                    hasFailure: activity.hasFailure
                )

            case .activityGroup(let group):
                return ChatWebTranscriptRow(
                    id: row.id,
                    kind: "activityGroup",
                    title: group.items.count == 1
                        ? activityItemTitle(group.items[0]) : group.summary,
                    detail: activityDetail(group.items),
                    status: group.hasFailure
                        ? "failed" : (group.isInProgress ? "inProgress" : nil),
                    isRunning: group.isInProgress,
                    hasFailure: group.hasFailure
                )

            case .notice(let item):
                return ChatWebTranscriptRow(
                    id: row.id,
                    kind: "notice",
                    title: item.title ?? humanized(item.kind),
                    detail: ChatTimelineLayout.reasoningText(item),
                    status: item.itemKind == .error ? "error" : "warning",
                    hasFailure: item.itemKind == .error
                )

            case .approval(let approval):
                return approvalRow(approval, id: row.id)
            }
        }

        private func planRow(_ plan: Plan) -> ChatWebTranscriptRow {
            let detail = plan.entries.map { entry in
                let checked = entry.status == "completed" ? "x" : " "
                let status = entry.status.map { " — \(humanized($0))" } ?? ""
                return "- [\(checked)] \(entry.content)\(status)"
            }.joined(separator: "\n")
            return ChatWebTranscriptRow(
                id: "chat-plan",
                kind: "plan",
                title: "Plan",
                detail: detail
            )
        }

        private func approvalRow(
            _ approval: Approval,
            id: String
        ) -> ChatWebTranscriptRow {
            let options: [ChatWebTranscriptOption]?
            if approval.approvalStatus == .pending {
                if let approvalOptions = approval.options,
                    !approvalOptions.isEmpty
                {
                    options = approvalOptions.map { option in
                        let decision: MaidApprovalDecision = switch option.kind {
                        case "allow_always": .acceptForSession
                        case "reject_once", "reject_always": .decline
                        default: .accept
                        }
                        return ChatWebTranscriptOption(
                            title: option.name,
                            decision: decision.rawValue,
                            optionID: option.optionID
                        )
                    }
                } else {
                    options = [
                        ChatWebTranscriptOption(
                            title: "Decline",
                            decision: MaidApprovalDecision.decline.rawValue,
                            optionID: nil
                        ),
                        ChatWebTranscriptOption(
                            title: "Allow",
                            decision: MaidApprovalDecision.accept.rawValue,
                            optionID: nil
                        ),
                    ]
                }
            } else {
                options = nil
            }
            return ChatWebTranscriptRow(
                id: id,
                kind: "approval",
                title: "Permission needed",
                detail: approval.args.map { encodedJSON($0.value) },
                status: approval.approvalStatus == .pending
                    ? "pending"
                    : approval.decision.map(humanized) ?? "Resolved",
                options: options
            )
        }

        private func thoughtTitle(_ item: Item) -> String {
            let seconds = item.updatedAt.timeIntervalSince(item.createdAt)
            guard item.itemStatus != .inProgress, seconds >= 1 else {
                return "Thought"
            }
            return "Thought for \(ChatTurnActivity.formatted(.seconds(seconds)))"
        }

        private func activityItemTitle(_ item: Item) -> String {
            let summary = item.toolCallSummary
            switch ChatActivityVerb(item: item) {
            case .ranCommand:
                if let command = summary?.commandPreview, !command.isEmpty {
                    return "Ran \(command)"
                }
            case .thought:
                return thoughtTitle(item)
            case .read:
                if let path = summary?.locations?.first?.path, !path.isEmpty {
                    return "Read \(lastPathComponent(path))"
                }
            case .edited:
                if let path = summary?.changes?.first?.path, !path.isEmpty {
                    let extra = max(0, (summary?.changeCount ?? 1) - 1)
                    return "Edited \(lastPathComponent(path))"
                        + (extra > 0 ? " +\(extra)" : "")
                }
            case .searched:
                if let query = summary?.queryPreview, !query.isEmpty {
                    return "Searched \(query)"
                }
            case .fetched, .tool:
                break
            }
            if let title = item.title, !title.isEmpty { return title }
            return ChatActivityVerb(item: item)
                .phrase(count: 1, toolName: summary?.name)
                .capitalizedFirst
        }

        private func activityDetail(_ items: [Item]) -> String {
            items.map { item in
                var blocks = ["### \(activityItemTitle(item))"]
                let summary = item.toolCallSummary
                if let command = summary?.commandPreview, !command.isEmpty {
                    blocks.append("```shell\n$ \(truncated(command))\n```")
                }
                if let query = summary?.queryPreview, !query.isEmpty {
                    blocks.append(query)
                }
                if let output = summary?.outputPreview, !output.isEmpty {
                    blocks.append("```text\n\(truncated(output))\n```")
                }
                if let error = summary?.errorPreview, !error.isEmpty {
                    blocks.append("```text\n\(truncated(error))\n```")
                }
                if let changes = summary?.changes, !changes.isEmpty {
                    blocks.append(
                        changes.map { "- Edited `\($0.path)`" }
                            .joined(separator: "\n")
                    )
                }
                return blocks.joined(separator: "\n\n")
            }.joined(separator: "\n\n")
        }

        private func toggleSection(_ sectionID: String) {
            foldModel.toggle(sectionID)
        }

        private func loadEarlier() {
            guard !isLoadingEarlier,
                let firstLoaded = loadedSections.first,
                let oldStartIndex = sections.firstIndex(where: {
                    $0.id == firstLoaded.id
                }),
                oldStartIndex > sections.startIndex
            else { return }

            let page = ChatTimelineLayout.paginatedSections(
                sections[..<oldStartIndex],
                userMessageLimit: Self.earlierTurnCount
            )
            guard let newOldestSectionID = page.first?.id else { return }
            isLoadingEarlier = true
            oldestLoadedSectionID = newOldestSectionID
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                isLoadingEarlier = false
            }
        }

        private func respondToApproval(
            requestID: String,
            decision: String,
            optionID: String?
        ) {
            guard let decision = MaidApprovalDecision(rawValue: decision) else {
                return
            }
            approvalError = nil
            Task {
                do {
                    try await store.respondToApproval(
                        threadID: threadID,
                        requestID: requestID,
                        decision: decision,
                        optionID: optionID
                    )
                } catch {
                    approvalError = error.localizedDescription
                }
            }
        }

        private func transcriptDidRender() {
            if isRealThreadBenchmark {
                ChatBenchmarkAutoRun.noteTranscriptWarm()
            }
        }

        private func humanized(_ value: String) -> String {
            value.replacing("_", with: " ")
                .replacing("-", with: " ")
                .capitalized
        }

        private func lastPathComponent(_ path: String) -> String {
            path.split(separator: "/").last.map(String.init) ?? path
        }

        private func truncated(_ text: String) -> String {
            String(text.prefix(4_000))
        }

        private func encodedJSON(_ value: Any) -> String {
            if let string = value as? String { return string }
            guard JSONSerialization.isValidJSONObject(value),
                let data = try? JSONSerialization.data(
                    withJSONObject: value,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                )
            else { return String(describing: value) }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private struct ChatWebTranscriptView: NSViewRepresentable {
        let rows: [ChatWebTranscriptRow]
        let scrollState: ChatScrollState
        let onRendered: @MainActor () -> Void
        var onToggleSection: @MainActor (String) -> Void = { _ in }
        var onLoadEarlier: @MainActor () -> Void = {}
        var onApproval: @MainActor (String, String, String?) -> Void = {
            _, _, _ in
        }

        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        func makeCoordinator() -> Coordinator {
            Coordinator(
                scrollState: scrollState,
                onToggleSection: onToggleSection,
                onLoadEarlier: onLoadEarlier,
                onApproval: onApproval
            )
        }

        func makeNSView(context: Context) -> WKWebView {
            let contentController = WKUserContentController()
            contentController.add(
                WeakChatWebScriptMessageHandler(coordinator: context.coordinator),
                name: Coordinator.messageHandlerName
            )

            let configuration = WKWebViewConfiguration()
            configuration.userContentController = contentController
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true

            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = context.coordinator
            webView.allowsMagnification = false
            webView.alphaValue = 0
            webView.setAccessibilityIdentifier("chat-web-transcript")
            context.coordinator.attach(to: webView)

            if let documentURL = Bundle.main.url(
                forResource: "ChatWebTranscript",
                withExtension: "html"
            ) {
                webView.loadFileURL(
                    documentURL,
                    allowingReadAccessTo: documentURL.deletingLastPathComponent()
                )
            } else {
                webView.loadHTMLString(
                    "<p role=alert>Chat Web transcript resource is missing.</p>",
                    baseURL: nil
                )
            }
            return webView
        }

        func updateNSView(_ webView: WKWebView, context: Context) {
            context.coordinator.onRendered = onRendered
            context.coordinator.onToggleSection = onToggleSection
            context.coordinator.onLoadEarlier = onLoadEarlier
            context.coordinator.onApproval = onApproval
            context.coordinator.update(
                rows: rows,
                followsBottom: scrollState.shouldFollowBottom,
                bottomScrollRequest: scrollState.bottomScrollRequest,
                colorScheme: colorScheme,
                fontScale: Self.fontScale(for: dynamicTypeSize)
            )
        }

        static func dismantleNSView(
            _ webView: WKWebView,
            coordinator: Coordinator
        ) {
            coordinator.detach(from: webView)
        }

        private static func fontScale(for size: DynamicTypeSize) -> Double {
            switch size {
            case .xSmall: 0.88
            case .small: 0.94
            case .medium: 0.97
            case .large: 1
            case .xLarge: 1.12
            case .xxLarge: 1.23
            case .xxxLarge: 1.35
            case .accessibility1: 1.5
            case .accessibility2: 1.65
            case .accessibility3: 1.85
            case .accessibility4: 2.05
            case .accessibility5: 2.3
            @unknown default: 1
            }
        }

        @MainActor
        final class Coordinator: NSObject, WKNavigationDelegate,
            ChatWebTranscriptBenchmarkDriving
        {
            static let messageHandlerName = "maiChat"

            private weak var webView: WKWebView?
            private let scrollState: ChatScrollState
            private var isReady = false
            private var pendingUpdate: PendingUpdate?
            private var updateTask: Task<Void, Never>?
            private var generation = 0
            private var lastRows: [ChatWebTranscriptRow] = []
            private var lastFollowsBottom = true
            private var lastBottomScrollRequestCount = 0
            private var lastColorScheme = ColorScheme.light
            private var lastFontScale = 1.0
            private var benchmarkContinuation: CheckedContinuation<ChatFramePacingReport?, Never>?

            var onRendered: (@MainActor () -> Void)?
            var onToggleSection: @MainActor (String) -> Void
            var onLoadEarlier: @MainActor () -> Void
            var onApproval: @MainActor (String, String, String?) -> Void

            init(
                scrollState: ChatScrollState,
                onToggleSection: @escaping @MainActor (String) -> Void,
                onLoadEarlier: @escaping @MainActor () -> Void,
                onApproval: @escaping @MainActor (String, String, String?) -> Void
            ) {
                self.scrollState = scrollState
                self.onToggleSection = onToggleSection
                self.onLoadEarlier = onLoadEarlier
                self.onApproval = onApproval
            }

            func attach(to webView: WKWebView) {
                self.webView = webView
                ChatWebTranscriptBenchmarkRegistry.activeDriver = self
            }

            func detach(from webView: WKWebView) {
                updateTask?.cancel()
                updateTask = nil
                benchmarkContinuation?.resume(returning: nil)
                benchmarkContinuation = nil
                webView.stopLoading()
                webView.configuration.userContentController
                    .removeScriptMessageHandler(forName: Self.messageHandlerName)
                if ChatWebTranscriptBenchmarkRegistry.activeDriver === self {
                    ChatWebTranscriptBenchmarkRegistry.activeDriver = nil
                }
                self.webView = nil
            }

            func update(
                rows: [ChatWebTranscriptRow],
                followsBottom: Bool,
                bottomScrollRequest: ChatScrollState.BottomScrollRequest,
                colorScheme: ColorScheme,
                fontScale: Double
            ) {
                let update = PendingUpdate(
                    rows: rows,
                    followsBottom: followsBottom,
                    bottomScrollRequest: bottomScrollRequest,
                    colorScheme: colorScheme,
                    fontScale: fontScale
                )
                pendingUpdate = update
                guard isReady else { return }
                apply(update)
            }

            private func apply(_ update: PendingUpdate) {
                guard let webView else { return }
                pendingUpdate = nil

                let rowsChanged = update.rows != lastRows
                let rowUpdate = rowsChanged
                    ? Self.rowUpdate(
                        from: lastRows,
                        to: update.rows,
                        forcesFullUpdate: updateTask != nil
                    )
                    : nil
                let followingChanged = update.followsBottom != lastFollowsBottom
                let themeChanged =
                    update.colorScheme != lastColorScheme
                    || update.fontScale != lastFontScale
                let bottomRequestChanged =
                    update.bottomScrollRequest.count != lastBottomScrollRequestCount

                lastRows = update.rows
                lastFollowsBottom = update.followsBottom
                lastColorScheme = update.colorScheme
                lastFontScale = update.fontScale
                lastBottomScrollRequestCount = update.bottomScrollRequest.count

                guard
                    rowsChanged || followingChanged || themeChanged
                        || bottomRequestChanged
                else { return }

                generation &+= 1
                let currentGeneration = generation
                updateTask?.cancel()
                updateTask = Task { [weak self, weak webView] in
                    guard let self, let webView else { return }

                    if themeChanged {
                        _ = await self.call(
                            "window.maiChat.setTheme(theme, fontScale)",
                            arguments: [
                                "theme": update.colorScheme == .dark
                                    ? "dark" : "light",
                                "fontScale": update.fontScale,
                            ],
                            in: webView
                        )
                    }

                    if let rowUpdate {
                        let succeeded: Bool
                        switch rowUpdate {
                        case .full(let rows):
                            let rowsJSON = await Task.detached(
                                priority: .userInitiated
                            ) {
                                Self.encoded(rows)
                            }.value
                            guard !Task.isCancelled,
                                currentGeneration == self.generation,
                                let rowsJSON
                            else { return }
                            succeeded = await self.call(
                                "window.maiChat.setRows(JSON.parse(rowsJSON), followsBottom)",
                                arguments: [
                                    "rowsJSON": rowsJSON,
                                    "followsBottom": update.followsBottom,
                                ],
                                in: webView
                            )

                        case .patch(let rows):
                            let rowsJSON = await Task.detached(
                                priority: .userInitiated
                            ) {
                                Self.encoded(rows)
                            }.value
                            guard !Task.isCancelled,
                                currentGeneration == self.generation,
                                let rowsJSON
                            else { return }
                            succeeded = await self.call(
                                "window.maiChat.patchRows(JSON.parse(rowsJSON))",
                                arguments: ["rowsJSON": rowsJSON],
                                in: webView
                            )

                        case .append(
                            let id,
                            let suffix,
                            let isStreaming,
                            let label
                        ):
                            succeeded = await self.call(
                                "window.maiChat.appendMessage(id, suffix, isStreaming, label)",
                                arguments: [
                                    "id": id,
                                    "suffix": suffix,
                                    "isStreaming": isStreaming,
                                    "label": label ?? NSNull(),
                                ],
                                in: webView
                            )
                        }
                        if !succeeded {
                            self.lastRows = []
                        }
                    } else if followingChanged {
                        _ = await self.call(
                            "window.maiChat.setFollowing(followsBottom)",
                            arguments: ["followsBottom": update.followsBottom],
                            in: webView
                        )
                    }

                    if bottomRequestChanged {
                        _ = await self.call(
                            "window.maiChat.scrollToBottom(animated)",
                            arguments: [
                                "animated": update.bottomScrollRequest.animated
                            ],
                            in: webView
                        )
                    }

                    if currentGeneration == self.generation {
                        self.updateTask = nil
                    }
                }
            }

            nonisolated private static func rowUpdate(
                from oldRows: [ChatWebTranscriptRow],
                to newRows: [ChatWebTranscriptRow],
                forcesFullUpdate: Bool
            ) -> RowUpdate {
                guard !forcesFullUpdate,
                    oldRows.count == newRows.count,
                    oldRows.indices.allSatisfy({
                        oldRows[$0].id == newRows[$0].id
                    })
                else { return .full(newRows) }

                let changedIndices = oldRows.indices.filter {
                    oldRows[$0] != newRows[$0]
                }
                guard changedIndices.count == 1,
                    let index = changedIndices.first
                else {
                    return .patch(changedIndices.map { newRows[$0] })
                }

                let oldRow = oldRows[index]
                let newRow = newRows[index]
                if canAppend(from: oldRow, to: newRow),
                    let oldMarkdown = oldRow.markdown,
                    let newMarkdown = newRow.markdown
                {
                    return .append(
                        id: newRow.id,
                        suffix: String(newMarkdown.dropFirst(oldMarkdown.count)),
                        isStreaming: newRow.isStreaming,
                        label: newRow.label
                    )
                }
                return .patch([newRow])
            }

            nonisolated private static func canAppend(
                from oldRow: ChatWebTranscriptRow,
                to newRow: ChatWebTranscriptRow
            ) -> Bool {
                guard oldRow.kind == "message", newRow.kind == "message",
                    let oldMarkdown = oldRow.markdown,
                    let newMarkdown = newRow.markdown,
                    newMarkdown.hasPrefix(oldMarkdown)
                else { return false }
                return oldRow.id == newRow.id
                    && oldRow.role == newRow.role
                    && oldRow.title == newRow.title
                    && oldRow.detail == newRow.detail
                    && oldRow.label == newRow.label
                    && oldRow.sectionID == newRow.sectionID
                    && oldRow.status == newRow.status
                    && oldRow.isExpanded == newRow.isExpanded
                    && oldRow.isRunning == newRow.isRunning
                    && oldRow.hasFailure == newRow.hasFailure
                    && oldRow.options == newRow.options
            }

            func runScrollBenchmark(
                pointsPerSecond: CGFloat,
                maximumSweepSeconds: TimeInterval,
                label: String,
                displayMaximumFPS: Int
            ) async -> ChatFramePacingReport? {
                guard isReady, benchmarkContinuation == nil, let webView else {
                    return nil
                }

                return await withCheckedContinuation { continuation in
                    benchmarkContinuation = continuation
                    Task { [weak self, weak webView] in
                        guard let self, let webView else {
                            continuation.resume(returning: nil)
                            return
                        }
                        let succeeded = await self.call(
                            "window.maiChat.runScrollBenchmark(speed, maximumSeconds, label, displayMaximumFPS)",
                            arguments: [
                                "speed": Double(pointsPerSecond),
                                "maximumSeconds": maximumSweepSeconds,
                                "label": label,
                                "displayMaximumFPS": displayMaximumFPS,
                            ],
                            in: webView
                        )
                        if !succeeded, self.benchmarkContinuation != nil {
                            self.benchmarkContinuation = nil
                            continuation.resume(returning: nil)
                        }
                    }
                }
            }

            private func call(
                _ script: String,
                arguments: [String: Any],
                in webView: WKWebView
            ) async -> Bool {
                do {
                    _ = try await webView.callAsyncJavaScript(
                        script,
                        arguments: arguments,
                        in: nil,
                        contentWorld: .page
                    )
                    return true
                } catch {
                    ChatBenchmarkAutoRun.trace(
                        "web transcript JavaScript error: \(error.localizedDescription)"
                    )
                    return false
                }
            }

            nonisolated private static func encoded(
                _ rows: [ChatWebTranscriptRow]
            ) -> String? {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.withoutEscapingSlashes]
                guard let data = try? encoder.encode(rows) else { return nil }
                return String(decoding: data, as: UTF8.self)
            }

            private func handle(_ body: Any) {
                guard let message = body as? [String: Any],
                    let action = message["action"] as? String
                else { return }

                switch action {
                case "ready":
                    isReady = true
                    if let pendingUpdate {
                        apply(pendingUpdate)
                    }

                case "rendered":
                    webView?.alphaValue = 1
                    onRendered?()

                case "scrollIntent":
                    if message["direction"] as? String == "away" {
                        scrollState.noteScrollAwayFromEnd()
                    } else {
                        scrollState.noteScrollTowardEnd()
                    }

                case "scrollActivity":
                    if let isActive = message["active"] as? Bool {
                        scrollState.noteUserScrollActivity(isActive: isActive)
                    }

                case "scrollState":
                    guard let isNearBottom = message["nearBottom"] as? Bool else {
                        return
                    }
                    if isNearBottom {
                        scrollState.noteScrollReturnedToEnd()
                    } else {
                        scrollState.noteEndVisibility(false)
                    }

                case "toggleSection":
                    guard let sectionID = message["sectionID"] as? String else {
                        return
                    }
                    scrollState.noteContentExpansion()
                    onToggleSection(sectionID)

                case "loadEarlier":
                    onLoadEarlier()

                case "contentExpansion":
                    scrollState.noteContentExpansion()

                case "approval":
                    guard let requestID = message["requestID"] as? String,
                        let decision = message["decision"] as? String
                    else { return }
                    onApproval(
                        requestID,
                        decision,
                        message["optionID"] as? String
                    )

                case "copy":
                    guard let text = message["text"] as? String else { return }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)

                case "openLink":
                    guard let rawURL = message["url"] as? String,
                        let url = URL(string: rawURL),
                        url.scheme == "https" || url.scheme == "http"
                    else { return }
                    NSWorkspace.shared.open(url)

                case "benchmarkComplete":
                    let report = Self.report(from: message)
                    let continuation = benchmarkContinuation
                    benchmarkContinuation = nil
                    continuation?.resume(returning: report)

                default:
                    break
                }
            }

            nonisolated private static func report(
                from message: [String: Any]
            ) -> ChatFramePacingReport? {
                func double(_ key: String) -> Double? {
                    (message[key] as? NSNumber)?.doubleValue
                }
                func integer(_ key: String) -> Int? {
                    (message[key] as? NSNumber)?.intValue
                }
                guard let label = message["label"] as? String,
                    let displayMaximumFPS = integer("displayMaximumFPS"),
                    let frameCount = integer("frameCount"),
                    let durationSeconds = double("durationSeconds"),
                    let averageFPS = double("averageFPS"),
                    let expectedFrameMilliseconds = double(
                        "expectedFrameMilliseconds"
                    ),
                    let p50FrameMilliseconds = double("p50FrameMilliseconds"),
                    let p95FrameMilliseconds = double("p95FrameMilliseconds"),
                    let p99FrameMilliseconds = double("p99FrameMilliseconds"),
                    let maxFrameMilliseconds = double("maxFrameMilliseconds"),
                    let hitchCount = integer("hitchCount"),
                    let hitchTimeMillisecondsPerSecond = double(
                        "hitchTimeMillisecondsPerSecond"
                    )
                else { return nil }

                return ChatFramePacingReport(
                    label: label,
                    displayMaximumFPS: displayMaximumFPS,
                    frameCount: frameCount,
                    durationSeconds: durationSeconds,
                    averageFPS: averageFPS,
                    expectedFrameMilliseconds: expectedFrameMilliseconds,
                    p50FrameMilliseconds: p50FrameMilliseconds,
                    p95FrameMilliseconds: p95FrameMilliseconds,
                    p99FrameMilliseconds: p99FrameMilliseconds,
                    maxFrameMilliseconds: maxFrameMilliseconds,
                    hitchCount: hitchCount,
                    hitchTimeMillisecondsPerSecond:
                        hitchTimeMillisecondsPerSecond
                )
            }

            func userContentController(
                _ userContentController: WKUserContentController,
                didReceive message: WKScriptMessage
            ) {
                handle(message.body)
            }

            func webView(
                _ webView: WKWebView,
                decidePolicyFor navigationAction: WKNavigationAction
            ) async -> WKNavigationActionPolicy {
                guard navigationAction.navigationType == .other,
                    navigationAction.request.url?.isFileURL == true
                else { return .cancel }
                return .allow
            }

            private struct PendingUpdate {
                let rows: [ChatWebTranscriptRow]
                let followsBottom: Bool
                let bottomScrollRequest: ChatScrollState.BottomScrollRequest
                let colorScheme: ColorScheme
                let fontScale: Double
            }

            private enum RowUpdate {
                case full([ChatWebTranscriptRow])
                case patch([ChatWebTranscriptRow])
                case append(
                    id: String,
                    suffix: String,
                    isStreaming: Bool,
                    label: String?
                )
            }
        }
    }

    @MainActor
    private final class WeakChatWebScriptMessageHandler: NSObject,
        WKScriptMessageHandler
    {
        private weak var coordinator: ChatWebTranscriptView.Coordinator?

        init(coordinator: ChatWebTranscriptView.Coordinator) {
            self.coordinator = coordinator
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            coordinator?.userContentController(
                userContentController,
                didReceive: message
            )
        }
    }
#endif
