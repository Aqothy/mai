import Foundation
import Testing
@testable import mai

/// `ThreadEventReducer` is the client-side mirror of the daemon's
/// `orchestration.Projection.Apply`. It is the piece most likely to drift from
/// the server, so each branch is pinned here directly rather than only being
/// exercised incidentally through `ThreadStore`.
struct ThreadEventReducerTests {

    // MARK: Messages

    @Test
    func appendsNewMessageAndCoalescesLaterChunksIntoIt() {
        var thread = makeThread()

        thread.apply(
            makeEvent(.threadMessageSent, payload: makePayload(messageID: "m1", role: MaidMessageRole.assistant.rawValue, text: "Hel"))
        )
        #expect(thread.timeline.count == 1)
        #expect(thread.timeline[0].entryKind == .message)

        thread.apply(
            makeEvent(.threadMessageSent, payload: makePayload(messageID: "m1", role: MaidMessageRole.assistant.rawValue, text: "lo"))
        )
        #expect(thread.timeline.count == 1)
        #expect(thread.timeline[0].message?.text == "Hello")
    }

    // MARK: Turns

    @Test
    func turnStartCreatesRunningTurnAndStampsItsMessage() {
        var thread = makeThread(session: makeSession(status: .ready))
        thread.apply(
            makeEvent(.threadMessageSent, payload: makePayload(messageID: "m1", role: MaidMessageRole.user.rawValue, text: "go"))
        )

        thread.apply(
            makeEvent(.threadTurnStartRequested, payload: makePayload(messageID: "m1", turnID: "turn-1"))
        )

        #expect(thread.latestTurn?.turnID == "turn-1")
        #expect(thread.latestTurn?.turnState == .running)
        #expect(thread.timeline[0].message?.turnID == "turn-1")
        #expect(thread.session?.sessionStatus == .running)
        #expect(thread.session?.activeTurnID == "turn-1")
    }

    /// Steering sends another turn.start for the turn already running; the
    /// original turn's timestamps must survive.
    @Test
    func turnStartForTheRunningTurnKeepsItsOriginalTimestamps() {
        let started = Date(timeIntervalSince1970: 1_000)
        var thread = makeThread(latestTurn: makeTurn(id: "turn-1", state: .running, at: started))

        thread.apply(
            makeEvent(.threadTurnStartRequested, occurredAt: started.addingTimeInterval(60), payload: makePayload(turnID: "turn-1"))
        )

        #expect(thread.latestTurn?.requestedAt == started)
    }

    @Test
    func newTurnKeepsTheSettledTurnInPreviousTurns() {
        let started = Date(timeIntervalSince1970: 1_000)
        var stopped = makeTurn(id: "turn-1", state: .interrupted, at: started)
        stopped.completedAt = started.addingTimeInterval(9)
        var thread = makeThread(latestTurn: stopped)

        thread.apply(
            makeEvent(.threadTurnStartRequested, occurredAt: started.addingTimeInterval(60), payload: makePayload(turnID: "turn-2"))
        )

        #expect(thread.latestTurn?.turnID == "turn-2")
        #expect(thread.previousTurns?.map(\.turnID) == ["turn-1"])
        #expect(thread.previousTurns?.first?.turnState == .interrupted)
        #expect(thread.previousTurns?.first?.completedAt == started.addingTimeInterval(9))
    }

    /// A failed interrupt clears the request without completing the turn; a
    /// confirmed one completes it.
    @Test
    func interruptRequestFailureAndConfirmation() {
        var thread = makeThread(latestTurn: makeTurn(id: "turn-1", state: .running))

        thread.apply(makeEvent(.threadTurnInterruptRequested, payload: makePayload(turnID: "turn-1")))
        #expect(thread.latestTurn?.interruptRequested == true)

        thread.apply(makeEvent(.threadTurnInterruptFailed, payload: makePayload(turnID: "turn-1")))
        #expect(thread.latestTurn?.interruptRequested == false)
        #expect(thread.latestTurn?.completedAt == nil)
        #expect(thread.latestTurn?.turnState == .running)

        thread.apply(makeEvent(.threadTurnInterruptRequested, payload: makePayload(turnID: "turn-1")))
        thread.apply(makeEvent(.threadTurnInterruptConfirmed, payload: makePayload(turnID: "turn-1")))
        #expect(thread.latestTurn?.turnState == .interrupted)
        #expect(thread.latestTurn?.interruptRequested == false)
        #expect(thread.latestTurn?.completedAt != nil)
    }

    // MARK: Session status

    /// Settles the running turn by status; only an error keeps the session's
    /// lastError and copies it onto the turn.
    @Test
    func sessionStatusSettlesTheRunningTurn() {
        for (status, expected) in [
            (MaidSessionStatus.ready, MaidTurnState.completed),
            (.interrupted, .interrupted),
            (.stopped, .interrupted),
            (.error, .error),
        ] {
            var thread = makeThread(latestTurn: makeTurn(id: "turn-1", state: .running))
            let session = makeSession(status: status, activeTurnID: nil, lastError: "boom")

            thread.apply(
                makeEvent(.threadSessionStatusSet, payload: makePayload(session: session, stopReason: "end_turn"))
            )

            let keptError = status == .error ? "boom" : nil
            #expect(thread.latestTurn?.turnState == expected, "status \(status) should settle the turn as \(expected)")
            #expect(thread.latestTurn?.completedAt != nil)
            #expect(thread.latestTurn?.stopReason == "end_turn")
            #expect(thread.latestTurn?.error == keptError)
            #expect(thread.session?.lastError == keptError)
            #expect(thread.session?.stopRequested == false)
        }
    }

    @Test
    func sessionStatusBackfillsThreadIdentityOnlyWhenMissing() {
        var bare = makeThread(providerInstanceID: nil)
        let session = makeSession(status: .ready, activeTurnID: nil, cwd: "/from/session", providerInstanceID: "provider-b")

        bare.apply(makeEvent(.threadSessionStatusSet, payload: makePayload(session: session)))
        #expect(bare.cwd == "/from/session")
        #expect(bare.providerInstanceID == "provider-b")

        var owned = makeThread(cwd: "/from/thread", providerInstanceID: "provider-a")
        owned.apply(makeEvent(.threadSessionStatusSet, payload: makePayload(session: session)))
        #expect(owned.cwd == "/from/thread")
        #expect(owned.providerInstanceID == "provider-a")
    }

    @Test
    func sessionPrepareResetsTheBindingToStarting() {
        var thread = makeThread(session: makeSession(status: .error, activeTurnID: "turn-1", lastError: "old"))

        thread.apply(
            makeEvent(.threadSessionPrepareRequested, payload: makePayload())
        )

        #expect(thread.session?.sessionStatus == .starting)
        #expect(thread.session?.activeTurnID == nil)
        #expect(thread.session?.lastError == nil)
    }

    @Test
    func stopRequestAndFailureToggleTheStopFlag() {
        var thread = makeThread(session: makeSession(status: .running))

        thread.apply(makeEvent(.threadSessionStopRequested, payload: makePayload()))
        #expect(thread.session?.stopRequested == true)

        thread.apply(makeEvent(.threadSessionStopFailed, payload: makePayload()))
        #expect(thread.session?.stopRequested == false)
    }

    // MARK: Items

    /// The daemon's `normalizeEvent` stamps `createdAt` before publishing, so a
    /// client never sees a zero one — the fixtures mirror that by giving each
    /// upsert its own `createdAt`. The later one must lose to the original.
    @Test
    func itemUpsertAppendsThenMergesPreservingCreatedAtAndPriorFields() {
        let created = Date(timeIntervalSince1970: 500)
        let updated = created.addingTimeInterval(10)
        var thread = makeThread()

        // A new item without a status starts in progress.
        thread.apply(
            makeEvent(.threadItemUpserted, occurredAt: created, payload: makePayload(
                item: makeItem(
                    id: "i1", createdAt: created, detailAvailable: true, kind: MaidItemKind.commandExecution.rawValue,
                    status: "", sequence: 1, title: "Run tests", toolCall: makeToolCall(command: "swift test"),
                    toolCallSummary: makeToolCallSummary(commandPreview: "swift test"), turnID: "turn-1")
            ))
        )
        #expect(thread.timeline.count == 1)
        #expect(thread.timeline[0].entryKind == .item)
        #expect(thread.timeline[0].item?.itemStatus == .inProgress)

        // A status-only update must keep every prior field, and must NOT adopt
        // the newer createdAt.
        thread.apply(
            makeEvent(.threadItemUpserted, occurredAt: updated, payload: makePayload(
                item: makeItem(id: "i1", createdAt: updated, kind: "", status: MaidItemStatus.completed.rawValue)
            ))
        )

        let item = thread.timeline[0].item
        #expect(thread.timeline.count == 1)
        #expect(item?.itemStatus == .completed)
        #expect(item?.itemKind == .commandExecution)
        #expect(item?.title == "Run tests")
        #expect(item?.toolCall?.command == "swift test")
        #expect(item?.toolCallSummary?.commandPreview == "swift test")
        #expect(item?.detailAvailable == true)
        #expect(item?.sequence == 1)
        #expect(item?.turnID == "turn-1")
        #expect(item?.createdAt == created)
        #expect(item?.updatedAt == updated)
    }

    /// textDelta APPENDS to the payload's text; a non-empty payload REPLACES it.
    /// Both rules must match the Go projection's applyItemPayload.
    @Test
    func itemTextDeltaAccumulatesWhileFullPayloadReplaces() {
        var thread = makeThread()
        thread.apply(
            makeEvent(.threadItemUpserted, payload: makePayload(
                item: makeItem(id: "r1", kind: MaidItemKind.reasoning.rawValue, status: MaidItemStatus.inProgress.rawValue, textDelta: "Thin")
            ))
        )
        #expect(payloadText(thread.timeline[0].item) == "Thin")
        #expect(thread.timeline[0].item?.textDelta == nil)

        thread.apply(
            makeEvent(.threadItemUpserted, payload: makePayload(
                item: makeItem(id: "r1", kind: MaidItemKind.reasoning.rawValue, status: MaidItemStatus.inProgress.rawValue, textDelta: "king")
            ))
        )
        #expect(payloadText(thread.timeline[0].item) == "Thinking")

        thread.apply(
            makeEvent(.threadItemUpserted, payload: makePayload(
                item: makeItem(id: "r1", kind: MaidItemKind.reasoning.rawValue, status: MaidItemStatus.completed.rawValue, payload: JSONAny(["text": "final"]))
            ))
        )
        #expect(payloadText(thread.timeline[0].item) == "final")
    }

    // MARK: Approvals

    @Test
    func approvalOpensPendingThenResolves() {
        var thread = makeThread()

        thread.apply(
            makeEvent(.threadApprovalOpened, payload: makePayload(
                approval: makeApprovalEvent(requestID: "req-1", turnID: "turn-1")
            ))
        )
        #expect(thread.timeline.count == 1)
        #expect(thread.timeline[0].entryKind == .approval)
        #expect(thread.timeline[0].approval?.approvalStatus == .pending)

        thread.apply(
            makeEvent(.threadApprovalResolved, payload: makePayload(
                approval: makeApprovalEvent(requestID: "req-1", turnID: "turn-1", decision: .accept, optionID: "allow-once")
            ))
        )
        #expect(thread.timeline.count == 1)
        #expect(thread.timeline[0].approval?.approvalStatus == .resolved)
        #expect(thread.timeline[0].approval?.decision == MaidApprovalDecision.accept.rawValue)
        #expect(thread.timeline[0].approval?.optionID == "allow-once")
    }

    @Test
    func approvalResponseRecordsTheOptimisticDecision() {
        var thread = makeThread()
        thread.apply(
            makeEvent(.threadApprovalOpened, payload: makePayload(approval: makeApprovalEvent(requestID: "req-1")))
        )

        thread.apply(
            makeEvent(.threadApprovalResponseRequested, payload: makePayload(
                decision: MaidApprovalDecision.decline.rawValue, optionID: "reject", requestID: "req-1"
            ))
        )

        // Still pending: the provider's resolve event is authoritative.
        #expect(thread.timeline[0].approval?.approvalStatus == .pending)
        #expect(thread.timeline[0].approval?.decision == MaidApprovalDecision.decline.rawValue)
        #expect(thread.timeline[0].approval?.optionID == "reject")
    }

    // MARK: Session metadata

    @Test
    func sessionMetadataEventsMaterializeAMissingBinding() {
        let options = [ConfigOption(category: MaidConfigOptionCategory.model.rawValue, choices: nil, currentValue: nil, description: nil, id: "model", label: "Model", type: MaidConfigOptionType.select.rawValue)]

        var thread = makeThread()
        thread.apply(
            makeEvent(.threadConfigOptionsUpdated, payload: makePayload(
                configOptions: options,
                modelSelection: ModelSelection(model: "opus", options: nil)
            ))
        )
        #expect(thread.session?.sessionStatus == .starting)
        #expect(thread.session?.configOptions?.count == 1)
        #expect(thread.modelSelection?.model == "opus")

        thread.apply(
            makeEvent(.threadSlashCommandsUpdated, payload: makePayload(
                slashCommands: [SlashCommand(description: nil, hasInput: nil, name: "compact")]
            ))
        )
        #expect(thread.session?.slashCommands?.count == 1)

        thread.apply(
            makeEvent(.threadTokenUsageUpdated, payload: makePayload(
                tokenUsage: TokenUsage(cost: nil, currency: nil, maxTokens: 200, usedTokens: 100)
            ))
        )
        #expect(thread.session?.tokenUsage?.usedTokens == 100)
    }

    // MARK: Provider selection

    @Test
    func switchingProviderReplacesSelectionAndClearsTheStaleSession() {
        var thread = makeThread(
            providerInstanceID: "provider-a",
            session: makeSession(status: .ready, providerInstanceID: "provider-a")
        )

        thread.apply(
            makeEvent(.threadMetaUpdated, payload: makePayload(providerInstanceID: "provider-b"))
        )

        #expect(thread.providerInstanceID == "provider-b")
        // A provider-only switch drops the old instance's model choice.
        #expect(thread.modelSelection == nil)
        #expect(thread.session == nil)
    }

    @Test
    func metaUpdateAppliesTitleAndCwdOnlyWhenPresent() {
        var thread = makeThread(cwd: "/original")

        thread.apply(
            makeEvent(.threadMetaUpdated, payload: makePayload(title: "Renamed"))
        )
        #expect(thread.title == "Renamed")
        #expect(thread.cwd == "/original")

        thread.apply(
            makeEvent(.threadMetaUpdated, payload: makePayload(cwd: "/moved"))
        )
        #expect(thread.title == "Renamed")
        #expect(thread.cwd == "/moved")
    }

    // MARK: Lookup

    /// Timeline lookups scan backwards for the streaming hot path. An entry
    /// buried behind newer ones must still be the one that gets updated.
    @Test
    func updatesTargetTheMatchingEntryEvenWhenItIsNotTheNewest() {
        var thread = makeThread()
        for index in 0..<2 {
            thread.apply(
                makeEvent(.threadMessageSent, payload: makePayload(messageID: "m\(index)", role: MaidMessageRole.assistant.rawValue, text: "chunk"))
            )
            thread.apply(
                makeEvent(.threadItemUpserted, payload: makePayload(item: makeItem(id: "i\(index)", kind: MaidItemKind.toolCall.rawValue, status: MaidItemStatus.inProgress.rawValue)))
            )
        }

        thread.apply(
            makeEvent(.threadMessageSent, payload: makePayload(messageID: "m0", role: MaidMessageRole.assistant.rawValue, text: "!"))
        )
        thread.apply(
            makeEvent(.threadItemUpserted, payload: makePayload(item: makeItem(id: "i0", kind: "", status: MaidItemStatus.completed.rawValue)))
        )

        #expect(thread.timeline.count == 4)
        #expect(thread.timeline[0].message?.text == "chunk!")
        #expect(thread.timeline[1].item?.itemStatus == .completed)
        #expect(thread.timeline[3].item?.itemStatus == .inProgress)
    }
}

// MARK: - Fixtures

private func makeThread(
    cwd: String? = nil,
    providerInstanceID: String? = "provider",
    session: SessionBinding? = nil,
    latestTurn: Turn? = nil
) -> mai.Thread {
    mai.Thread(
        createdAt: Date(timeIntervalSince1970: 0),
        cwd: cwd,
        id: "t",
        latestTurn: latestTurn,
        modelSelection: nil,
        plan: nil,
        providerInstanceID: providerInstanceID,
        session: session,
        timeline: [],
        title: "Thread",
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

private func makeEvent(
    _ type: MaidEventType,
    occurredAt: Date = Date(timeIntervalSince1970: 1_000),
    payload: EventPayload
) -> Event {
    Event(
        actor: MaidActorKind.server.rawValue,
        commandID: nil,
        eventID: "evt-1",
        metadata: nil,
        occurredAt: occurredAt,
        payload: payload,
        sequence: 1,
        type: type.rawValue
    )
}

private func makeSession(
    status: MaidSessionStatus,
    activeTurnID: String? = nil,
    lastError: String? = nil,
    cwd: String? = nil,
    providerInstanceID: String = "provider"
) -> SessionBinding {
    SessionBinding(
        activeTurnID: activeTurnID,
        configOptions: nil,
        cwd: cwd,
        driver: nil,
        lastError: lastError,
        providerInstanceID: providerInstanceID,
        providerName: nil,
        slashCommands: nil,
        status: status.rawValue,
        stopRequested: nil,
        threadID: "t",
        tokenUsage: nil,
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

private func makeTurn(
    id: String,
    state: MaidTurnState,
    at: Date = Date(timeIntervalSince1970: 0)
) -> Turn {
    Turn(
        completedAt: nil,
        error: nil,
        interruptRequested: false,
        requestedAt: at,
        startedAt: at,
        state: state.rawValue,
        stopReason: nil,
        turnID: id
    )
}

private func makeItem(
    id: String,
    createdAt: Date = Date(timeIntervalSince1970: 0),
    detailAvailable: Bool? = nil,
    kind: String,
    status: String,
    payload: JSONAny? = nil,
    sequence: Int? = nil,
    textDelta: String? = nil,
    title: String? = nil,
    toolCall: ToolCall? = nil,
    toolCallSummary: ToolCallSummary? = nil,
    turnID: String? = nil
) -> Item {
    Item(
        createdAt: createdAt,
        detailAvailable: detailAvailable,
        id: id,
        kind: kind,
        payload: payload,
        sequence: sequence,
        status: status,
        textDelta: textDelta,
        title: title,
        toolCall: toolCall,
        toolCallSummary: toolCallSummary,
        turnID: turnID,
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

private func makeToolCall(command: String) -> ToolCall {
    ToolCall(
        action: MaidToolAction.execute.rawValue,
        attachments: nil,
        changes: nil,
        command: command,
        cwd: nil,
        durationMilliseconds: nil,
        error: nil,
        exitCode: nil,
        locations: nil,
        name: nil,
        namespace: nil,
        output: nil,
        providerKind: nil,
        query: nil
    )
}

private func makeToolCallSummary(commandPreview: String) -> ToolCallSummary {
    ToolCallSummary(
        action: MaidToolAction.execute.rawValue, attachmentCount: nil, attachments: nil, changeCount: nil,
        changes: nil, commandPreview: commandPreview, cwd: nil, durationMilliseconds: nil, errorPreview: nil,
        exitCode: nil, locationCount: nil, locations: nil, name: nil, namespace: nil, outputPreview: nil,
        providerKind: nil, queryPreview: nil, truncated: nil
    )
}

private func makeApprovalEvent(
    requestID: String,
    turnID: String? = nil,
    decision: MaidApprovalDecision? = nil,
    optionID: String? = nil
) -> ApprovalEvent {
    ApprovalEvent(
        args: nil,
        cancelled: nil,
        decision: decision?.rawValue,
        detail: nil,
        optionID: optionID,
        options: nil,
        requestID: requestID,
        requestType: nil,
        turnID: turnID
    )
}

private func makePayload(
    approval: ApprovalEvent? = nil,
    configOptions: [ConfigOption]? = nil,
    cwd: String? = nil,
    decision: String? = nil,
    item: Item? = nil,
    messageID: String? = nil,
    modelSelection: ModelSelection? = nil,
    optionID: String? = nil,
    providerInstanceID: String? = nil,
    requestID: String? = nil,
    role: String? = nil,
    session: SessionBinding? = nil,
    slashCommands: [SlashCommand]? = nil,
    stopReason: String? = nil,
    text: String? = nil,
    title: String? = nil,
    tokenUsage: TokenUsage? = nil,
    turnID: String? = nil
) -> EventPayload {
    EventPayload(
        approval: approval,
        attachments: nil,
        configOptions: configOptions,
        createdAt: nil,
        cwd: cwd,
        decision: decision,
        item: item,
        messageID: messageID,
        modelSelection: modelSelection,
        optionID: optionID,
        plan: nil,
        providerInstanceID: providerInstanceID,
        requestID: requestID,
        role: role,
        session: session,
        sessionCleared: nil,
        slashCommands: slashCommands,
        stopReason: stopReason,
        text: text,
        threadID: "t",
        title: title,
        tokenUsage: tokenUsage,
        turnID: turnID,
        updatedAt: nil,
        value: nil
    )
}

private func payloadText(_ item: Item?) -> String? {
    (item?.payload?.value as? [String: Any])?["text"] as? String
}
