import SwiftUI

private struct ChatTimelinePreparationKey: Equatable {
    let timelineEntryCount: Int
    let streamingTurnID: String?
    let rowWidth: CGFloat
    /// Highlighted code is prepared per appearance.
    let codeTheme: ChatCodeHighlightTheme
    let expandedSectionIDs: Set<String>
    /// Loading earlier history changes which rows exist without changing the
    /// counts above; preparation must re-run over the widened window or a
    /// later width change only prepares the rows captured at the old window.
    let oldestLoadedSectionID: String?
}

struct ChatTimeline: View {
    #if os(macOS)
        // The native transcript arms pagination well before the top edge so
        // the next page is prepared before the reader reaches it.
        private static let historyLoadDistance: CGFloat = 240
    #else
        private static let historyLoadDistance: CGFloat = 1
        private static let scrollMovementTolerance: CGFloat = 0.5
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
    @State private var isLoadingEarlier = false

    @State private var isViewportNearBottom = true
    @State private var pendingPrependAnchorID: String?
    @State private var rowWidth: CGFloat = 0
    #if os(macOS)
        @State private var nativePreparedKey: ChatTimelinePreparationKey?
    #endif

    #if os(macOS)
        @State private var macScrollPositionPreserver =
            ChatMacScrollPositionPreserver()
    #else
        @State private var bottomFollower = ChatListBottomFollower()
    #endif

    @State private var streamingContinuity = ChatStreamingContinuity()
    /// Bumped when a finished turn's settled preparation lands, so `body`
    /// re-evaluates and swaps the lingering message to its settled rows.
    @State private var settledPreparationGeneration = 0

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatFork) private var chatFork

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
            expandedSectionIDs: foldModel.expandedSectionIDs,
            oldestLoadedSectionID: loadedSections.first?.id
        )

        #if os(macOS)
            let nativeItems = ChatNativeTimelineItem.items(
                rows: rows, plan: plan,
                hasEarlierSections: hasEarlierSections, isStreaming: effectiveStreamingTurnID != nil)
        #endif
        ScrollViewReader { proxy in
            Group {
                #if os(macOS)
                    // The transcript reports its own geometry; a SwiftUI scroll
                    // observer here would see nested code/table scrollers instead.
                    ChatNativeTranscript(
                        ids: nativeItems.map(\.id), width: rowWidth,
                        isPrepared: nativePreparedKey == preparationKey,
                        measurementKeys: nativeItems.map(\.measurementKey),
                        presentationTheme: codeTheme,
                        historyLoadDistance: Self.historyLoadDistance,
                        onGeometryChange: { old, new in
                            handleMacScrollGeometryChange(
                                from: old, to: new, hasEarlierSections: hasEarlierSections)
                        }, onAttach: configureMacScrollDocument,
                        nativeRowHeight: { index, width in
                            guard case .row(let row) = nativeItems[index],
                                let descriptor = ChatNativePreparedRow.descriptor(for: row)
                            else { return nil }
                            return ChatNativePreparedRow.preparedHeight(
                                for: descriptor, width: width, store: textLayoutStore)
                        },
                        nativeRowFactory: { index, reused in
                            guard case .row(let row) = nativeItems[index],
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
                            item: nativeItems[index], streamingTurnID: effectiveStreamingTurnID,
                            threadID: threadID, store: store, foldModel: foldModel,
                            scrollState: scrollState, annotationModel: annotationModel, textLayoutStore: textLayoutStore
                        )
                        // Natively hosted rows don't inherit this view's environment.
                        .environment(\.chatFork, chatFork)
                        .id(nativeItems[index].id)
                        .frame(width: rowWidth)
                        .frame(maxWidth: .infinity)
                    }
                #else
                    List {
                        timelineContent(
                            rows: rows, effectiveStreamingTurnID: effectiveStreamingTurnID,
                            hasEarlierSections: hasEarlierSections)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 0)
                    .dismissesKeyboardInteractively()
                #endif
            }
            #if os(macOS)
                .opacity(isAwaitingInitialBottom ? 0 : 1)
            #else
                .background {
                    ChatListCollectionViewIntrospector { collectionView in
                        bottomFollower.attach(to: collectionView)
                    }
                    .allowsHitTesting(false)
                }
            #endif
            .modifier(
                ChatBottomScrollRequestModifier(
                    scrollState: scrollState,
                    proxy: proxy,
                    bottomID: Self.bottomID,
                    pinToBottom: { animated in
                        #if os(macOS)
                            return macScrollPositionPreserver.pinToBottom()
                        #else
                            guard !animated else { return false }
                            return bottomFollower.pinToBottom()
                        #endif
                    }
                )
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
            .task(id: historyLoadRequest) {
                guard historyLoadRequest > 0, isTimelineNearTop,
                    !isAwaitingInitialBottom
                else { return }
                #if os(macOS)
                    await loadEarlier(
                        loadedSections: loadedSections,
                        hasEarlierSections: hasEarlierSections
                    )
                #else
                    await loadEarlier(
                        loadedSections: loadedSections,
                        renderedRows: rows,
                        preservesPosition: !isViewportNearBottom
                            || !scrollState.shouldFollowBottom
                    )
                #endif
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
                #if os(macOS)
                    if !Task.isCancelled {
                        nativePreparedKey = preparationKey
                    }
                #endif
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
                #if os(macOS)
                    foldModel.prepareForToggle = {
                        macScrollPositionPreserver
                            .captureBeforeContentExpansion()
                    }
                #endif
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
                isAwaitingInitialBottom = true
                #if os(macOS)
                    macScrollPositionPreserver.beginInitialBottomAlignment {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            isAwaitingInitialBottom = false
                            #if DEBUG
                                ChatBenchmarkAutoRun.isInitialAlignmentComplete = true
                            #endif
                        }
                    }
                #else
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                #endif
            }
            #if !os(macOS)
                .onScrollGeometryChange(for: ChatScrollGeometry.self) {
                    geometry in
                    Self.scrollGeometry(from: geometry)
                } action: { oldGeometry, newGeometry in
                    handleScrollGeometryChange(
                        from: oldGeometry,
                        to: newGeometry,
                        hasEarlierSections: hasEarlierSections,
                        proxy: proxy
                    )
                }
                .onScrollPhaseChange { oldPhase, newPhase in
                    handleScrollPhaseChange(from: oldPhase, to: newPhase)
                }
            #endif
        }
    }

    #if os(macOS)
        private func configureMacScrollDocument(_ document: any ChatMacScrollDocument) {
            macScrollPositionPreserver.configure(
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
            macScrollPositionPreserver.attach(to: document)
        }
    #endif

    private var codeTheme: ChatCodeHighlightTheme {
        colorScheme == .dark ? .dark : .light
    }

    #if os(macOS)
        private func handleMacScrollGeometryChange(
            from oldGeometry: ChatMacScrollGeometry,
            to newGeometry: ChatMacScrollGeometry,
            hasEarlierSections: Bool
        ) {
            let isNearTop = hasEarlierSections && newGeometry.isNearTop
            if isTimelineNearTop != isNearTop {
                isTimelineNearTop = isNearTop
            }
            if isViewportNearBottom != newGeometry.isNearBottom {
                isViewportNearBottom = newGeometry.isNearBottom
            }
            scrollState.noteEndVisibility(newGeometry.isNearBottom)

            if isAwaitingInitialBottom {
                if newGeometry.isNearBottom {
                    isAwaitingInitialBottom = false
                } else {
                    _ = macScrollPositionPreserver.pinToBottom()
                }
                return
            }

            // The 24-point end zone is only UI/intent hysteresis. While
            // following, every projected layout change (resize, reflow, or
            // content growth) aligns to the exact native document end.
            if scrollState.shouldFollowBottom {
                _ = macScrollPositionPreserver.pinToBottom()
            }

            if hasEarlierSections, !oldGeometry.isNearTop,
                newGeometry.isNearTop, !isLoadingEarlier
            {
                historyLoadRequest &+= 1
            }

        }
    #else
        private static func scrollGeometry(
            from geometry: ScrollGeometry
        ) -> ChatScrollGeometry {
            let hasContentMetrics =
                geometry.containerSize.height > 0
                && geometry.contentSize.height > 0
            return ChatScrollGeometry(
                isNearTop: hasContentMetrics
                    && geometry.visibleRect.minY + geometry.contentInsets.top
                        <= Self.historyLoadDistance,
                isNearBottom: hasContentMetrics
                    && geometry.contentSize.height + geometry.contentInsets.bottom
                        - geometry.visibleRect.maxY
                        <= ChatTimelineMetrics.nearBottomDistance,
                containerHeight: geometry.containerSize.height,
                bottomInset: geometry.contentInsets.bottom,
                contentHeight: geometry.contentSize.height,
                contentOffsetY: geometry.contentOffset.y
            )
        }

        private func handleScrollGeometryChange(
            from oldGeometry: ChatScrollGeometry,
            to newGeometry: ChatScrollGeometry,
            hasEarlierSections: Bool,
            proxy: ScrollViewProxy
        ) {
            // Content growing confirms the prepended rows have landed; pinning
            // earlier would run against the old layout.
            if let anchorID = pendingPrependAnchorID {
                if newGeometry.contentHeight > oldGeometry.contentHeight {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(anchorID, anchor: .top)
                    }
                    pendingPrependAnchorID = nil
                }
                return
            }

            let isNearTop = hasEarlierSections && newGeometry.isNearTop
            if isTimelineNearTop != isNearTop {
                isTimelineNearTop = isNearTop
            }
            if isViewportNearBottom != newGeometry.isNearBottom {
                isViewportNearBottom = newGeometry.isNearBottom
            }
            scrollState.noteEndVisibility(newGeometry.isNearBottom)
            if isAwaitingInitialBottom {
                if newGeometry.isNearBottom {
                    isAwaitingInitialBottom = false
                }
                return
            }
            if hasEarlierSections, !oldGeometry.isNearTop,
                newGeometry.isNearTop, !isLoadingEarlier
            {
                historyLoadRequest &+= 1
            }

            let viewportShrank =
                newGeometry.bottomInset > oldGeometry.bottomInset
                || newGeometry.containerHeight < oldGeometry.containerHeight
            let contentGrew = newGeometry.contentHeight > oldGeometry.contentHeight

            // Keyboard and accessibility scrolling do not always enter a
            // user-driven `ScrollPhase`. Offset movement toward older content is
            // still proof the viewport left the end, so following must stop —
            // otherwise every content-height correction below yanks the viewport
            // back down. Same-frame keyboard shifts and streaming growth are
            // excluded; they move the offset without expressing that intent.
            if !viewportShrank, !contentGrew,
                newGeometry.contentOffsetY
                    < oldGeometry.contentOffsetY - Self.scrollMovementTolerance
            {
                scrollState.noteScrollAwayFromEnd()
            }

            if viewportShrank || contentGrew, scrollState.shouldFollowBottom {
                // Pinning through the proxy resolves the row identifier by
                // walking the entire ForEach identity list per call; the direct
                // offset write is constant time. The proxy remains the fallback
                // until the collection view resolves.
                if !bottomFollower.pinToBottom() {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
        }

        private func handleScrollPhaseChange(
            from oldPhase: ScrollPhase,
            to newPhase: ScrollPhase
        ) {
            if newPhase.isUserDriven, !oldPhase.isUserDriven,
                isTimelineNearTop,
                !isAwaitingInitialBottom, !isLoadingEarlier
            {
                // A drag beginning at the top changes no geometry, so explicitly
                // restart the structured pagination task.
                historyLoadRequest &+= 1
            }
            scrollState.noteUserScrollActivity(isActive: newPhase.isUserDriven)
        }

        @ViewBuilder
        private func timelineContent(
            rows: [ChatTimelineRenderRow],
            effectiveStreamingTurnID: String?,
            hasEarlierSections: Bool
        ) -> some View {
            if hasEarlierSections {
                Color.clear
                    .frame(height: ChatTimelineMetrics.historyMarkerHeight)
                    .id(Self.historyMarkerID)
                    .listRowInsets(.init())
                    .listRowSeparator(.hidden)
            }

            if !hasEarlierSections, !plan.isEmpty {
                ChatPlanRow(plan: plan)
                    .padding(.vertical, ChatTimelineMetrics.rowVerticalInset)
                    .frame(
                        maxWidth: ChatContentMetrics.maximumWidth,
                        alignment: .leading
                    )
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

            ForEach(rows) { row in
                ChatTimelineRenderRowView(
                    row: row,
                    streamingTurnID: effectiveStreamingTurnID,
                    threadID: threadID,
                    store: store,
                    foldModel: foldModel,
                    scrollState: scrollState,
                    annotationModel: annotationModel,
                    textLayoutStore: textLayoutStore
                )
            }

            // Keep the activity header, message and footer in the same presentation
            // until settled preparation is ready. Removing just the footer early
            // changes List's bottom offset and briefly displaces the live header.
            if effectiveStreamingTurnID != nil {
                ChatWorkingIndicator(activityKey: rows.last?.id)
                    .padding(.vertical, ChatTimelineMetrics.rowVerticalInset)
                    .frame(
                        maxWidth: ChatContentMetrics.maximumWidth,
                        alignment: .leading
                    )
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

            ChatEndMarker()
                .id(Self.bottomID)
                .listRowInsets(.init())
                .listRowSeparator(.hidden)
        }
    #endif

    private static let bottomID = ChatTimelineBoundaryID.bottom
    private static let historyMarkerID = ChatTimelineBoundaryID.history
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

    #if os(macOS)
        private func loadEarlier(
            loadedSections: [ChatTimelineLayout.Section],
            hasEarlierSections: Bool
        ) async {
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

            // The preserver needs the exact number of rows entering above the
            // current anchor: the page's rows plus the change in leading
            // fixed rows (history marker or plan).
            let pageRows = Self.renderRows(
                page.timelineRows,
                streamingTurnID: streamingTurnID,
                segmentCache: segmentCache
            )
            let oldLeadingRowCount = hasEarlierSections
                ? 1
                : (plan.isEmpty ? 0 : 1)
            let hasEarlierSectionsAfterLoad =
                page.newOldestSectionID != sections.first?.id || hasOlderTurns
            let newLeadingRowCount = hasEarlierSectionsAfterLoad
                ? 1
                : (plan.isEmpty ? 0 : 1)
            let leadingRowCount = pageRows.count
                + newLeadingRowCount - oldLeadingRowCount

            macScrollPositionPreserver.captureBeforePrepend(
                leadingRowCount: leadingRowCount
            )
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                oldestLoadedSectionID = page.newOldestSectionID
            }
        }
    #else
        private func loadEarlier(
            loadedSections: [ChatTimelineLayout.Section],
            renderedRows: [ChatTimelineRenderRow],
            preservesPosition: Bool
        ) async {
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

            if preservesPosition {
                // Loading only arms at the top edge, so pinning the former first
                // row to the top preserves the viewport as older rows prepend.
                pendingPrependAnchorID = renderedRows.first?.id
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                oldestLoadedSectionID = page.newOldestSectionID
            }
        }
    #endif

    /// With every loaded turn shown, reads the daemon's next older page;
    /// once it lands, the load runs again over the widened sections.
    private func loadOlderTurns(loadedSections: [ChatTimelineLayout.Section]) async {
        guard hasOlderTurns, loadedSections.first?.id == sections.first?.id else { return }
        await store.loadOlderTurns()
        guard !Task.isCancelled else { return }
        historyLoadRequest &+= 1
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
