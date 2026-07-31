import Foundation

extension Thread {
    /// Applies `event` to this thread in place.
    ///
    /// `timeline` is copy-on-write, so call this through your own storage
    /// (`sessionsByID[id]?.thread?.apply(event)`) rather than a temporary copy —
    /// a second reference forces a full array copy per streamed chunk.
    mutating func apply(_ event: Event) {
        ThreadEventReducer.apply(event, to: &self)
    }
}

/// Client-side mirror of the daemon's `orchestration.Projection.Apply`: the
/// daemon streams events, not snapshots, so every branch below must match the
/// Go projection.
enum ThreadEventReducer {
    static func apply(_ event: Event, to thread: inout Thread) {
        guard event.payload.threadID == thread.id else { return }
        let payload = event.payload
        let occurredAt = event.occurredAt

        switch event.eventType {
        case .threadMetaUpdated:
            applyProviderSelection(payload, to: &thread)
            if let cwd = nonEmpty(payload.cwd) { thread.cwd = cwd }
            if let title = nonEmpty(payload.title) { thread.title = title }

        case .threadMessageSent:
            guard let id = payload.messageID, let role = payload.role else { break }
            if let index = thread.timeline.lastIndex(where: { $0.message?.id == id }),
               var message = thread.timeline[index].message {
                message.attachments = (message.attachments ?? []) + (payload.attachments ?? [])
                message.text += payload.text ?? ""
                if let turnID = nonEmpty(payload.turnID) { message.turnID = turnID }
                message.updatedAt = occurredAt
                thread.timeline[index].message = message
            } else {
                let message = Message(
                    attachments: payload.attachments,
                    createdAt: payload.createdAt ?? occurredAt,
                    id: id,
                    role: role,
                    text: payload.text ?? "",
                    turnID: payload.turnID,
                    updatedAt: payload.updatedAt ?? occurredAt
                )
                thread.timeline.append(TimelineEntry(approval: nil, item: nil, kind: MaidTimelineEntryKind.message.rawValue, message: message))
            }

        case .threadTurnStartRequested:
            applyProviderSelection(payload, to: &thread)
            let turnID = nonEmpty(payload.turnID) ?? event.eventID
            if let messageID = payload.messageID,
               let index = thread.timeline.lastIndex(where: { $0.message?.id == messageID }) {
                thread.timeline[index].message?.turnID = turnID
            }
            // A turn.start for the already-running turn is steering: the same
            // logical turn continues, so its timestamps must survive.
            if thread.latestTurn?.turnID != turnID {
                thread.latestTurn = Turn(completedAt: nil, error: nil, interruptRequested: false, requestedAt: occurredAt, startedAt: occurredAt, state: MaidTurnState.running.rawValue, stopReason: nil, turnID: turnID)
            }
            if thread.session != nil {
                thread.session?.activeTurnID = turnID
                thread.session?.status = MaidSessionStatus.running.rawValue
                thread.session?.updatedAt = occurredAt
            }

        case .threadTurnInterruptRequested:
            if let turn = thread.latestTurn, payload.turnID == nil || payload.turnID == turn.turnID {
                thread.latestTurn?.interruptRequested = true
            }

        case .threadTurnInterruptConfirmed:
            if let turn = thread.latestTurn, turn.turnID == payload.turnID, turn.completedAt == nil {
                thread.latestTurn?.completedAt = occurredAt
                thread.latestTurn?.interruptRequested = false
                thread.latestTurn?.state = MaidTurnState.interrupted.rawValue
            }

        case .threadTurnInterruptFailed:
            if let turn = thread.latestTurn, turn.turnID == payload.turnID, turn.completedAt == nil {
                thread.latestTurn?.interruptRequested = false
            }

        case .threadSessionPrepareRequested:
            var session = ensureSession(thread, event)
            session.activeTurnID = nil
            session.lastError = nil
            session.status = MaidSessionStatus.starting.rawValue
            session.updatedAt = occurredAt
            thread.session = session

        case .threadSessionStopRequested:
            thread.session?.stopRequested = true

        case .threadSessionStopFailed:
            thread.session?.stopRequested = false

        case .threadSessionStatusSet:
            guard var session = payload.session else { break }
            let failed = session.sessionStatus == .error
            if !failed { session.lastError = nil }
            session.stopRequested = false
            session.threadID = thread.id
            session.updatedAt = occurredAt

            if let active = session.activeTurnID, !active.isEmpty {
                if thread.latestTurn?.turnID != active {
                    thread.latestTurn = Turn(completedAt: nil, error: nil, interruptRequested: false, requestedAt: occurredAt, startedAt: occurredAt, state: MaidTurnState.running.rawValue, stopReason: nil, turnID: active)
                } else {
                    thread.latestTurn?.state = MaidTurnState.running.rawValue
                }
            } else if let turn = thread.latestTurn, turn.completedAt == nil {
                let state: MaidTurnState = switch session.sessionStatus {
                case .error: .error
                case .interrupted, .stopped: .interrupted
                default: .completed
                }
                thread.latestTurn?.completedAt = occurredAt
                if failed { thread.latestTurn?.error = session.lastError }
                thread.latestTurn?.interruptRequested = false
                thread.latestTurn?.state = state.rawValue
                thread.latestTurn?.stopReason = payload.stopReason
            }

            if thread.cwd == nil, let cwd = session.cwd { thread.cwd = cwd }
            if thread.providerInstanceID == nil { thread.providerInstanceID = session.providerInstanceID }
            thread.session = session

        // normalizeEvent stamps createdAt server-side, so an incoming item
        // always carries one; an existing entry keeps its original across merges.
        case .threadItemUpserted:
            guard var item = payload.item else { break }
            if let index = thread.timeline.lastIndex(where: { $0.item?.id == item.id }),
               let old = thread.timeline[index].item {
                item.payload = mergedItemPayload(old: old, incoming: item)
                item.createdAt = old.createdAt
                if nonEmpty(item.kind) == nil { item.kind = old.kind }
                if nonEmpty(item.status) == nil { item.status = old.status }
                if nonEmpty(item.title) == nil { item.title = old.title }
                if item.toolCall == nil { item.toolCall = old.toolCall }
                if nonEmpty(item.turnID) == nil { item.turnID = old.turnID }
                item.textDelta = nil
                item.updatedAt = occurredAt
                thread.timeline[index].item = item
            } else {
                item.payload = mergedItemPayload(old: nil, incoming: item)
                if nonEmpty(item.status) == nil { item.status = MaidItemStatus.inProgress.rawValue }
                item.textDelta = nil
                item.updatedAt = occurredAt
                thread.timeline.append(TimelineEntry(approval: nil, item: item, kind: MaidTimelineEntryKind.item.rawValue, message: nil))
            }

        case .threadPlanUpdated:
            if var plan = payload.plan {
                plan.updatedAt = occurredAt
                thread.plan = plan
            }

        case .threadApprovalOpened, .threadApprovalResolved:
            guard let update = payload.approval else { break }
            let resolved = event.eventType == .threadApprovalResolved
            let status = resolved ? MaidApprovalStatus.resolved : .pending
            if let index = thread.timeline.lastIndex(where: { $0.approval?.requestID == update.requestID }),
               var approval = thread.timeline[index].approval {
                // Reopening restores the request's arguments and options; a
                // resolution leaves them as they were.
                if !resolved {
                    approval.args = update.args
                    approval.options = update.options
                }
                approval.decision = resolved ? update.decision : nil
                approval.optionID = resolved ? update.optionID : nil
                approval.status = status.rawValue
                if let turnID = update.turnID { approval.turnID = turnID }
                approval.updatedAt = occurredAt
                thread.timeline[index].approval = approval
            } else {
                let approval = Approval(args: update.args, createdAt: occurredAt, decision: resolved ? update.decision : nil, optionID: resolved ? update.optionID : nil, options: resolved ? nil : update.options, requestID: update.requestID, status: status.rawValue, turnID: update.turnID, updatedAt: occurredAt)
                thread.timeline.append(TimelineEntry(approval: approval, item: nil, kind: MaidTimelineEntryKind.approval.rawValue, message: nil))
            }

        case .threadApprovalResponseRequested:
            guard let requestID = payload.requestID else { break }
            if let index = thread.timeline.lastIndex(where: { $0.approval?.requestID == requestID }) {
                thread.timeline[index].approval?.decision = payload.decision
                thread.timeline[index].approval?.optionID = payload.optionID
                thread.timeline[index].approval?.updatedAt = occurredAt
            }

        case .threadConfigOptionsUpdated:
            var session = ensureSession(thread, event)
            session.configOptions = payload.configOptions ?? []
            session.updatedAt = occurredAt
            if let model = payload.modelSelection { thread.modelSelection = model }
            thread.session = session

        case .threadSlashCommandsUpdated:
            var session = ensureSession(thread, event)
            session.slashCommands = payload.slashCommands ?? []
            session.updatedAt = occurredAt
            thread.session = session

        case .threadTokenUsageUpdated:
            var session = ensureSession(thread, event)
            session.tokenUsage = payload.tokenUsage
            session.updatedAt = occurredAt
            thread.session = session

        // Remaining cases change nothing client-visible; `nil` is an event type
        // this build does not know.
        default:
            break
        }
    }

    private static func applyProviderSelection(_ payload: EventPayload, to thread: inout Thread) {
        let providerID = nonEmpty(payload.providerInstanceID)
        let staleSession = providerID != nil
            && nonEmpty(thread.session?.providerInstanceID) != nil
            && thread.session?.providerInstanceID != providerID
        let clearSession = payload.sessionCleared == true || staleSession

        if let providerID {
            // A provider-only switch carries no modelSelection, which replaces
            // (and so clears) the old instance's model choice.
            thread.modelSelection = payload.modelSelection
            thread.providerInstanceID = providerID
        } else if let model = payload.modelSelection {
            thread.modelSelection = model
        }
        if clearSession { thread.session = nil }
    }

    private static func ensureSession(_ thread: Thread, _ event: Event) -> SessionBinding {
        if let session = thread.session { return session }
        return SessionBinding(activeTurnID: nil, configOptions: nil, cwd: thread.cwd, driver: nil, lastError: nil, providerInstanceID: event.payload.providerInstanceID ?? thread.providerInstanceID ?? "", providerName: nil, slashCommands: nil, status: MaidSessionStatus.starting.rawValue, stopRequested: false, threadID: thread.id, tokenUsage: nil, updatedAt: event.occurredAt)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func mergedItemPayload(old: Item?, incoming: Item) -> JSONAny? {
        guard let delta = nonEmpty(incoming.textDelta) else { return incoming.payload ?? old?.payload }
        var object = (old?.payload?.value as? [String: Any]) ?? [:]
        object["text"] = (object["text"] as? String ?? "") + delta
        return JSONAny(object)
    }
}
