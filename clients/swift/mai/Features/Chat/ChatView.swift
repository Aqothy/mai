import SwiftUI

struct ChatView: View {
    let store: ThreadStore
    let draftStore: ThreadDraftStore

    @State private var draftModel: DraftPromptModel
    @State private var chatModel: ChatPromptModel?
    @State private var scrollState = ChatScrollState()

    init(store: ThreadStore, draftStore: ThreadDraftStore) {
        self.store = store
        self.draftStore = draftStore
        _draftModel = State(initialValue: DraftPromptModel(store: store, draftStore: draftStore))
    }

    var body: some View {
        Group {
            if let errorMessage = store.selectedThreadLoadErrorMessage {
                ThreadLoadErrorView(store: store, errorMessage: errorMessage)
            } else if let errorMessage = store.selectedThreadHistoryRestoreErrorMessage {
                ThreadLoadErrorView(store: store, errorMessage: errorMessage)
            } else if store.isSelectedThreadRestoringHistory {
                ProgressView("Restoring Chat…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let thread = store.selectedThread {
                ChatTimeline(
                    threadID: thread.id,
                    timeline: thread.timeline,
                    plan: thread.plan,
                    streamingTurnID: thread.latestTurn?.turnState == .running
                        ? thread.latestTurn?.turnID
                        : nil,
                    store: store,
                    scrollState: scrollState
                )
                .id(thread.id)
            } else if store.selectedThreadID != nil {
                ProgressView("Loading Chat…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DraftPromptView(model: draftModel)
            }
        }
        .overlay(alignment: .bottom) {
            if store.selectedThread != nil {
                ChatScrollToBottomButton(scrollState: scrollState) {
                    scrollState.requestScrollToBottom(animated: true)
                }
                .safeAreaPadding(.bottom)
            }
        }
        .modifier(
            ChatComposerSafeAreaBar(
                composer: ChatComposerStack(
                    store: store,
                    draftModel: draftModel,
                    chatModel: chatModel
                )
            )
        )
        .navigationTitle(selectedThreadTitle)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: store.selectedThreadID, initial: true) { _, threadID in
            scrollState.reset()
            if let threadID {
                if chatModel?.threadID != threadID {
                    chatModel = ChatPromptModel(
                        store: store,
                        draftStore: draftStore,
                        threadID: threadID
                    )
                }
            } else {
                chatModel = nil
            }
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { chatModel?.isErrorPresented ?? false },
                set: { chatModel?.isErrorPresented = $0 }
            )
        ) {
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(chatModel?.errorMessage ?? "An unknown error occurred.")
        }
    }

    private var selectedThreadTitle: String {
        if let title = store.selectedThread?.title {
            return title
        }
        return store.selectedThreadTitle ?? ""
    }
}

/// One composer for both the draft and thread phases. Its structural
/// identity never changes across the transition, so the text field (and
/// keyboard focus) survives sending the first message; only the bindings
/// and controls around it swap. A dedicated view keeps composer changes from
/// re-evaluating the timeline.
private struct ChatComposerStack: View {
    let store: ThreadStore
    let draftModel: DraftPromptModel
    let chatModel: ChatPromptModel?

    var body: some View {
        let thread = store.selectedThread

        VStack(alignment: .leading) {
            if chatModel == nil {
                HStack(spacing: 16) {
                    DraftSessionControlsView(model: draftModel)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .padding(.bottom, 10)
            } else if let chatModel, !chatModel.queuedPrompts.isEmpty {
                ChatPromptQueueView(model: chatModel)
            }

            PromptComposer(
                text: promptText,
                isEnabled: chatModel == nil
                    ? draftModel.isPromptEnabled
                    : thread != nil && chatModel?.isPromptEnabled == true,
                focusID: nil,
                canSend: chatModel == nil
                    ? draftModel.canSend
                    : thread != nil && chatModel?.canSend == true,
                isSending: isSendingNow,
                isRunning: thread?.latestTurn?.turnState == .running,
                isStopping: chatModel?.isInterrupting == true,
                attachments: currentAttachments,
                submitLabel: chatModel == nil ? "Start chat" : "Send"
            ) {
                if let chatModel {
                    Task { await chatModel.send() }
                } else {
                    Task { await draftModel.send() }
                }
            } stop: {
                if let chatModel, let turnID = thread?.latestTurn?.turnID {
                    Task { await chatModel.interrupt(turnID: turnID) }
                }
            } removeAttachment: { id in
                if let chatModel {
                    chatModel.removeAttachment(id: id)
                } else {
                    draftModel.removeAttachment(id: id)
                }
            } leadingControls: {
                ComposerAddMenu(
                    isImageAttachmentAvailable: supportsImageAttachments,
                    isImageAttachmentDisabled: isSendingNow
                        || currentAttachments.count
                            >= ChatAttachmentLoader.maximumAttachmentCount,
                    maximumImageSelectionCount: max(
                        1,
                        ChatAttachmentLoader.maximumAttachmentCount - currentAttachments.count
                    ),
                    commands: thread?.session?.slashCommands ?? [],
                    addImages: chatModel?.addImages ?? draftModel.addImages,
                    addPhotos: chatModel?.addPhotos ?? draftModel.addPhotos,
                    addCameraImage: chatModel?.addCameraImage ?? draftModel.addCameraImage,
                    insertCommand: chatModel?.insertSlashCommand ?? { _ in },
                    showError: chatModel?.showError ?? draftModel.showError
                )
            } trailingControls: {
                if let chatModel, let thread {
                    ChatComposerControlsView(thread: thread, model: chatModel)
                } else if chatModel == nil {
                    DraftComposerControlsView(model: draftModel)
                }
            }
        }
    }

    private var promptText: Binding<String> {
        if let chatModel {
            @Bindable var chatModel = chatModel
            return $chatModel.text
        }
        @Bindable var draftModel = draftModel
        return $draftModel.prompt
    }

    private var currentAttachments: [ChatPendingAttachment] {
        chatModel?.attachments ?? draftModel.attachments
    }

    private var isSendingNow: Bool {
        chatModel?.isSending ?? draftModel.isSending
    }

    private var supportsImageAttachments: Bool {
        if chatModel != nil {
            return store.promptContentCapabilities(
                for: store.selectedThread?.providerInstanceID
            )?.image == true
        }
        return draftModel.supportsImageAttachments
    }
}

private struct ChatComposerSafeAreaBar<Composer: View>: ViewModifier {
    let composer: Composer

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.safeAreaBar(edge: .bottom, spacing: 0) {
                composer
            }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                composer
            }
        }
    }
}

private struct ChatTimeline: View {
    static let nearBottomDistance: CGFloat = 24
    /// Matches MarkdownView's default block spacing so the seam between two
    /// chunk rows reads as ordinary paragraph spacing.
    private static let interChunkSpacing: CGFloat = 8

    let threadID: String
    let timeline: [TimelineEntry]
    let plan: Plan?
    let streamingTurnID: String?
    let store: ThreadStore
    let scrollState: ChatScrollState

    private let chunkCache = ChatMarkdownChunkCache.shared

    #if os(iOS)
        @State private var proseWarmWidth: CGFloat = 0
    #endif

    var body: some View {
        let rows = timelineRows()

        ScrollViewReader { proxy in
            List {
                if let plan, !plan.entries.isEmpty {
                    ChatPlanRow(plan: plan)
                        .padding(.vertical, 10)
                        .listRowInsets(
                            .init(top: 0, leading: 16, bottom: 0, trailing: 16)
                        )
                        .listRowSeparator(.hidden)
                }

                ForEach(rows) { row in
                    switch row {
                    case .entry(let entry):
                        ChatTimelineRow(
                            entry: entry,
                            messagePresentation: entry.message.map {
                                ChatMarkdownPresentation.timelineMessage(
                                    role: $0.role,
                                    turnID: $0.turnID,
                                    streamingTurnID: streamingTurnID
                                )
                            } ?? ChatMarkdownPresentation(isStreaming: false),
                            threadID: threadID,
                            store: store
                        )
                        .padding(.vertical, 10)
                        .listRowInsets(
                            .init(top: 0, leading: 16, bottom: 0, trailing: 16)
                        )
                        .listRowSeparator(.hidden)
                    case .messageChunk(let chunk):
                        ChatMessageRow(
                            messageID: chunk.rowID,
                            text: chunk.text,
                            role: chunk.role,
                            attachments: chunk.attachments,
                            presentation: ChatMarkdownPresentation(isStreaming: false)
                        )
                        .padding(.top, chunk.isFirst ? 10 : 0)
                        .padding(.bottom, chunk.isLast ? 10 : Self.interChunkSpacing)
                        .listRowInsets(
                            .init(top: 0, leading: 16, bottom: 0, trailing: 16)
                        )
                        .listRowSeparator(.hidden)
                    case .messageProse(let chunk):
                        #if os(iOS)
                            ChatProseMessageRow(chunk: chunk)
                                .padding(.top, chunk.isFirst ? 10 : 0)
                                .padding(
                                    .bottom,
                                    chunk.isLast ? 10 : Self.interChunkSpacing
                                )
                                .listRowInsets(
                                    .init(top: 0, leading: 16, bottom: 0, trailing: 16)
                                )
                                .listRowSeparator(.hidden)
                        #else
                            EmptyView()
                        #endif
                    }
                }

                ChatEndMarker()
                    .id(Self.bottomID)
                    .listRowInsets(.init())
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .scrollDismissesKeyboard(.interactively)
            #if os(iOS)
                // Row content width is the list width minus the 16pt row
                // insets. Warming here — and again as the timeline grows —
                // keeps prose layout ahead of the scroll.
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width - 32
                } action: { width in
                    proseWarmWidth = width
                    warmProseLayouts(width: width)
                }
                .onChange(of: timeline.count) { _, _ in
                    warmProseLayouts(width: proseWarmWidth)
                }
                .onChange(of: streamingTurnID) { _, _ in
                    warmProseLayouts(width: proseWarmWidth)
                }
            #endif
            .onChange(of: scrollState.bottomScrollRequest) { _, request in
                if request.animated {
                    withAnimation(.smooth) {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                } else {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            .onScrollGeometryChange(for: ChatScrollGeometry.self) { geometry in
                ChatScrollGeometry(
                    isNearBottom: geometry.contentSize.height
                        + geometry.contentInsets.bottom
                        - geometry.visibleRect.maxY <= Self.nearBottomDistance,
                    containerHeight: geometry.containerSize.height,
                    bottomInset: geometry.contentInsets.bottom,
                    contentHeight: geometry.contentSize.height
                )
            } action: { oldGeometry, newGeometry in
                scrollState.noteEndVisibility(newGeometry.isNearBottom)
                let viewportShrank =
                    newGeometry.bottomInset > oldGeometry.bottomInset
                    || newGeometry.containerHeight < oldGeometry.containerHeight
                // The single follow-bottom path. It runs post-layout, so the
                // pin resolves against the FINAL content size — a scroll
                // issued alongside the data change would land short — and it
                // covers every source of content growth.
                let contentGrew = newGeometry.contentHeight > oldGeometry.contentHeight
                let shouldPin =
                    (viewportShrank || contentGrew) && scrollState.shouldFollowBottom
                if shouldPin {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
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

    private static let bottomID = "chat-bottom"

    /// Oversized settled assistant messages expand into several rows so List
    /// realizes a bounded amount of work per row; everything else maps one
    /// entry to one row. On iOS the preferred split is typed segments —
    /// unbounded selectable prose plus isolated rich blocks — with size-based
    /// chunks as the fallback for sources segments cannot honor (math,
    /// reference definitions).
    private func timelineRows() -> [ChatTimelineRowModel] {
        timeline.flatMap { entry -> [ChatTimelineRowModel] in
            guard let message = entry.message, isChunkable(message) else {
                return [.entry(entry)]
            }

            #if os(iOS)
                if let segments = chunkCache.segments(
                    messageID: message.id,
                    source: message.text
                ) {
                    return segmentRows(for: message, segments: segments)
                }
            #endif

            let chunks = chunkCache.chunks(
                messageID: message.id,
                source: message.text
            )
            guard chunks.count > 1 else { return [.entry(entry)] }
            return chunks.indices.map { index in
                .messageChunk(
                    ChatMessageChunkRowModel(
                        messageID: message.id,
                        index: index,
                        text: chunks[index],
                        role: message.role,
                        attachments: index == chunks.count - 1
                            ? message.attachments
                            : nil,
                        isFirst: index == 0,
                        isLast: index == chunks.count - 1
                    )
                )
            }
        }
    }

    #if os(iOS)
        private func segmentRows(
            for message: Message,
            segments: [ChatMarkdownSegment]
        ) -> [ChatTimelineRowModel] {
            segments.indices.map { index in
                let model = ChatMessageChunkRowModel(
                    messageID: message.id,
                    index: index,
                    text: segments[index].source,
                    role: message.role,
                    attachments: index == segments.count - 1
                        ? message.attachments
                        : nil,
                    isFirst: index == 0,
                    isLast: index == segments.count - 1
                )
                return segments[index].kind == .prose
                    ? .messageProse(model)
                    : .messageChunk(model)
            }
        }

        /// Feeds the layout store every settled prose segment so background
        /// layout finishes before rows scroll in.
        private func warmProseLayouts(width: CGFloat) {
            guard width > 0 else { return }
            var sources: [String] = []
            for entry in timeline {
                guard let message = entry.message, isChunkable(message),
                    let segments = chunkCache.segments(
                        messageID: message.id,
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

    /// Only settled assistant prose chunks: user messages keep their single
    /// bubble, and a streaming message keeps the streaming reader's
    /// single-view lifecycle until the turn completes.
    private func isChunkable(_ message: Message) -> Bool {
        message.role == MaidMessageRole.assistant.rawValue
            && (streamingTurnID == nil || message.turnID != streamingTurnID)
            && ChatMarkdownChunker.isOversized(message.text)
    }
}

private enum ChatTimelineRowModel: Identifiable {
    case entry(TimelineEntry)
    case messageChunk(ChatMessageChunkRowModel)
    /// A prose segment rendered by the pre-laid-out selectable text pipeline.
    case messageProse(ChatMessageChunkRowModel)

    var id: ChatRowIdentity {
        switch self {
        case .entry(let entry):
            entry.chatIdentity
        case .messageChunk(let chunk), .messageProse(let chunk):
            .messageChunk(chunk.messageID, chunk.index)
        }
    }
}

private struct ChatMessageChunkRowModel {
    let messageID: String
    let index: Int
    let text: String
    let role: String
    /// Attachments render once, under the final chunk.
    let attachments: [Attachment]?
    let isFirst: Bool
    let isLast: Bool

    var rowID: String { "\(messageID)#chunk-\(index)" }
}

#if os(iOS)
    /// Assistant prose rendered by the pre-laid-out selectable pipeline; no
    /// bubble styling because only assistant messages segment.
    private struct ChatProseMessageRow: View {
        let chunk: ChatMessageChunkRowModel

        var body: some View {
            VStack(alignment: .leading) {
                ChatProseMessageText(source: chunk.text)

                if let attachments = chunk.attachments, !attachments.isEmpty {
                    Text(attachments.map { $0.name ?? $0.kind }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
#endif

private struct ChatScrollGeometry: Equatable {
    let isNearBottom: Bool
    let containerHeight: CGFloat
    let bottomInset: CGFloat
    let contentHeight: CGFloat
}

private enum ChatRowIdentity: Hashable {
    case message(String)
    case messageChunk(String, Int)
    case item(String)
    case approval(String)
    case unknown(String)
}

private extension TimelineEntry {
    var chatIdentity: ChatRowIdentity {
        if let message { return .message(message.id) }
        if let item { return .item(item.id) }
        if let approval { return .approval(approval.requestID) }
        return .unknown(kind)
    }
}

private struct ChatTimelineRow: View {
    let entry: TimelineEntry
    let messagePresentation: ChatMarkdownPresentation
    let threadID: String
    let store: ThreadStore

    var body: some View {
        // Single-root container keeps the row unary so List can template row
        // identity without evaluating every row's body.
        VStack(alignment: .leading, spacing: 0) {
            switch entry.entryKind {
            case .message:
                if let message = entry.message {
                    ChatMessageRow(
                        messageID: message.id,
                        text: message.text,
                        role: message.role,
                        attachments: message.attachments,
                        presentation: messagePresentation
                    )
                }
            case .item:
                if let item = entry.item {
                    ChatItemRow(item: item, threadID: threadID, store: store)
                }
            case .approval:
                if let approval = entry.approval {
                    ChatApprovalRow(approval: approval, threadID: threadID, store: store)
                }
            case nil:
                Label("Unsupported timeline entry", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct ChatMessageRow: View {
    let messageID: String
    let text: String
    let role: String
    let attachments: [Attachment]?
    let presentation: ChatMarkdownPresentation

    var body: some View {
        VStack(alignment: .leading) {
            if !text.isEmpty {
                ChatMarkdownMessageView(
                    messageID: messageID,
                    source: text,
                    presentation: presentation
                )
            }

            if let attachments, !attachments.isEmpty {
                Text(attachments.map { $0.name ?? $0.kind }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, role == MaidMessageRole.user.rawValue ? 14 : 0)
        .padding(.vertical, role == MaidMessageRole.user.rawValue ? 10 : 0)
        .background(
            role == MaidMessageRole.user.rawValue
                ? Color.accentColor.opacity(0.15) : Color.clear,
            in: .rect(cornerRadius: 18)
        )
        .frame(
            maxWidth: .infinity,
            alignment: role == MaidMessageRole.user.rawValue ? .trailing : .leading
        )
    }
}

private struct ChatItemRow: View {
    let item: Item
    let threadID: String
    let store: ThreadStore

    @State private var isExpanded = false
    @State private var detail: Item?
    @State private var isLoadingDetail = false
    @State private var detailErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Label(
                    item.title ?? ChatTimelineText.humanized(item.kind),
                    systemImage: iconName
                )
                .bold()

                Spacer()

                Text(ChatTimelineText.humanized(item.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let summary = item.toolCallSummary {
                ChatToolSummaryView(summary: summary)
            } else if let toolCall = item.toolCall {
                if let changes = toolCall.changes, !changes.isEmpty {
                    UnifiedDiffLauncherView(changes: changes)
                } else if let text = ChatTimelineText.encoded(toolCall) {
                    Text(ChatTimelineText.preview(text))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }

            if let payload = item.payload {
                Text(ChatTimelineText.preview(ChatTimelineText.encoded(payload.value)))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }

            if item.detailAvailable == true {
                Button(
                    isExpanded ? "Hide details" : "Show details",
                    systemImage: isExpanded ? "chevron.up" : "chevron.down"
                ) {
                    isExpanded.toggle()
                    if isExpanded, detail == nil {
                        Task { await loadDetail() }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                if isExpanded {
                    ChatItemDetailView(
                        detail: detail,
                        isLoading: isLoadingDetail,
                        errorMessage: detailErrorMessage
                    ) {
                        Task { await loadDetail() }
                    }
                }
            }
        }
        .padding()
        .background(backgroundStyle, in: .rect(cornerRadius: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: item.sequence) { _, _ in
            itemDidUpdate()
        }
        .onChange(of: item.updatedAt) { _, _ in
            guard item.sequence == nil else { return }
            itemDidUpdate()
        }
    }

    private func itemDidUpdate() {
        guard detail != nil else { return }
        detail = nil
        detailErrorMessage = nil
        if isExpanded, item.itemStatus != .inProgress {
            Task { await loadDetail() }
        }
    }

    private func loadDetail() async {
        guard !isLoadingDetail else { return }
        isLoadingDetail = true
        detailErrorMessage = nil
        defer { isLoadingDetail = false }
        do {
            detail = try await store.itemDetail(threadID: threadID, item: item)
        } catch {
            detailErrorMessage = error.localizedDescription
        }
    }

    private var iconName: String {
        switch item.itemKind {
        case .userMessage, .assistantMessage: "bubble.left"
        case .reasoning: "brain"
        case .commandExecution: "terminal"
        case .fileChange: "doc.badge.gearshape"
        case .mcpToolCall, .toolCall: "wrench.and.screwdriver"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        case nil: "gearshape"
        }
    }

    private var backgroundStyle: Color {
        switch item.itemKind {
        case .warning: .orange.opacity(0.12)
        case .error: .red.opacity(0.12)
        default: .secondary.opacity(0.08)
        }
    }
}

private struct ChatToolSummaryView: View {
    let summary: ToolCallSummary

    var body: some View {
        VStack(alignment: .leading) {
            if let command = summary.commandPreview, !command.isEmpty {
                Text(command)
                    .font(.callout.monospaced())
                    .lineLimit(2)
            }
            if let query = summary.queryPreview, !query.isEmpty {
                Text(query)
                    .font(.callout)
                    .lineLimit(2)
            }
            if let changes = summary.changes, !changes.isEmpty {
                Label(
                    summarizedValues(
                        changes.map(\.path),
                        totalCount: summary.changeCount
                    ),
                    systemImage: "doc.on.doc"
                )
                .lineLimit(2)
            }
            if let locations = summary.locations, !locations.isEmpty {
                Label(
                    summarizedValues(
                        locations.map(\.path),
                        totalCount: summary.locationCount
                    ),
                    systemImage: "mappin.and.ellipse"
                )
                .lineLimit(2)
            }
            if let attachments = summary.attachments, !attachments.isEmpty {
                Label(
                    summarizedValues(
                        attachments.map { $0.name ?? $0.kind },
                        totalCount: summary.attachmentCount
                    ),
                    systemImage: "paperclip"
                )
                .lineLimit(2)
            }
            if let output = summary.outputPreview, !output.isEmpty {
                Text(output)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if let error = summary.errorPreview, !error.isEmpty {
                Text(error)
                    .font(.callout.monospaced())
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func summarizedValues(_ values: [String], totalCount: Int?) -> String {
        let displayed = values.joined(separator: " · ")
        let omitted = max(0, (totalCount ?? values.count) - values.count)
        return omitted == 0 ? displayed : "\(displayed) · +\(omitted)"
    }
}

private struct ChatItemDetailView: View {
    let detail: Item?
    let isLoading: Bool
    let errorMessage: String?
    let retry: () -> Void

    var body: some View {
        Group {
            if let detail {
                if let toolCall = detail.toolCall {
                    ChatToolDetailContent(toolCall: toolCall)
                } else if let payload = detail.payload {
                    ChatDetailTextBlock(
                        title: "Details",
                        text: ChatTimelineText.encoded(payload.value)
                    )
                }
            } else if isLoading {
                ProgressView("Loading details…")
                    .controlSize(.small)
            } else if let errorMessage {
                VStack(alignment: .leading) {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Retry", systemImage: "arrow.clockwise", action: retry)
                }
            }
        }
    }
}

private struct ChatToolDetailContent: View {
    let toolCall: ToolCall

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let command = toolCall.command, !command.isEmpty {
                ChatDetailTextBlock(title: "Command", text: command)
            }
            if let query = toolCall.query, !query.isEmpty {
                ChatDetailTextBlock(title: "Query", text: query)
            }
            if let cwd = toolCall.cwd, !cwd.isEmpty {
                ChatDetailValue(title: "Working directory", value: cwd)
            }
            if let output = toolCall.output, !output.isEmpty {
                ChatDetailTextBlock(title: "Output", text: output)
            }
            if let error = toolCall.error, !error.isEmpty {
                ChatDetailTextBlock(title: "Error", text: error, isError: true)
            }
            if let changes = toolCall.changes, !changes.isEmpty {
                UnifiedDiffLauncherView(changes: changes)
            }
            if let locations = toolCall.locations, !locations.isEmpty {
                ChatDetailValue(
                    title: "Locations",
                    value: locations.map { location in
                        location.line.map { "\(location.path):\($0)" } ?? location.path
                    }.joined(separator: "\n")
                )
            }
            if let attachments = toolCall.attachments, !attachments.isEmpty {
                ChatDetailValue(
                    title: "Attachments",
                    value: attachments.map(attachmentDescription).joined(separator: "\n")
                )
            }
            if let metadata, !metadata.isEmpty {
                ChatDetailValue(title: "Result", value: metadata.joined(separator: " · "))
            }
        }
    }

    private var metadata: [String]? {
        var values: [String] = []
        if let exitCode = toolCall.exitCode {
            values.append("Exit \(exitCode)")
        }
        if let duration = toolCall.durationMilliseconds {
            values.append("\(duration) ms")
        }
        if let name = toolCall.name, !name.isEmpty {
            let qualifiedName = toolCall.namespace.map { "\($0).\(name)" } ?? name
            values.append(qualifiedName)
        } else if let providerKind = toolCall.providerKind, !providerKind.isEmpty {
            values.append(providerKind)
        }
        return values.isEmpty ? nil : values
    }

    private func attachmentDescription(_ attachment: Attachment) -> String {
        var description = attachment.name ?? attachment.uri ?? attachment.kind
        if let mimeType = attachment.mimeType, !mimeType.isEmpty {
            description += " · \(mimeType)"
        }
        if let data = attachment.data, !data.isEmpty {
            description += " · embedded data omitted"
        }
        return description
    }
}

private struct ChatDetailValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
    }
}

private struct ChatDetailTextBlock: View {
    private static let maximumCharacters = 8_000

    let title: String
    let text: String
    var isError = false

    private var projectedText: (preview: String, isTruncated: Bool) {
        guard let end = text.index(
            text.startIndex,
            offsetBy: Self.maximumCharacters,
            limitedBy: text.endIndex
        ) else {
            return (text, false)
        }
        return (String(text[..<end]), end != text.endIndex)
    }

    var body: some View {
        let projectedText = projectedText

        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(projectedText.preview)
                .font(.callout.monospaced())
                .foregroundStyle(isError ? .red : .primary)
                .textSelection(.enabled)
            if projectedText.isTruncated {
                Text(
                    "Inline preview limited to \(Self.maximumCharacters.formatted()) characters"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ChatApprovalRow: View {
    let approval: Approval
    let threadID: String
    let store: ThreadStore

    @State private var isResponding = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading) {
            Label("Permission needed", systemImage: "hand.raised")
                .bold()

            if let args = approval.args {
                Text(ChatTimelineText.encoded(args.value))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }

            if approval.approvalStatus == .pending {
                HStack {
                    if let options = approval.options, !options.isEmpty {
                        ForEach(options, id: \.optionID) { option in
                            Button(option.name) {
                                respond(
                                    decision: decision(for: option),
                                    optionID: option.optionID
                                )
                            }
                            .disabled(isResponding)
                        }
                    } else {
                        Button("Decline", role: .destructive) {
                            respond(decision: .decline, optionID: nil)
                        }
                        .disabled(isResponding)

                        Button("Allow") {
                            respond(decision: .accept, optionID: nil)
                        }
                        .disabled(isResponding)
                    }
                }
            } else {
                Text(approval.decision.map(ChatTimelineText.humanized) ?? "Resolved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func decision(for option: ApprovalOption) -> MaidApprovalDecision {
        switch option.kind {
        case "allow_always": .acceptForSession
        case "reject_once", "reject_always": .decline
        default: .accept
        }
    }

    private func respond(decision: MaidApprovalDecision, optionID: String?) {
        guard !isResponding else { return }
        isResponding = true
        errorMessage = nil
        Task {
            defer { isResponding = false }
            do {
                try await store.respondToApproval(
                    threadID: threadID,
                    requestID: approval.requestID,
                    decision: decision,
                    optionID: optionID
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct ChatPlanRow: View {
    let plan: Plan

    var body: some View {
        VStack(alignment: .leading) {
            Label("Plan", systemImage: "checklist")
                .bold()

            // Index identity is deliberate: PlanEntry has no stable unique
            // key (content can repeat) and plans are replaced wholesale.
            ForEach(plan.entries.indices, id: \.self) { index in
                let entry = plan.entries[index]
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: entry.status == "completed" ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(entry.status == "completed" ? .green : .secondary)
                    Text(entry.content)
                    Spacer()
                    if let status = entry.status {
                        Text(ChatTimelineText.humanized(status))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(.secondary.opacity(0.08), in: .rect(cornerRadius: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum ChatTimelineText {
    /// Inline item rows cap payload previews so a huge tool result cannot
    /// become an unbounded list row; the expandable detail view shows more.
    static let maximumInlinePreviewCharacters = 4_000

    static func humanized(_ value: String) -> String {
        value.replacing("_", with: " ").replacing("-", with: " ").capitalized
    }

    static func preview(_ text: String) -> String {
        guard
            let end = text.index(
                text.startIndex,
                offsetBy: maximumInlinePreviewCharacters,
                limitedBy: text.endIndex
            ),
            end < text.endIndex
        else {
            return text
        }
        return String(text[..<end]) + "…"
    }

    static func encoded<T: Encodable>(_ value: T) -> String? {
        guard let data = try? newJSONEncoder().encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func encoded(_ value: Any) -> String {
        if let string = value as? String { return string }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct ChatEndMarker: View {
    var body: some View {
        Color.clear
            .frame(height: 24)
            .allowsHitTesting(false)
    }
}

private struct ChatScrollToBottomButton: View {
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
                .modifier(ChatScrollButtonStyle())
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy, value: scrollState.isNearBottom)
    }
}

private struct ChatScrollButtonStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content
                .background(.regularMaterial, in: .circle)
                .buttonStyle(.plain)
        }
    }
}

/// A panel of queued prompts whose bottom edge tucks behind the composer so
/// the two read as one connected surface.
private struct ChatPromptQueueView: View {
    let model: ChatPromptModel

    /// Matches the composer's corner radius; the panel extends this far
    /// beneath the composer to close the gap left by its rounded corners.
    private let composerOverlap: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            ForEach(model.queuedPrompts) { prompt in
                QueuedPromptRow(
                    model: model,
                    promptID: prompt.id,
                    text: prompt.text,
                    attachmentCount: prompt.attachments.count
                )
            }
        }
        .padding(.bottom, composerOverlap)
        .background(
            .regularMaterial,
            in: .rect(topLeadingRadius: 20, topTrailingRadius: 20)
        )
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.bottom, -composerOverlap)
    }
}

/// Stores only the fields it renders — never the full queued prompt, whose
/// attachments carry base64 payloads that would be deep-compared per update.
private struct QueuedPromptRow: View {
    let model: ChatPromptModel
    let promptID: String
    let text: String
    let attachmentCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.turn.down.right")
                .foregroundStyle(.secondary)

            Text(text.isEmpty
                ? "\(attachmentCount) attachment(s)"
                : text)
                .lineLimit(1)

            Spacer()

            Button("Steer", systemImage: "arrow.triangle.branch") {
                Task { await model.steerQueuedPrompt(promptID) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button("Remove queued prompt", systemImage: "trash") {
                model.removeQueuedPrompt(promptID)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct ThreadLoadErrorView: View {
    let store: ThreadStore
    let errorMessage: String

    var body: some View {
        ContentUnavailableView {
            Label("Unable to Load Thread", systemImage: "exclamationmark.triangle")
        } description: {
            Text(errorMessage)
        } actions: {
            Button("Retry") {
                store.retry()
            }
        }
    }
}

#if DEBUG
    #Preview("Selected Chat") {
        NavigationStack {
            ChatView(
                store: PreviewData.threadStore(),
                draftStore: ThreadDraftStore()
            )
        }
    }

    #Preview("Draft Chat") {
        ChatView(
            store: ThreadStore(previewThreads: PreviewData.threads),
            draftStore: ThreadDraftStore()
        )
    }
#endif
