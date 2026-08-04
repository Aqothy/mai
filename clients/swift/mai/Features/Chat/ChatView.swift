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
                    latestTurn: thread.latestTurn,
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

/// Keeps one composer identity across draft-to-thread transitions.
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
                focusID: chatModel == nil ? draftModel.promptFocusID : nil,
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

/// Expanded/collapsed turn sections. A reference type so rows can toggle the
/// fold without closure or binding inputs defeating row-level invalidation.
@Observable
final class ChatTimelineFoldModel {
    private(set) var expandedSectionIDs: Set<String> = []

    func toggle(_ sectionID: String) {
        // No animation: List rows animating height changes overlap badly.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            expandedSectionIDs.formSymmetricDifference([sectionID])
        }
    }
}

nonisolated enum ChatTimelineMetrics {
    static let rowHorizontalInset: CGFloat = 16
    static let userBubbleHorizontalPadding: CGFloat = 14
    static let userBubbleVerticalPadding: CGFloat = 10
    static let interSegmentSpacing: CGFloat = 8

    #if os(iOS)
        static func textWidth(
            for style: ChatTextLayoutStyle,
            in rowWidth: CGFloat
        ) -> CGFloat {
            switch style {
            case .markdownProse:
                rowWidth
            case .plain:
                max(0, rowWidth - 2 * userBubbleHorizontalPadding)
            }
        }
    #endif
}

private struct ChatTimeline: View {
    static let nearBottomDistance: CGFloat = 24

    let threadID: String
    let timeline: [TimelineEntry]
    let plan: Plan?
    let latestTurn: Turn?
    let streamingTurnID: String?
    let store: ThreadStore
    let scrollState: ChatScrollState

    @State private var foldModel = ChatTimelineFoldModel()
    @State private var segmentCache = ChatMarkdownSegmentCache()

    #if os(iOS)
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        @State private var textLayoutStore = ChatTextLayoutStore()
        @State private var textWarmRowWidth: CGFloat = 0
    #endif

    var body: some View {
        let rows = renderRows(
            ChatTimelineLayout.rows(
                timeline: timeline,
                streamingTurnID: streamingTurnID,
                latestTurn: latestTurn,
                expandedSectionIDs: foldModel.expandedSectionIDs
            )
        )

        ScrollViewReader { proxy in
            List {
                if let plan, !plan.entries.isEmpty {
                    ChatPlanRow(plan: plan)
                        .padding(.vertical, 10)
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

                ForEach(rows) { row in
                    #if os(iOS)
                        ChatTimelineRenderRowView(
                            row: row,
                            streamingTurnID: streamingTurnID,
                            threadID: threadID,
                            store: store,
                            foldModel: foldModel,
                            scrollState: scrollState,
                            textLayoutStore: textLayoutStore
                        )
                    #else
                        ChatTimelineRenderRowView(
                            row: row,
                            streamingTurnID: streamingTurnID,
                            threadID: threadID,
                            store: store,
                            foldModel: foldModel,
                            scrollState: scrollState
                        )
                    #endif
                }

                if streamingTurnID != nil {
                    ChatWorkingIndicator(activityKey: rows.last?.id)
                        .padding(.vertical, 10)
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
                // A row's content width is the list width minus 16pt insets
                // on each side. Warm every settled prose segment at that
                // exact width before List needs to realize it while scrolling.
                .onGeometryChange(for: CGFloat.self) { geometry in
                    max(
                        0,
                        geometry.size.width
                            - 2 * ChatTimelineMetrics.rowHorizontalInset
                    )
                } action: { width in
                    textWarmRowWidth = width
                    warmTextLayouts(in: rows, rowWidth: width)
                }
                .onChange(of: timeline.count) { _, _ in
                    warmTextLayouts(in: rows, rowWidth: textWarmRowWidth)
                }
                .onChange(of: streamingTurnID) { _, _ in
                    warmTextLayouts(in: rows, rowWidth: textWarmRowWidth)
                }
                .onChange(of: foldModel.expandedSectionIDs) { _, _ in
                    warmTextLayouts(in: rows, rowWidth: textWarmRowWidth)
                }
                .onChange(of: dynamicTypeSize) { _, _ in
                    // Fonts are baked into each layout. Swapping the small
                    // per-timeline store gives visible representables a new
                    // dependency and guarantees they remeasure immediately.
                    textLayoutStore = ChatTextLayoutStore()
                    warmTextLayouts(in: rows, rowWidth: textWarmRowWidth)
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
                // Pin after layout so content growth uses the final size.
                // Expansion toggles call noteContentExpansion() first, which
                // drops shouldFollowBottom so this pin cannot fire for them.
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

    /// Expands only settled oversized assistant messages. Streaming keeps its
    /// stable incremental MarkdownView lifecycle; short and uncommon
    /// document-wide Markdown features keep the existing static renderer.
    private func renderRows(
        _ rows: [ChatTimelineRowModel]
    ) -> [ChatTimelineRenderRow] {
        #if !os(iOS)
            return rows.map(ChatTimelineRenderRow.standard)
        #else
            return rows.flatMap { row -> [ChatTimelineRenderRow] in
                guard case .message(let message) = row else {
                    return [.standard(row)]
                }

                let plan = ChatMessageTextPlanner.plan(
                    messageID: message.id,
                    role: message.role,
                    messageTurnID: message.turnID,
                    streamingTurnID: streamingTurnID,
                    source: message.text,
                    segmentCache: segmentCache
                )
                switch plan {
                case .existingRenderer:
                    return [.standard(row)]

                case .plainText:
                    return [
                        .plainText(
                            ChatMessageSegmentRowModel(
                                messageID: message.id,
                                index: 0,
                                source: message.text,
                                role: message.role,
                                attachments: message.attachments,
                                isFirst: true,
                                isLast: true
                            )
                        )
                    ]

                case .segmented(let segments):
                    return segments.indices.map { index in
                        let segment = segments[index]
                        let model = ChatMessageSegmentRowModel(
                            messageID: message.id,
                            index: index,
                            source: segment.source,
                            role: message.role,
                            attachments: index == segments.count - 1
                                ? message.attachments
                                : nil,
                            isFirst: index == 0,
                            isLast: index == segments.count - 1
                        )
                        return segment.kind == .prose
                            ? .prose(model)
                            : .richMarkdown(model)
                    }
                }
            }
        #endif
    }

    #if os(iOS)
        private func warmTextLayouts(
            in rows: [ChatTimelineRenderRow],
            rowWidth: CGFloat
        ) {
            let requests = rows.suffix(ChatTextLayoutStore.capacity).compactMap {
                row -> ChatTextLayoutRequest? in
                switch row {
                case .prose(let segment):
                    ChatTextLayoutRequest(
                        id: segment.rowID,
                        source: segment.source,
                        style: .markdownProse,
                        width: ChatTimelineMetrics.textWidth(
                            for: .markdownProse,
                            in: rowWidth
                        )
                    )
                case .plainText(let message):
                    ChatTextLayoutRequest(
                        id: message.rowID,
                        source: message.source,
                        style: .plain,
                        width: ChatTimelineMetrics.textWidth(
                            for: .plain,
                            in: rowWidth
                        )
                    )
                case .standard, .richMarkdown:
                    nil
                }
            }
            textLayoutStore.warm(requests: requests)
        }
    #endif
}

private enum ChatTimelineRenderRow: Identifiable {
    case standard(ChatTimelineRowModel)
    case richMarkdown(ChatMessageSegmentRowModel)
    case prose(ChatMessageSegmentRowModel)
    case plainText(ChatMessageSegmentRowModel)

    var id: String {
        switch self {
        case .standard(let row): row.id
        case .richMarkdown(let segment): "\(segment.rowID)-rich"
        case .prose(let segment): "\(segment.rowID)-prose"
        case .plainText(let message): "\(message.rowID)-plain"
        }
    }
}

/// A single concrete row shape lets List derive every row identity without
/// evaluating the case-specific body for the entire transcript.
private struct ChatTimelineRenderRowView: View {
    let row: ChatTimelineRenderRow
    let streamingTurnID: String?
    let threadID: String
    let store: ThreadStore
    let foldModel: ChatTimelineFoldModel
    let scrollState: ChatScrollState
    #if os(iOS)
        let textLayoutStore: ChatTextLayoutStore
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch row {
            case .standard(let model):
                ChatTimelineRow(
                    row: model,
                    streamingTurnID: streamingTurnID,
                    threadID: threadID,
                    store: store,
                    foldModel: foldModel,
                    scrollState: scrollState
                )

            case .richMarkdown(let segment):
                ChatMessageRow(
                    messageID: segment.rowID,
                    text: segment.source,
                    role: segment.role,
                    attachments: segment.attachments,
                    presentation: ChatMarkdownPresentation(isStreaming: false)
                )
                .padding(.top, segment.isFirst ? 10 : 0)
                .padding(
                    .bottom,
                    segment.isLast ? 10 : ChatTimelineMetrics.interSegmentSpacing
                )

            case .prose(let segment):
                #if os(iOS)
                    ChatNativeTextMessageRow(
                        segment: segment,
                        style: .markdownProse,
                        layoutStore: textLayoutStore
                    )
                    .padding(.top, segment.isFirst ? 10 : 0)
                    .padding(
                        .bottom,
                        segment.isLast ? 10 : ChatTimelineMetrics.interSegmentSpacing
                    )
                #endif

            case .plainText(let message):
                #if os(iOS)
                    ChatNativeTextMessageRow(
                        segment: message,
                        style: .plain,
                        layoutStore: textLayoutStore
                    )
                    .padding(.vertical, 10)
                #endif
            }
        }
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

private struct ChatMessageSegmentRowModel {
    let messageID: String
    let index: Int
    let source: String
    let role: String
    let attachments: [Attachment]?
    let isFirst: Bool
    let isLast: Bool

    var rowID: String { "\(messageID)#segment-\(index)" }
}

#if os(iOS)
    private struct ChatNativeTextMessageRow: View {
        let segment: ChatMessageSegmentRowModel
        let style: ChatTextLayoutStyle
        let layoutStore: ChatTextLayoutStore

        var body: some View {
            VStack(alignment: .leading) {
                ChatSelectableText(
                    layoutID: segment.rowID,
                    source: segment.source,
                    style: style,
                    layoutStore: layoutStore
                )

                if let attachments = segment.attachments, !attachments.isEmpty {
                    Text(
                        attachments.map { $0.name ?? $0.kind }
                            .joined(separator: " · ")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(
                .horizontal,
                isUserMessage ? ChatTimelineMetrics.userBubbleHorizontalPadding : 0
            )
            .padding(
                .vertical,
                isUserMessage ? ChatTimelineMetrics.userBubbleVerticalPadding : 0
            )
            .background(
                isUserMessage ? Color.accentColor.opacity(0.15) : Color.clear,
                in: .rect(cornerRadius: 18)
            )
            .frame(
                maxWidth: .infinity,
                alignment: isUserMessage ? .trailing : .leading
            )
        }

        private var isUserMessage: Bool {
            segment.role == MaidMessageRole.user.rawValue
        }
    }
#endif

private struct ChatScrollGeometry: Equatable {
    let isNearBottom: Bool
    let containerHeight: CGFloat
    let bottomInset: CGFloat
    let contentHeight: CGFloat
}

private struct ChatTimelineRow: View {
    let row: ChatTimelineRowModel
    let streamingTurnID: String?
    let threadID: String
    let store: ThreadStore
    let foldModel: ChatTimelineFoldModel
    let scrollState: ChatScrollState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch row {
            case .message(let message):
                ChatMessageRow(
                    messageID: message.id,
                    text: message.text,
                    role: message.role,
                    attachments: message.attachments,
                    presentation: ChatMarkdownPresentation.timelineMessage(
                        role: message.role,
                        turnID: message.turnID,
                        streamingTurnID: streamingTurnID
                    )
                )
                .padding(.vertical, 10)
            case .thought(let item):
                ChatThoughtRow(item: item, scrollState: scrollState)
            case .turnActivity(let activity):
                ChatTurnActivityRow(
                    activity: activity,
                    foldModel: foldModel,
                    scrollState: scrollState
                )
            case .activityGroup(let group):
                // A lone step needs no group wrapper: one tap reaches it.
                if group.items.count == 1, let item = group.items.first {
                    ChatActivityItemRow(
                        item: item,
                        threadID: threadID,
                        store: store,
                        scrollState: scrollState
                    )
                    .padding(.vertical, 4)
                } else {
                    ChatActivityGroupRow(
                        group: group,
                        threadID: threadID,
                        store: store,
                        scrollState: scrollState
                    )
                }
            case .notice(let item):
                ChatNoticeRow(item: item)
            case .approval(let approval):
                ChatApprovalRow(approval: approval, threadID: threadID, store: store)
                    .padding(.vertical, 10)
            }
        }
    }
}

/// The model's reasoning behind a "Thought" disclosure — open while the
/// thought streams, folding on its own once the item settles.
/// Rendered with Foundation's inline Markdown parsing rather than the
/// MarkdownView renderer: inline attributes (bold section titles, code
/// spans) apply on top of the row's own font and dimmed secondary color,
/// which the renderer's document styling would override.
private struct ChatThoughtRow: View {
    let item: Item
    let scrollState: ChatScrollState

    @State private var isExpandedOverride: Bool?

    var body: some View {
        if let text = ChatTimelineLayout.reasoningText(item) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    scrollState.noteContentExpansion()
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        isExpandedOverride = !isExpanded
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "brain")
                            .font(.caption)
                            .frame(width: 16)

                        ChatActivityGroupRow.itemLineText(item)

                        Image(
                            systemName: isExpanded
                                ? "chevron.down" : "chevron.right"
                        )
                        .font(.caption2.weight(.semibold))
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isExpanded ? "Hide thought" : "Show thought"
                )

                if isExpanded {
                    Text(Self.attributed(text))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Streams stay readable live; a settled thought folds unless the user
    /// has toggled it themselves.
    private var isExpanded: Bool {
        isExpandedOverride ?? (item.itemStatus == .inProgress)
    }

    private static func attributed(_ text: String) -> AttributedString {
        guard let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return AttributedString(text)
        }
        return parsed
    }
}

/// The turn's work header. While the turn runs it is a live elapsed timer;
/// once finished it becomes the "Worked for 42s" disclosure that folds and
/// unfolds the turn's activity.
private struct ChatTurnActivityRow: View {
    let activity: ChatTurnActivity
    let foldModel: ChatTimelineFoldModel
    let scrollState: ChatScrollState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if activity.isRunning {
                    Text("Working")
                    if let startedAt = activity.startedAt {
                        Text(startedAt, style: .timer)
                            .monospacedDigit()
                    }
                } else {
                    Button {
                        scrollState.noteContentExpansion()
                        foldModel.toggle(activity.sectionID)
                    } label: {
                        HStack(spacing: 6) {
                            Text(activity.title)

                            if activity.hasFailure {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }

                            Image(
                                systemName: activity.isExpanded
                                    ? "chevron.down" : "chevron.right"
                            )
                            .font(.caption2.weight(.semibold))
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        activity.isExpanded
                            ? "Hide agent activity, \(activity.title)"
                            : "Show agent activity, \(activity.title)"
                    )
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Divider()
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

/// One compact line summarizing a run of consecutive activity items, e.g.
/// "Read 2 files, ran a command". Tapping reveals the individual steps.
private struct ChatActivityGroupRow: View {
    let group: ChatActivityGroup
    let threadID: String
    let store: ThreadStore
    let scrollState: ChatScrollState

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                scrollState.noteContentExpansion()
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: Self.iconName(for: group.items.first))
                        .font(.caption)
                        .frame(width: 16)
                        .foregroundStyle(
                            group.hasFailure
                                ? AnyShapeStyle(.red)
                                : AnyShapeStyle(.secondary)
                        )

                    summaryText
                        .lineLimit(1)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(group.items, id: \.id) { item in
                        ChatActivityItemRow(
                            item: item,
                            threadID: threadID,
                            store: store,
                            scrollState: scrollState
                        )
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryText: Text {
        Text(group.summary)
    }

    /// A single-step group shows its specific work instead of an aggregate.
    static func singleItemText(_ item: Item, fallback: String) -> Text {
        let summary = item.toolCallSummary
        switch ChatActivityVerb(item: item) {
        case .ranCommand:
            if let command = summary?.commandPreview, !command.isEmpty {
                return Text("Ran ") + monospaced(command)
            }
        case .thought:
            let seconds = item.updatedAt.timeIntervalSince(item.createdAt)
            if seconds >= 1 {
                return Text("Thought for \(ChatTurnActivity.formatted(.seconds(seconds)))")
            }
            return Text("Thought")
        case .read:
            if let path = summary?.locations?.first?.path, !path.isEmpty {
                return Text("Read ") + monospaced(lastPathComponent(path))
            }
        case .edited:
            if let path = summary?.changes?.first?.path, !path.isEmpty {
                let extra = max(0, (summary?.changeCount ?? 1) - 1)
                let suffix = extra > 0 ? " +\(extra)" : ""
                return Text("Edited ") + monospaced(lastPathComponent(path)) + Text(suffix)
            }
        case .searched:
            if let query = summary?.queryPreview, !query.isEmpty {
                return Text("Searched ") + monospaced(query)
            }
        case .fetched, .tool:
            break
        }
        if let title = item.title, !title.isEmpty {
            return Text(title)
        }
        return Text(fallback)
    }

    /// The one-line label for a step, shared by the group summary and the
    /// expanded per-step rows so both read identically.
    static func itemLineText(_ item: Item) -> Text {
        singleItemText(
            item,
            fallback: ChatActivityVerb(item: item)
                .phrase(count: 1, toolName: item.toolCallSummary?.name)
                .capitalizedFirst
        )
    }

    private static func monospaced(_ value: String) -> Text {
        Text(value).font(.callout.monospaced())
    }

    private static func lastPathComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    static func iconName(for item: Item?) -> String {
        guard let item else { return "circle.dashed" }
        return switch ChatActivityVerb(item: item) {
        case .thought: "brain"
        case .read: "book"
        case .searched: "magnifyingglass"
        case .edited: "pencil"
        case .ranCommand: "terminal"
        case .fetched: "globe"
        case .tool: "wrench.and.screwdriver"
        }
    }
}

/// A single step inside an expanded activity group, in the same compact
/// one-line style as the group row. Steps with output expand into a small
/// box; file edits open the diff viewer directly; steps with nothing more to
/// show are plain text, not buttons.
private struct ChatActivityItemRow: View {
    let item: Item
    let threadID: String
    let store: ThreadStore
    let scrollState: ChatScrollState

    @State private var isExpanded = false
    // Captured at presentation: `detail` is cleared whenever the item
    // updates, and an open sheet must not lose its content to that.
    @State private var presentedChanges: [FileChange]?
    @State private var detail: Item?
    @State private var isLoadingDetail = false
    @State private var detailErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isFileChangeStep || hasExpandableContent {
                Button {
                    if isFileChangeStep {
                        Task { await openDiff() }
                    } else {
                        scrollState.noteContentExpansion()
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { isExpanded.toggle() }
                        if isExpanded, detail == nil, item.detailAvailable == true {
                            Task { await loadDetail() }
                        }
                    }
                } label: {
                    lineLabel
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            } else {
                lineLabel
            }

            if isExpanded, hasExpandableContent || detailErrorMessage != nil {
                expandedContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(
            isPresented: Binding(
                get: { presentedChanges != nil },
                set: { if !$0 { presentedChanges = nil } }
            )
        ) {
            ChatStepDiffSheet(changes: presentedChanges ?? [])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: item.sequence) { _, _ in
            itemDidUpdate()
        }
        .onChange(of: item.updatedAt) { _, _ in
            guard item.sequence == nil else { return }
            itemDidUpdate()
        }
    }

    private var lineLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: ChatActivityGroupRow.iconName(for: item))
                .font(.caption)
                .frame(width: 16)
                .foregroundStyle(
                    item.itemStatus == .failed
                        ? AnyShapeStyle(.red)
                        : AnyShapeStyle(.secondary)
                )

            ChatActivityGroupRow.itemLineText(item)
                .lineLimit(1)

            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(item.itemStatus == .failed ? .red : .secondary)
            }

            if isFileChangeStep || hasExpandableContent {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var expandedContent: some View {
        if let detailErrorMessage {
            HStack(spacing: 10) {
                Text(detailErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Retry", systemImage: "arrow.clockwise") {
                    Task { await loadDetail() }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        } else {
            // Summary previews render instantly; the fetched detail replaces
            // them in place, so expansion never flashes a loading state.
            ChatStepOutputBox(
                command: toolCall?.command ?? summary?.commandPreview,
                query: toolCall?.query ?? summary?.queryPreview,
                output: toolCall?.output ?? summary?.outputPreview,
                error: toolCall?.error ?? summary?.errorPreview,
                metadata: metadata
            )
        }
    }

    private var summary: ToolCallSummary? { item.toolCallSummary }
    private var toolCall: ToolCall? { detail?.toolCall }

    private var isFileChangeStep: Bool {
        ChatActivityVerb(item: item) == .edited
    }

    /// Expandable only when there is genuinely more to show; a bare read
    /// with no output would otherwise expand into an empty box.
    private var hasExpandableContent: Bool {
        summary?.commandPreview != nil
            || summary?.queryPreview != nil
            || summary?.outputPreview != nil
            || summary?.errorPreview != nil
    }

    private func openDiff() async {
        if detail == nil {
            await loadDetail()
        }
        if let changes = detail?.toolCall?.changes, !changes.isEmpty {
            presentedChanges = changes
        } else if hasExpandableContent || detailErrorMessage != nil {
            // No structured diff came back; fall back to whatever the step
            // can show instead of silently doing nothing.
            isExpanded = true
        }
    }

    private var statusText: String? {
        switch item.itemStatus {
        case .failed, .interrupted, .declined:
            item.itemStatus.map { ChatTimelineText.humanized($0.rawValue) }
        case .completed, .inProgress, nil:
            nil
        }
    }

    private var metadata: String? {
        var values: [String] = []
        let exitCode = toolCall?.exitCode ?? summary?.exitCode
        if let exitCode, exitCode != 0 {
            values.append("Exit \(exitCode)")
        }
        let duration = toolCall?.durationMilliseconds ?? summary?.durationMilliseconds
        if let duration, duration >= 100 {
            values.append("\(duration) ms")
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
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
}

/// The rounded output panel under an expanded step: command, output, and
/// error in monospaced text.
private struct ChatStepOutputBox: View {
    private static let maximumCharacters = 4_000

    let command: String?
    let query: String?
    let output: String?
    let error: String?
    let metadata: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let command, !command.isEmpty {
                monospacedText("$ " + command, style: .primary)
            }
            if let query, !query.isEmpty {
                Text(query)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            if let output, !output.isEmpty {
                monospacedText(output, style: .secondary)
            }
            if let error, !error.isEmpty {
                monospacedText(error, style: .red)
            }
            if let metadata {
                Text(metadata)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.secondary.opacity(0.08), in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private func monospacedText(_ text: String, style: some ShapeStyle) -> some View {
        let (preview, isTruncated) = truncated(text)
        Text(preview)
            .font(.caption.monospaced())
            .foregroundStyle(style)
            .textSelection(.enabled)
        if isTruncated {
            Text("Preview truncated")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func truncated(_ text: String) -> (String, Bool) {
        guard let end = text.index(
            text.startIndex,
            offsetBy: Self.maximumCharacters,
            limitedBy: text.endIndex
        ) else {
            return (text, false)
        }
        return (String(text[..<end]), end != text.endIndex)
    }
}

/// Presents a tool step's captured file changes in the shared diff viewer.
private struct ChatStepDiffSheet: View {
    let changes: [FileChange]

    var body: some View {
        UnifiedDiffView(changes: changes)
    }
}

/// Warnings and errors stay visible outside the fold.
private struct ChatNoticeRow: View {
    let item: Item

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                item.title ?? ChatTimelineText.humanized(item.kind),
                systemImage: item.itemKind == .error
                    ? "xmark.octagon" : "exclamationmark.triangle"
            )
            .font(.callout.weight(.semibold))

            if let text = ChatTimelineLayout.reasoningText(item) {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(
            item.itemKind == .error ? .red.opacity(0.12) : .orange.opacity(0.12),
            in: .rect(cornerRadius: 12)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
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
                if role == MaidMessageRole.user.rawValue {
                    Text(verbatim: text)
                        .textSelection(.enabled)
                } else {
                    ChatMarkdownMessageView(
                        messageID: messageID,
                        source: text,
                        presentation: presentation
                    )
                }
            }

            if let attachments, !attachments.isEmpty {
                Text(attachments.map { $0.name ?? $0.kind }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(
            .horizontal,
            role == MaidMessageRole.user.rawValue
                ? ChatTimelineMetrics.userBubbleHorizontalPadding : 0
        )
        .padding(
            .vertical,
            role == MaidMessageRole.user.rawValue
                ? ChatTimelineMetrics.userBubbleVerticalPadding : 0
        )
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

            // PlanEntry has no stable key and plans are replaced wholesale.
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
    static func humanized(_ value: String) -> String {
        value.replacing("_", with: " ").replacing("-", with: " ").capitalized
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

private struct ChatPromptQueueView: View {
    let model: ChatPromptModel

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
