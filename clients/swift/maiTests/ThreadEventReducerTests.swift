import Foundation
import Testing
@testable import mai

/// `ThreadEventReducer` is the client-side mirror of the daemon's
/// `orchestration.Projection.Apply`. It is the piece most likely to drift from
/// the server, so each branch is pinned here directly rather than only being
/// exercised incidentally through `ThreadStore`.
struct ThreadEventReducerTests {

    // MARK: Routing

    @Test
    func ignoresEventsAddressedToAnotherThread() {
        var thread = makeThread()
        let originalTitle = thread.title
        thread.apply(makeEvent(.threadMetaUpdated, payload: makePayload(threadID: "other", title: "Renamed")))

        #expect(thread.title == originalTitle)
    }

    /// A newer daemon may send an event type this build predates. It must be
    /// ignored, never treated as an error or applied to the wrong branch.
    @Test
    func ignoresUnrecognizedEventType() {
        var thread = makeThread()
        let originalTitle = thread.title
        var unknown = makeEvent(.threadMetaUpdated, payload: makePayload(title: "Renamed"))
        unknown.type = "thread.invented-in-the-future"

        thread.apply(unknown)

        #expect(thread.title == originalTitle)
    }

    // MARK: Messages

    @Test
    func appendsNewMessageAndCoalescesLaterChunksIntoIt() {
        var thread = makeThread()

        thread.apply(
            makeEvent(.threadMessageSent, payload: makePayload(messageID: "m1", role: MaidMessageRole.assistant.rawValue, text: "Hel"))
        )
        #expect(thread.timeline.count == 1)
        #expect(thread.timeline[0].entryKind == .message)
        #expect(thread.timeline[0].message?.text == "Hel")

        thread.apply(
            makeEvent(.threadMessageSent, payload: makePayload(messageID: "m1", role: MaidMessageRole.assistant.rawValue, text: "lo"))
        )
        #expect(thread.timeline.count == 1)
        #expect(thread.timeline[0].message?.text == "Hello")
    }

    @Test
    func ignoresMessageEventWithoutIdentity() {
        var thread = makeThread()
        thread.apply(makeEvent(.threadMessageSent, payload: makePayload(text: "orphan")))
        #expect(thread.timeline.isEmpty)
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
    func interruptRequestMarksTurnAndConfirmationCompletesIt() {
        var thread = makeThread(latestTurn: makeTurn(id: "turn-1", state: .running))

        thread.apply(
            makeEvent(.threadTurnInterruptRequested, payload: makePayload(turnID: "turn-1"))
        )
        #expect(thread.latestTurn?.interruptRequested == true)
        #expect(thread.latestTurn?.completedAt == nil)

        thread.apply(
            makeEvent(.threadTurnInterruptConfirmed, payload: makePayload(turnID: "turn-1"))
        )
        #expect(thread.latestTurn?.turnState == .interrupted)
        #expect(thread.latestTurn?.interruptRequested == false)
        #expect(thread.latestTurn?.completedAt != nil)
    }

    @Test
    func interruptFailureClearsTheRequestWithoutCompletingTheTurn() {
        var thread = makeThread(latestTurn: makeTurn(id: "turn-1", state: .running))
        thread.apply(
            makeEvent(.threadTurnInterruptRequested, payload: makePayload(turnID: "turn-1"))
        )

        thread.apply(
            makeEvent(.threadTurnInterruptFailed, payload: makePayload(turnID: "turn-1"))
        )

        #expect(thread.latestTurn?.interruptRequested == false)
        #expect(thread.latestTurn?.completedAt == nil)
        #expect(thread.latestTurn?.turnState == .running)
    }

    // MARK: Session status

    @Test
    func sessionStatusSettlesTheRunningTurn() {
        for (status, expected) in [
            (MaidSessionStatus.ready, MaidTurnState.completed),
            (.interrupted, .interrupted),
            (.stopped, .interrupted),
            (.error, .error),
        ] {
            var thread = makeThread(latestTurn: makeTurn(id: "turn-1", state: .running))
            let session = makeSession(status: status, activeTurnID: nil, lastError: status == .error ? "boom" : nil)

            thread.apply(
                makeEvent(.threadSessionStatusSet, payload: makePayload(session: session, stopReason: "end_turn"))
            )

            #expect(thread.latestTurn?.turnState == expected, "status \(status) should settle the turn as \(expected)")
            #expect(thread.latestTurn?.completedAt != nil)
            #expect(thread.latestTurn?.stopReason == "end_turn")
        }
    }

    @Test
    func erroredSessionKeepsItsMessageAndAttachesItToTheTurn() {
        var thread = makeThread(latestTurn: makeTurn(id: "turn-1", state: .running))
        let session = makeSession(status: .error, activeTurnID: nil, lastError: "provider exploded")

        thread.apply(
            makeEvent(.threadSessionStatusSet, payload: makePayload(session: session))
        )

        #expect(thread.session?.lastError == "provider exploded")
        #expect(thread.latestTurn?.error == "provider exploded")
    }

    @Test
    func nonErrorSessionClearsAnyStaleLastError() {
        var thread = makeThread()
        let session = makeSession(status: .ready, activeTurnID: nil, lastError: "stale")

        thread.apply(
            makeEvent(.threadSessionStatusSet, payload: makePayload(session: session))
        )

        #expect(thread.session?.lastError == nil)
        #expect(thread.session?.stopRequested == false)
    }

    @Test
    func sessionStatusBackfillsThreadIdentityOnlyWhenMissing() {
        var bare = mai.Thread(
            createdAt: .distantPast, cwd: nil, id: "t", latestTurn: nil, modelSelection: nil,
            plan: nil, providerInstanceID: nil, session: nil, timeline: [], title: "t", updatedAt: .distantPast
        )
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

        thread.apply(
            makeEvent(.threadItemUpserted, occurredAt: created, payload: makePayload(
                item: makeItem(id: "i1", createdAt: created, kind: MaidItemKind.toolCall.rawValue, status: MaidItemStatus.inProgress.rawValue, title: "Run tests", toolCall: makeToolCall(command: "swift test"), turnID: "turn-1")
            ))
        )
        #expect(thread.timeline.count == 1)
        #expect(thread.timeline[0].entryKind == .item)
        #expect(thread.timeline[0].item?.createdAt == created)

        // A status-only update must keep kind/title/turnID, and must NOT adopt
        // the newer createdAt.
        thread.apply(
            makeEvent(.threadItemUpserted, occurredAt: updated, payload: makePayload(
                item: makeItem(id: "i1", createdAt: updated, kind: "", status: MaidItemStatus.completed.rawValue, title: nil, turnID: nil)
            ))
        )

        let item = thread.timeline[0].item
        #expect(thread.timeline.count == 1)
        #expect(item?.itemStatus == .completed)
        #expect(item?.itemKind == .toolCall)
        #expect(item?.title == "Run tests")
        #expect(item?.toolCall?.command == "swift test")
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

    @Test
    func newItemWithoutStatusDefaultsToInProgress() {
        var thread = makeThread()
        thread.apply(
            makeEvent(.threadItemUpserted, payload: makePayload(item: makeItem(id: "i1", kind: MaidItemKind.toolCall.rawValue, status: "")))
        )
        #expect(thread.timeline[0].item?.itemStatus == .inProgress)
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
            makeEvent(.threadConfigOptionsUpdated, payload: makePayload(configOptions: options))
        )
        #expect(thread.session?.sessionStatus == .starting)
        #expect(thread.session?.configOptions?.count == 1)

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

    @Test
    func configOptionsCarryingAModelUpdateTheThreadSelection() {
        var thread = makeThread()
        thread.apply(
            makeEvent(.threadConfigOptionsUpdated, payload: makePayload(
                configOptions: [],
                modelSelection: ModelSelection(model: "opus", options: nil)
            ))
        )
        #expect(thread.modelSelection?.model == "opus")
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
        for index in 0..<20 {
            thread.apply(
                makeEvent(.threadMessageSent, payload: makePayload(messageID: "m\(index)", role: MaidMessageRole.assistant.rawValue, text: "chunk"))
            )
            thread.apply(
                makeEvent(.threadItemUpserted, payload: makePayload(item: makeItem(id: "i\(index)", kind: MaidItemKind.toolCall.rawValue, status: MaidItemStatus.inProgress.rawValue)))
            )
        }
        #expect(thread.timeline.count == 40)

        thread.apply(
            makeEvent(.threadMessageSent, payload: makePayload(messageID: "m0", role: MaidMessageRole.assistant.rawValue, text: "!"))
        )
        thread.apply(
            makeEvent(.threadItemUpserted, payload: makePayload(item: makeItem(id: "i0", kind: "", status: MaidItemStatus.completed.rawValue)))
        )

        #expect(thread.timeline.count == 40)
        #expect(thread.timeline.first(where: { $0.message?.id == "m0" })?.message?.text == "chunk!")
        #expect(thread.timeline.first(where: { $0.item?.id == "i0" })?.item?.itemStatus == .completed)
    }
}

// MARK: - Fixtures

private func makeThread(
    id: String = "t",
    cwd: String? = nil,
    providerInstanceID: String? = "provider",
    session: SessionBinding? = nil,
    latestTurn: Turn? = nil
) -> mai.Thread {
    mai.Thread(
        createdAt: Date(timeIntervalSince1970: 0),
        cwd: cwd,
        id: id,
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
    sequence: Int = 1,
    occurredAt: Date = Date(timeIntervalSince1970: 1_000),
    payload: EventPayload
) -> Event {
    Event(
        actor: MaidActorKind.server.rawValue,
        commandID: nil,
        eventID: "evt-\(sequence)",
        metadata: nil,
        occurredAt: occurredAt,
        payload: payload,
        sequence: sequence,
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
        lastError: lastError,
        provider: nil,
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
    kind: String,
    status: String,
    payload: JSONAny? = nil,
    textDelta: String? = nil,
    title: String? = nil,
    toolCall: ToolCall? = nil,
    turnID: String? = nil
) -> Item {
    Item(
        createdAt: createdAt,
        id: id,
        kind: kind,
        payload: payload,
        status: status,
        textDelta: textDelta,
        title: title,
        toolCall: toolCall,
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
    threadID: String = "t",
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
        threadID: threadID,
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
