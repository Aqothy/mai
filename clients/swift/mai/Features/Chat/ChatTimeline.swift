import SwiftUI

struct ChatTimeline: View {
    // The transcript arms pagination well before the top edge so the next
    // page is prepared before the reader reaches it. A flick on a phone
    // covers a screen in a few frames, so it arms a screen early.
    #if os(macOS)
        private static let historyLoadDistance: CGFloat = 240
    #else
        private static let historyLoadDistance: CGFloat = 1_000
    #endif

    let threadID: String
    let sections: [ChatTimelineLayout.Section]
    /// Requests still open, shown with their turns.
    let requests: [ChatRequest]
    let timelineEntryCount: Int
    /// Whether the daemon has turns before the loaded ones.
    let hasOlderTurns: Bool
    let plan: [PlanEntry]
    let streamingTurnID: String?
    let segmentCache: ChatMarkdownSegmentCache
    let store: ThreadStore
    let scrollState: ChatScrollState
    let annotationModel: ChatAnnotationModel

    @State private var foldModel = ChatTimelineFoldModel()
    @State private var isAwaitingInitialBottom = true
    @State private var oldestLoadedSectionID: String?
    @State private var isTimelineNearTop = false
    @State private var historyLoadRequest = 0
    /// The history the last request was for.
    @State private var requestedHistory: ChatTimelineHistoryPosition?
    @State private var isLoadingEarlier = false

    @State private var rowWidth: CGFloat = 0
    @State private var preparedKey: ChatTimelinePreparationKey?
    @State private var scrollPositionPreserver = ChatTranscriptScrollPositionPreserver()

    @State private var streamingContinuity = ChatStreamingContinuity()
    /// Bumped when a finished turn's settled preparation lands, so `body`
    /// re-evaluates and swaps the lingering message to its settled rows.
    @State private var settledPreparationGeneration = 0

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatFork) private var chatFork
    @Environment(\.attachmentLoader) private var attachmentLoader

    /// Retained by the thread session across short navigation round trips.
    let textLayoutStore: ChatTextLayoutStore

    var body: some View {
        let loadedSections = Self.loadedSections(
            in: sections,
            oldestSectionID: oldestLoadedSectionID
        )
        // Read so the settled-preparation bump re-evaluates this body; the
        // continuity object itself is deliberately not observable.
        let _ = settledPreparationGeneration
        let settlingTurnID = streamingContinuity.settlingTurnID(
            streamingTurnID: streamingTurnID,
            latestTurnID: sections.last?.id
        )
        let effectiveStreamingTurnID = streamingTurnID ?? settlingTurnID
        let timelineRows = ChatTimelineLayout.rows(
            sections: loadedSections,
            requests: requests,
            liveTurnID: effectiveStreamingTurnID,
            expandedSectionIDs: foldModel.expandedSectionIDs
        )
        let rows = Self.renderRows(
            timelineRows,
            streamingTurnID: effectiveStreamingTurnID,
            segmentCache: segmentCache
        )
        let hasEarlierSections = loadedSections.first?.id != sections.first?.id || hasOlderTurns
        let preparationKey = ChatTimelinePreparationKey(
            timelineEntryCount: timelineEntryCount,
            streamingTurnID: streamingTurnID,
            rowWidth: rowWidth,
            codeTheme: codeTheme,
            layoutStore: ObjectIdentifier(textLayoutStore),
            expandedSectionIDs: foldModel.expandedSectionIDs,
            oldestLoadedSectionID: loadedSections.first?.id
        )
        let items = ChatNativeTimelineItem.items(
            rows: rows, plan: plan,
            hasEarlierSections: hasEarlierSections, isStreaming: effectiveStreamingTurnID != nil)

        // The transcript reports its own geometry; a SwiftUI scroll observer
        // here would see nested code/table scrollers instead.
        ChatNativeTranscript(
            ids: items.map(\.id), sourceIDs: items.map(\.sourceID), width: rowWidth,
            isPrepared: preparedKey == preparationKey,
            measurementKeys: items.map(\.measurementKey),
            presentationTheme: codeTheme,
            layoutStore: ObjectIdentifier(textLayoutStore),
            historyLoadDistance: Self.historyLoadDistance,
            onGeometryChange: { _, geometry in
                handleScrollGeometryChange(
                    geometry, hasEarlierSections: hasEarlierSections,
                    oldestLoadedSectionID: loadedSections.first?.id)
            }, onAttach: configureScrollDocument,
            nativeRowHeight: { index, width in
                guard case .row(let row) = items[index],
                    let descriptor = ChatNativePreparedRow.descriptor(for: row)
                else { return nil }
                return ChatNativePreparedRow.preparedHeight(
                    for: descriptor, width: width, store: textLayoutStore, theme: codeTheme)
            },
            nativeRowFactory: { index, reused in
                guard case .row(let row) = items[index],
                    let descriptor = ChatNativePreparedRow.descriptor(for: row)
                else { return nil }
                let native =
                    reused as? ChatNativePreparedRow
                    ?? ChatNativePreparedRow(frame: .zero)
                native.update(
                    descriptor, width: rowWidth, store: textLayoutStore,
                    theme: codeTheme,
                    annotationContext: row.annotationContext(model: annotationModel))
                return native
            }
        ) { index in
            ChatNativeTimelineItemView(
                item: items[index], streamingTurnID: effectiveStreamingTurnID,
                threadID: threadID, store: store, foldModel: foldModel,
                scrollState: scrollState, annotationModel: annotationModel, textLayoutStore: textLayoutStore
            )
            // Natively hosted rows don't inherit this view's environment.
            .environment(\.chatFork, chatFork)
            .environment(\.attachmentLoader, attachmentLoader)
            .id(items[index].id)
            .frame(width: rowWidth)
            .frame(maxWidth: .infinity)
        }
        #if os(iOS)
            // The scroll view runs under the navigation bar, the composer
            // and the keyboard.
            .ignoresSafeArea(edges: .vertical)
        #endif
        .opacity(isAwaitingInitialBottom ? 0 : 1)
        .modifier(
            ChatBottomScrollRequestModifier(scrollState: scrollState) { animated in
                #if os(macOS)
                    _ = scrollPositionPreserver.pinToBottom()
                #else
                    _ = scrollPositionPreserver.pinToBottom(animated: animated)
                #endif
            }
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
        .onGeometryChange(for: CGFloat.self) { geometry in
            ChatTimelineMetrics.rowWidth(in: geometry.size.width)
        } action: { width in
            rowWidth = width
        }
        #if os(iOS)
            // The navigation bar above the transcript and the composer and
            // keyboard below it.
            .onGeometryChange(for: EdgeInsets.self) { geometry in
                geometry.safeAreaInsets
            } action: { insets in
                scrollPositionPreserver.setViewportInsets(
                    UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0))
            }
        #endif
        // A request made while the first page aligns runs once it has, and
        // older turns arriving run it again over the widened sections. A
        // read that failed changes neither, so it is not repeated.
        .task(
            id: ChatTimelineHistoryLoadTrigger(
                request: historyLoadRequest, isAwaitingInitialBottom: isAwaitingInitialBottom,
                oldestSectionID: sections.first?.id)
        ) {
            guard historyLoadRequest > 0, isTimelineNearTop,
                !isAwaitingInitialBottom
            else { return }
            await loadEarlier(loadedSections: loadedSections)
        }
        .task(
            id: preparationKey
        ) {
            guard rowWidth > 0 else { return }
            #if DEBUG
                // A real-thread benchmark waits for this preparation pass so
                // sweeps measure the production steady state.
                let signalsBenchmarkWarm =
                    ChatBenchmarkAutoRun.plan != nil
                    && ChatBenchmarkAutoRun.threadTitleQuery != nil
                if signalsBenchmarkWarm {
                    ChatBenchmarkAutoRun.noteTranscriptWarmStarted()
                }
            #endif
            // While a finished turn lingers in its streaming presentation,
            // prepare the settled rows it is about to swap to.
            let preparationRows = settlingTurnID == nil
                ? timelineRows
                : ChatTimelineLayout.rows(
                    sections: loadedSections,
                    requests: requests,
                    liveTurnID: streamingTurnID,
                    expandedSectionIDs: foldModel.expandedSectionIDs
                )
            await Self.prepare(
                timelineRows: preparationRows,
                streamingTurnID: streamingTurnID,
                segmentCache: segmentCache,
                textLayoutStore: textLayoutStore,
                rowWidth: rowWidth,
                codeTheme: codeTheme
            )
            #if DEBUG
                if signalsBenchmarkWarm, !Task.isCancelled {
                    ChatBenchmarkAutoRun.noteTranscriptWarm()
                }
            #endif
            if !Task.isCancelled {
                preparedKey = preparationKey
            }
            guard !Task.isCancelled, let settlingTurnID else { return }
            streamingContinuity.noteSettledPreparation(
                turnID: settlingTurnID
            )
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                settledPreparationGeneration &+= 1
            }
        }
        .onAppear {
            if oldestLoadedSectionID == nil {
                oldestLoadedSectionID = loadedSections.first?.id
                #if DEBUG
                    // A real-thread benchmark sweeps the whole transcript;
                    // mounting it fully up front keeps history pagination
                    // from re-anchoring the viewport mid-measurement.
                    if ChatBenchmarkAutoRun.threadTitleQuery != nil,
                        !UserDefaults.standard.bool(forKey: "ChatBenchmarkPaginatedHistory")
                    {
                        oldestLoadedSectionID = sections.first?.id
                    }
                #endif
            }
            // Once aligned, the transcript keeps the reader's place when the
            // chat is shown again.
            guard isAwaitingInitialBottom else { return }
            scrollPositionPreserver.beginInitialBottomAlignment {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    isAwaitingInitialBottom = false
                    #if DEBUG
                        ChatBenchmarkAutoRun.isInitialAlignmentComplete = true
                    #endif
                }
            }
        }
    }

    private func configureScrollDocument(_ document: ChatTranscriptScrollDocument) {
        scrollPositionPreserver.configure(
            ChatScrollIntentHandlers(
                isBottomFollowingEnabled: {
                    scrollState.shouldFollowBottom
                },
                noteReaderAwayFromEnd: {
                    scrollState.noteScrollAwayFromEnd()
                },
                noteReaderReachedEnd: {
                    scrollState.noteScrollReturnedToEnd()
                }
            )
        )
        scrollPositionPreserver.attach(to: document)
    }

    private var codeTheme: ChatCodeHighlightTheme {
        colorScheme == .dark ? .dark : .light
    }

    private func handleScrollGeometryChange(
        _ geometry: ChatScrollGeometry,
        hasEarlierSections: Bool,
        oldestLoadedSectionID: String?
    ) {
        let isNearTop = hasEarlierSections && geometry.isNearTop
        if isTimelineNearTop != isNearTop {
            isTimelineNearTop = isNearTop
        }
        scrollState.noteEndVisibility(geometry.isNearBottom)

        // Asked for once per loaded history while the top is near, not only
        // on arriving there: a first page shorter than the viewport is near
        // the top from the start, and a short earlier page leaves the reader
        // there. Not again for the same history, or a load that found
        // nothing would repeat for every report; leaving the top re-arms it.
        guard isNearTop else {
            if requestedHistory != nil { requestedHistory = nil }
            return
        }
        let history = ChatTimelineHistoryPosition(
            oldestLoadedSectionID: oldestLoadedSectionID,
            oldestSectionID: sections.first?.id)
        if !isLoadingEarlier, requestedHistory != history {
            requestedHistory = history
            historyLoadRequest &+= 1
        }
    }

    private static let initialTurnCount = 5
    private static let earlierTurnCount = 10

    /// The first timeline mount contains only the newest turns so the app
    /// does not construct distant history during a cold open.
    static func initialSections(
        in sections: [ChatTimelineLayout.Section]
    ) -> [ChatTimelineLayout.Section] {
        ChatTimelineLayout.paginatedSections(
            sections,
            userMessageLimit: Self.initialTurnCount
        )
    }

    private static func loadedSections(
        in sections: [ChatTimelineLayout.Section],
        oldestSectionID: String?
    ) -> [ChatTimelineLayout.Section] {
        guard let oldestSectionID,
            let startIndex = sections.firstIndex(where: {
                $0.id == oldestSectionID
            })
        else {
            return Self.initialSections(in: sections)
        }
        return Array(sections[startIndex...])
    }

    private func loadEarlier(loadedSections: [ChatTimelineLayout.Section]) async {
        guard !isLoadingEarlier else { return }

        isLoadingEarlier = true
        defer { isLoadingEarlier = false }

        guard
            let page = await prepareEarlierPage(
                loadedSections: loadedSections,
                rowWidth: rowWidth
            )
        else {
            await loadOlderTurns(loadedSections: loadedSections)
            return
        }

        // The documents keep the row being read in place as the page's rows
        // install above it.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            oldestLoadedSectionID = page.newOldestSectionID
        }
    }

    /// With every loaded turn shown, reads the daemon's next older page.
    /// The load runs again once older turns arrive, by this read or any
    /// other: the task's trigger includes the oldest section.
    private func loadOlderTurns(loadedSections: [ChatTimelineLayout.Section]) async {
        guard hasOlderTurns, loadedSections.first?.id == sections.first?.id else { return }
        await store.loadOlderTurns()
    }

    private func prepareEarlierPage(
        loadedSections: [ChatTimelineLayout.Section],
        rowWidth: CGFloat
    ) async -> (
        newOldestSectionID: String,
        timelineRows: [ChatTimelineRowModel]
    )? {
        guard rowWidth > 0,
            let oldestLoadedSection = loadedSections.first,
            let oldStartIndex = sections.firstIndex(where: {
                $0.id == oldestLoadedSection.id
            }),
            oldStartIndex > sections.startIndex
        else { return nil }

        let pageSections = ChatTimelineLayout.paginatedSections(
            sections[..<oldStartIndex],
            userMessageLimit: Self.earlierTurnCount
        )
        let pageTimelineRows = ChatTimelineLayout.rows(
            sections: pageSections,
            liveTurnID: streamingTurnID,
            expandedSectionIDs: foldModel.expandedSectionIDs
        )
        await Self.prepare(
            timelineRows: pageTimelineRows,
            streamingTurnID: streamingTurnID,
            segmentCache: segmentCache,
            textLayoutStore: textLayoutStore,
            rowWidth: rowWidth,
            codeTheme: codeTheme
        )

        guard !Task.isCancelled, isTimelineNearTop,
            !isAwaitingInitialBottom,
            oldestLoadedSectionID == oldestLoadedSection.id,
            let newOldestSectionID = pageSections.first?.id,
            sections.contains(where: { $0.id == newOldestSectionID })
        else { return nil }

        return (newOldestSectionID, pageTimelineRows)
    }
}
