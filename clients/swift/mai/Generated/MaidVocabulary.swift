// Code generated from api/wire/vocabulary.go. DO NOT EDIT.
//
// Closed string vocabularies the daemon sends. The wire models keep these
// fields as plain String on purpose, so an unknown value from a newer daemon
// still decodes; use `Maid<Name>(rawValue:)` to branch and treat nil as
// "unrecognized" rather than as an error.

/// Type discriminator of a thread event delivered on orchestration.subscribeThread.
public enum MaidEventType: String, Codable, Sendable, CaseIterable {
    case threadCreated = "thread.created"
    case threadImported = "thread.imported"
    case threadMetaUpdated = "thread.meta-updated"
    case threadMessageSent = "thread.message-sent"
    case threadTurnStartRequested = "thread.turn-start-requested"
    case threadTurnInterruptRequested = "thread.turn-interrupt-requested"
    case threadTurnInterruptConfirmed = "thread.turn-interrupt-confirmed"
    case threadTurnInterruptFailed = "thread.turn-interrupt-failed"
    case threadApprovalResponseRequested = "thread.approval-response-requested"
    case threadSessionPrepareRequested = "thread.session-prepare-requested"
    case threadSessionStopRequested = "thread.session-stop-requested"
    case threadSessionStopFailed = "thread.session-stop-failed"
    case threadConfigOptionSetRequested = "thread.config-option-set-requested"
    case threadSessionStatusSet = "thread.session-status-set"
    case threadItemUpserted = "thread.item-upserted"
    case threadPlanUpdated = "thread.plan-updated"
    case threadApprovalOpened = "thread.approval-opened"
    case threadApprovalResolved = "thread.approval-resolved"
    case threadConfigOptionsUpdated = "thread.config-options-updated"
    case threadSlashCommandsUpdated = "thread.slash-commands-updated"
    case threadTokenUsageUpdated = "thread.token-usage-updated"
    case threadHistoryReplayCompleted = "thread.history-replay-completed"
}

/// Type discriminator of a client command sent to orchestration.dispatchCommand.
public enum MaidCommandType: String, Codable, Sendable, CaseIterable {
    case threadCreate = "thread.create"
    case threadStart = "thread.start"
    case threadMetaUpdate = "thread.meta.update"
    case threadTurnStart = "thread.turn.start"
    case threadTurnRetry = "thread.turn.retry"
    case threadTurnInterrupt = "thread.turn.interrupt"
    case threadApprovalRespond = "thread.approval.respond"
    case threadSessionPrepare = "thread.session.prepare"
    case threadSessionStop = "thread.session.stop"
    case threadConfigOptionSet = "thread.config-option.set"
}

/// Payload discriminator of a subscription snapshot or update.
public enum MaidStreamItemKind: String, Codable, Sendable, CaseIterable {
    case snapshot = "snapshot"
    case event = "event"
    case threadUpserted = "thread-upserted"
}

/// Origin of a thread event.
public enum MaidActorKind: String, Codable, Sendable, CaseIterable {
    case client = "client"
    case server = "server"
    case provider = "provider"
}

/// Which payload of a timeline entry's tagged union is populated.
public enum MaidTimelineEntryKind: String, Codable, Sendable, CaseIterable {
    case message = "message"
    case item = "item"
    case approval = "approval"
}

/// Author of a timeline message.
public enum MaidMessageRole: String, Codable, Sendable, CaseIterable {
    case user = "user"
    case assistant = "assistant"
}

/// Lifecycle state of a thread's latest turn.
public enum MaidTurnState: String, Codable, Sendable, CaseIterable {
    case running = "running"
    case interrupted = "interrupted"
    case completed = "completed"
    case error = "error"
}

/// Status of a thread's provider session binding.
public enum MaidSessionStatus: String, Codable, Sendable, CaseIterable {
    case starting = "starting"
    case running = "running"
    case ready = "ready"
    case interrupted = "interrupted"
    case stopped = "stopped"
    case error = "error"
}

/// Whether an approval request is still awaiting a decision.
public enum MaidApprovalStatus: String, Codable, Sendable, CaseIterable {
    case pending = "pending"
    case resolved = "resolved"
}

/// Client decision on an approval request.
public enum MaidApprovalDecision: String, Codable, Sendable, CaseIterable {
    case accept = "accept"
    case acceptForSession = "acceptForSession"
    case decline = "decline"
    case cancel = "cancel"
}

/// What an approval request is asking permission for.
public enum MaidRequestType: String, Codable, Sendable, CaseIterable {
    case commandExecutionApproval = "command_execution_approval"
    case fileReadApproval = "file_read_approval"
    case fileChangeApproval = "file_change_approval"
    case dynamicToolCall = "dynamic_tool_call"
}

/// Kind of a non-message timeline item.
public enum MaidItemKind: String, Codable, Sendable, CaseIterable {
    case userMessage = "user_message"
    case assistantMessage = "assistant_message"
    case reasoning = "reasoning"
    case commandExecution = "command_execution"
    case fileChange = "file_change"
    case mcpToolCall = "mcp_tool_call"
    case toolCall = "tool_call"
    case warning = "warning"
    case error = "error"
}

/// Lifecycle status of a timeline item.
public enum MaidItemStatus: String, Codable, Sendable, CaseIterable {
    case inProgress = "in_progress"
    case completed = "completed"
    case failed = "failed"
    case interrupted = "interrupted"
    case declined = "declined"
}

/// Control a session config option renders as.
public enum MaidConfigOptionType: String, Codable, Sendable, CaseIterable {
    case select = "select"
    case boolean = "boolean"
}

/// Advisory grouping hint for a session config option; unknown values must be tolerated.
public enum MaidConfigOptionCategory: String, Codable, Sendable, CaseIterable {
    case model = "model"
    case mode = "mode"
    case modelConfig = "model_config"
    case thoughtLevel = "thought_level"
    case other = "other"
}

/// Status of an execution-plan checklist entry.
public enum MaidPlanEntryStatus: String, Codable, Sendable, CaseIterable {
    case pending = "pending"
    case inProgress = "in_progress"
    case completed = "completed"
}

/// Priority of an execution-plan checklist entry.
public enum MaidPlanEntryPriority: String, Codable, Sendable, CaseIterable {
    case high = "high"
    case medium = "medium"
    case low = "low"
}

/// Whether a provider instance's process is alive.
public enum MaidInstanceStatus: String, Codable, Sendable, CaseIterable {
    case initialized = "initialized"
    case exited = "exited"
}

/// Provider authentication state. Unknown means the agent advertises auth methods but exposes no probe.
public enum MaidAuthStatus: String, Codable, Sendable, CaseIterable {
    case unknown = "unknown"
    case authenticated = "authenticated"
    case unauthenticated = "unauthenticated"
}

/// Whether a provider can change the active model for a thread.
public enum MaidModelSwitchSupport: String, Codable, Sendable, CaseIterable {
    case unsupported = "unsupported"
    case inSession = "in-session"
}
