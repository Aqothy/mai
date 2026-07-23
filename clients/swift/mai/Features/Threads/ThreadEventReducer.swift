import Foundation

enum ThreadEventReducer {
    static func apply(_ event: Event, to original: Thread) -> Thread {
        guard event.payload.threadID == original.id else { return original }
        var thread = original

        switch event.type {
        case "thread.meta-updated":
            thread = applyProviderSelection(event.payload, to: thread)
            thread = thread.with(
                cwd: nonEmpty(event.payload.cwd).map(Optional.some),
                title: nonEmpty(event.payload.title) ?? thread.title
            )

        case "thread.message-sent":
            guard let id = event.payload.messageID, let role = event.payload.role else { break }
            var timeline = thread.timeline
            if let index = timeline.firstIndex(where: { $0.message?.id == id }), let old = timeline[index].message {
                let message = old.with(
                    attachments: (old.attachments ?? []) + (event.payload.attachments ?? []),
                    text: old.text + (event.payload.text ?? ""),
                    turnID: nonEmpty(event.payload.turnID).map(Optional.some),
                    updatedAt: event.occurredAt
                )
                timeline[index] = timeline[index].with(message: .some(message))
            } else {
                let message = Message(
                    attachments: event.payload.attachments,
                    createdAt: event.payload.createdAt ?? event.occurredAt,
                    id: id,
                    role: role,
                    text: event.payload.text ?? "",
                    turnID: event.payload.turnID,
                    updatedAt: event.payload.updatedAt ?? event.occurredAt
                )
                timeline.append(TimelineEntry(approval: nil, item: nil, kind: "message", message: message))
            }
            thread = thread.with(timeline: timeline)

        case "thread.turn-start-requested":
            thread = applyProviderSelection(event.payload, to: thread)
            let turnID = nonEmpty(event.payload.turnID) ?? event.eventID
            var timeline = thread.timeline
            if let messageID = event.payload.messageID,
               let index = timeline.firstIndex(where: { $0.message?.id == messageID }),
               let message = timeline[index].message {
                timeline[index] = timeline[index].with(message: .some(message.with(turnID: .some(turnID))))
            }
            let turn = thread.latestTurn?.turnID == turnID
                ? thread.latestTurn
                : Turn(completedAt: nil, error: nil, interruptRequested: false, requestedAt: event.occurredAt, startedAt: event.occurredAt, state: "running", stopReason: nil, turnID: turnID)
            var session = thread.session
            if let current = session {
                session = current.with(activeTurnID: .some(turnID), status: "running", updatedAt: event.occurredAt)
            }
            thread = thread.with(
                draft: false,
                latestTurn: turn.map(Optional.some),
                session: session.map(Optional.some),
                timeline: timeline,
                title: original.draft ? nonEmpty(event.payload.title) ?? thread.title : thread.title
            )

        case "thread.turn-interrupt-requested":
            if let turn = thread.latestTurn, event.payload.turnID == nil || event.payload.turnID == turn.turnID {
                thread = thread.with(latestTurn: .some(turn.with(interruptRequested: .some(true))))
            }

        case "thread.turn-interrupt-confirmed":
            if let turn = thread.latestTurn, turn.turnID == event.payload.turnID, turn.completedAt == nil {
                thread = thread.with(latestTurn: .some(turn.with(completedAt: .some(event.occurredAt), interruptRequested: .some(false), state: "interrupted")))
            }

        case "thread.turn-interrupt-failed":
            if let turn = thread.latestTurn, turn.turnID == event.payload.turnID, turn.completedAt == nil {
                thread = thread.with(latestTurn: .some(turn.with(interruptRequested: .some(false))))
            }

        case "thread.session-prepare-requested":
            let session = ensureSession(thread, event).with(activeTurnID: .some(nil), lastError: .some(nil), status: "starting", updatedAt: event.occurredAt)
            thread = thread.with(session: .some(session))

        case "thread.session-stop-requested":
            if let session = thread.session {
                thread = thread.with(session: .some(session.with(stopRequested: .some(true))))
            }

        case "thread.session-stop-failed":
            if let session = thread.session {
                thread = thread.with(session: .some(session.with(stopRequested: .some(false))))
            }

        case "thread.session-status-set":
            guard var session = event.payload.session else { break }
            session = session.with(
                lastError: session.status == "error" ? nil : .some(nil),
                stopRequested: .some(false),
                threadID: thread.id,
                updatedAt: event.occurredAt
            )
            var turn = thread.latestTurn
            if let active = session.activeTurnID, !active.isEmpty {
                if turn?.turnID != active {
                    turn = Turn(completedAt: nil, error: nil, interruptRequested: false, requestedAt: event.occurredAt, startedAt: event.occurredAt, state: "running", stopReason: nil, turnID: active)
                } else if let current = turn {
                    turn = current.with(state: "running")
                }
            } else if let current = turn, current.completedAt == nil {
                let state: String
                switch session.status {
                case "error": state = "error"
                case "interrupted", "stopped": state = "interrupted"
                default: state = "completed"
                }
                turn = current.with(
                    completedAt: .some(event.occurredAt),
                    error: session.status == "error" ? .some(session.lastError) : nil,
                    interruptRequested: .some(false),
                    state: state,
                    stopReason: .some(event.payload.stopReason)
                )
            }
            thread = thread.with(
                cwd: thread.cwd == nil ? session.cwd.map(Optional.some) : nil,
                latestTurn: turn.map(Optional.some),
                providerInstanceID: thread.providerInstanceID == nil ? Optional.some(session.providerInstanceID) : nil,
                session: .some(session)
            )

        case "thread.item-upserted":
            guard var item = event.payload.item else { break }
            var timeline = thread.timeline
            if let index = timeline.firstIndex(where: { $0.item?.id == item.id }), let old = timeline[index].item {
                let payload = mergedItemPayload(old: old, incoming: item)
                item = item.with(
                    createdAt: old.createdAt,
                    kind: nonEmpty(item.kind) ?? old.kind,
                    payload: .some(payload),
                    status: nonEmpty(item.status) ?? old.status,
                    textDelta: .some(nil),
                    title: nonEmpty(item.title).map(Optional.some) ?? .some(old.title),
                    turnID: nonEmpty(item.turnID).map(Optional.some) ?? .some(old.turnID),
                    updatedAt: event.occurredAt
                )
                timeline[index] = timeline[index].with(item: .some(item))
            } else {
                item = item.with(
                    payload: .some(mergedItemPayload(old: nil, incoming: item)),
                    status: nonEmpty(item.status) ?? "in_progress",
                    textDelta: .some(nil),
                    updatedAt: event.occurredAt
                )
                timeline.append(TimelineEntry(approval: nil, item: item, kind: "item", message: nil))
            }
            thread = thread.with(timeline: timeline)

        case "thread.plan-updated":
            if let plan = event.payload.plan {
                thread = thread.with(plan: .some(plan.with(updatedAt: event.occurredAt)))
            }

        case "thread.approval-opened", "thread.approval-resolved":
            guard let update = event.payload.approval else { break }
            var timeline = thread.timeline
            let resolved = event.type == "thread.approval-resolved"
            if let index = timeline.firstIndex(where: { $0.approval?.requestID == update.requestID }), let old = timeline[index].approval {
                let approval = old.with(
                    args: resolved ? nil : .some(update.args),
                    decision: .some(resolved ? update.decision : nil),
                    optionID: .some(resolved ? update.optionID : nil),
                    options: resolved ? nil : .some(update.options),
                    status: resolved ? "resolved" : "pending",
                    turnID: update.turnID.map(Optional.some),
                    updatedAt: event.occurredAt
                )
                timeline[index] = timeline[index].with(approval: .some(approval))
            } else {
                let approval = Approval(args: update.args, createdAt: event.occurredAt, decision: resolved ? update.decision : nil, optionID: resolved ? update.optionID : nil, options: resolved ? nil : update.options, requestID: update.requestID, status: resolved ? "resolved" : "pending", turnID: update.turnID, updatedAt: event.occurredAt)
                timeline.append(TimelineEntry(approval: approval, item: nil, kind: "approval", message: nil))
            }
            thread = thread.with(timeline: timeline)

        case "thread.approval-response-requested":
            guard let requestID = event.payload.requestID else { break }
            var timeline = thread.timeline
            if let index = timeline.firstIndex(where: { $0.approval?.requestID == requestID }), let old = timeline[index].approval {
                timeline[index] = timeline[index].with(approval: .some(old.with(decision: .some(event.payload.decision), optionID: .some(event.payload.optionID), updatedAt: event.occurredAt)))
                thread = thread.with(timeline: timeline)
            }

        case "thread.config-options-updated":
            let session = ensureSession(thread, event).with(configOptions: .some(event.payload.configOptions ?? []), updatedAt: event.occurredAt)
            if let model = event.payload.modelSelection {
                thread = thread.with(modelSelection: .some(model))
            }
            thread = thread.with(session: .some(session))

        case "thread.slash-commands-updated":
            let session = ensureSession(thread, event).with(slashCommands: .some(event.payload.slashCommands ?? []), updatedAt: event.occurredAt)
            thread = thread.with(session: .some(session))

        case "thread.token-usage-updated":
            let session = ensureSession(thread, event).with(tokenUsage: .some(event.payload.tokenUsage), updatedAt: event.occurredAt)
            thread = thread.with(session: .some(session))

        default:
            break
        }
        return thread
    }

    private static func applyProviderSelection(_ payload: EventPayload, to thread: Thread) -> Thread {
        let providerID = nonEmpty(payload.providerInstanceID)
        let staleSession = providerID != nil
            && nonEmpty(thread.session?.providerInstanceID) != nil
            && thread.session?.providerInstanceID != providerID
        let clearSession = payload.sessionCleared == true || staleSession

        if let providerID {
            return thread.with(
                modelSelection: .some(payload.modelSelection),
                providerInstanceID: .some(providerID),
                session: clearSession ? .some(nil) : nil
            )
        }
        if let model = payload.modelSelection {
            return thread.with(
                modelSelection: .some(model),
                session: clearSession ? .some(nil) : nil
            )
        }
        return clearSession ? thread.with(session: .some(nil)) : thread
    }

    private static func ensureSession(_ thread: Thread, _ event: Event) -> SessionBinding {
        if let session = thread.session { return session }
        return SessionBinding(activeTurnID: nil, configOptions: nil, cwd: thread.cwd, lastError: nil, provider: nil, providerInstanceID: event.payload.providerInstanceID ?? thread.providerInstanceID ?? "", providerName: nil, slashCommands: nil, status: "starting", stopRequested: false, threadID: thread.id, tokenUsage: nil, updatedAt: event.occurredAt)
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
