// Code generated from api/wire/vocabulary.go. DO NOT EDIT.
//
// Closed string vocabularies the daemon sends. The wire models keep these
// fields as plain String on purpose, so an unknown value from a newer daemon
// still decodes; use `Maid<Name>(rawValue:)` to branch and treat nil as
// "unrecognized" rather than as an error.

/// Why thread.command refused a command: the data.code of its JSON-RPC error.
public enum MaidCommandErrorCode: String, Codable, Sendable, CaseIterable {
    case outOfScope = "out_of_scope"
    case ceilingExceeded = "ceiling_exceeded"
    case depthExceeded = "depth_exceeded"
    case agentUnavailable = "agent_unavailable"
    case notFound = "not_found"
    case notRunning = "not_running"
    case permissionRequest = "permission_request"
    case invalid = "invalid"
}

/// Where an ACP agent's definition comes from.
public enum MaidACPAgentSource: String, Codable, Sendable, CaseIterable {
    case registry = "registry"
    case custom = "custom"
}

/// What the daemon is doing with an ACP agent's files. Failed says the last install or update failed; an installed version keeps working.
public enum MaidACPAgentState: String, Codable, Sendable, CaseIterable {
    case notInstalled = "notInstalled"
    case installing = "installing"
    case installed = "installed"
    case updating = "updating"
    case failed = "failed"
}

/// Why an ACP agent can't be installed on the daemon's machine.
public enum MaidACPAgentBlocker: String, Codable, Sendable, CaseIterable {
    case platform = "platform"
    case node = "node"
    case uv = "uv"
}

/// What a thread is doing, derived from its turns, requests and queue.
public enum MaidThreadStatus: String, Codable, Sendable, CaseIterable {
    case running = "running"
    case waiting = "waiting"
    case held = "held"
    case idle = "idle"
}

/// How a thread began: a person's chat, a spawned child, or a provider's own subagent.
public enum MaidOriginKind: String, Codable, Sendable, CaseIterable {
    case user = "user"
    case spawn = "spawn"
    case native = "native"
}

/// Why a thread's queue waits, and so who may release it; absent when nothing holds it.
public enum MaidHold: String, Codable, Sendable, CaseIterable {
    case stoppedPerson = "stoppedPerson"
    case stoppedAgent = "stoppedAgent"
    case failed = "failed"
    case hops = "hops"
}

/// What started a turn.
public enum MaidStartedBy: String, Codable, Sendable, CaseIterable {
    case delivery = "delivery"
    case provider = "provider"
    case found = "found"
}

/// Who a delivery is from: a person's prompt, an agent's message, a reply, a daemon notice.
public enum MaidDeliveryKind: String, Codable, Sendable, CaseIterable {
    case prompt = "prompt"
    case message = "message"
    case reply = "reply"
    case notice = "notice"
}

/// How a delivery goes: as the next turn, or into the running one.
public enum MaidDeliveryMode: String, Codable, Sendable, CaseIterable {
    case queue = "queue"
    case steer = "steer"
}

/// Where a delivery is on its way to the agent.
public enum MaidDeliveryState: String, Codable, Sendable, CaseIterable {
    case queued = "queued"
    case sending = "sending"
    case delivered = "delivered"
    case refused = "refused"
    case cancelled = "cancelled"
}

/// Who sent a delivery or issued a command.
public enum MaidActorKind: String, Codable, Sendable, CaseIterable {
    case device = "device"
    case agent = "agent"
    case daemon = "daemon"
}

/// When a spawned thread's parent hears from it.
public enum MaidWakeMode: String, Codable, Sendable, CaseIterable {
    case settled = "settled"
    case needsInput = "needsInput"
}

/// Which change a thread.event notification carries.
public enum MaidThreadEventKind: String, Codable, Sendable, CaseIterable {
    case entry = "entry"
    case text = "text"
    case turn = "turn"
    case delivery = "delivery"
    case request = "request"
    case resolved = "resolved"
    case participant = "participant"
    case thread = "thread"
    case child = "child"
    case plan = "plan"
    case refresh = "refresh"
    case removed = "removed"
}

/// Whether a thread.list item is the snapshot, an upsert or a removal.
public enum MaidThreadListKind: String, Codable, Sendable, CaseIterable {
    case snapshot = "snapshot"
    case upsert = "upsert"
    case remove = "remove"
}

/// Lifecycle state of a turn.
public enum MaidTurnState: String, Codable, Sendable, CaseIterable {
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case interrupted = "interrupted"
}

/// What streamed text adds to.
public enum MaidStreamKind: String, Codable, Sendable, CaseIterable {
    case assistant = "assistant"
    case reasoning = "reasoning"
}

/// What a block maiD wrapped around text it sent an agent carries.
public enum MaidEnvelopeKind: String, Codable, Sendable, CaseIterable {
    case handoff = "handoff"
    case message = "message"
    case reply = "reply"
    case notice = "notice"
    case instructions = "instructions"
}

/// How well a provider rebuilds a session run outside maiD from its own record.
public enum MaidHistoryQuality: String, Codable, Sendable, CaseIterable {
    case none = "none"
    case lossy = "lossy"
    case exact = "exact"
}

/// Client decision on an approval request.
public enum MaidApprovalDecision: String, Codable, Sendable, CaseIterable {
    case accept = "accept"
    case acceptForSession = "acceptForSession"
    case decline = "decline"
    case cancel = "cancel"
}

/// How a sign-in method or challenge proceeds.
public enum MaidAuthKind: String, Codable, Sendable, CaseIterable {
    case browser = "browser"
    case deviceCode = "device-code"
    case secret = "secret"
    case terminal = "terminal"
}

/// What a message or tool attachment carries.
public enum MaidAttachmentKind: String, Codable, Sendable, CaseIterable {
    case image = "image"
    case audio = "audio"
    case resource = "resource"
    case resourceLink = "resource_link"
}

/// Why a completed turn ended early; absent when it finished normally.
public enum MaidStopReason: String, Codable, Sendable, CaseIterable {
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal = "refusal"
}

/// How to render tool output; absent means plain text.
public enum MaidOutputFormat: String, Codable, Sendable, CaseIterable {
    case markdown = "markdown"
}

/// Input a user-input question takes.
public enum MaidQuestionKind: String, Codable, Sendable, CaseIterable {
    case text = "text"
    case number = "number"
    case integer = "integer"
    case choice = "choice"
}

/// How much a session may do without asking, from read_only to full; absent when its mode isn't mapped.
public enum MaidAccessLevel: String, Codable, Sendable, CaseIterable {
    case readOnly = "read_only"
    case ask = "ask"
    case edit = "edit"
    case full = "full"
}

/// Kind of an entry of a session's conversation.
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
    case webSearch = "web_search"
    case imageView = "image_view"
    case imageGeneration = "image_generation"
    case contextCompaction = "context_compaction"
    case envelope = "envelope"
    case request = "request"
}

/// Lifecycle status of an entry.
public enum MaidItemStatus: String, Codable, Sendable, CaseIterable {
    case inProgress = "in_progress"
    case completed = "completed"
    case failed = "failed"
    case interrupted = "interrupted"
    case declined = "declined"
}

/// Status of the goal a provider pursues over its turns.
public enum MaidGoalStatus: String, Codable, Sendable, CaseIterable {
    case active = "active"
    case paused = "paused"
    case blocked = "blocked"
    case usageLimited = "usage_limited"
    case budgetLimited = "budget_limited"
    case complete = "complete"
}

/// Action a provider explicitly stated for a tool call; absent when it stated none.
public enum MaidToolAction: String, Codable, Sendable, CaseIterable {
    case read = "read"
    case search = "search"
}

/// Kind of a normalized file mutation produced by a tool.
public enum MaidFileChangeKind: String, Codable, Sendable, CaseIterable {
    case add = "add"
    case update = "update"
    case delete = "delete"
    case move = "move"
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

/// Lifecycle of a provider instance: configured but never started this run, alive, or exited.
public enum MaidInstanceStatus: String, Codable, Sendable, CaseIterable {
    case configured = "configured"
    case initialized = "initialized"
    case exited = "exited"
}

/// Provider authentication state. Unknown means the agent advertises auth methods but exposes no probe.
public enum MaidAuthStatus: String, Codable, Sendable, CaseIterable {
    case unknown = "unknown"
    case authenticated = "authenticated"
    case unauthenticated = "unauthenticated"
}

/// Payload discriminator of a terminal.subscribeList snapshot or update.
public enum MaidTerminalListStreamItemKind: String, Codable, Sendable, CaseIterable {
    case snapshot = "snapshot"
    case terminalUpserted = "terminal-upserted"
    case terminalRemoved = "terminal-removed"
}

/// What a terminal's program reported doing (OSC 7501). Blocked renders as needing the user; unknown future values render neutrally.
public enum MaidTerminalProgramState: String, Codable, Sendable, CaseIterable {
    case idle = "idle"
    case working = "working"
    case done = "done"
    case blocked = "blocked"
    case error = "error"
}

/// What a blocked terminal program needs from the user. Unknown future values render like no need given.
public enum MaidTerminalProgramNeed: String, Codable, Sendable, CaseIterable {
    case permission = "permission"
    case answer = "answer"
    case auth = "auth"
}

/// Whether a terminal view's theme is light or dark.
public enum MaidTerminalColorScheme: String, Codable, Sendable, CaseIterable {
    case light = "light"
    case dark = "dark"
}
