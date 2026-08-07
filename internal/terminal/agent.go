package terminal

import "time"

// AgentKind identifies which coding agent owns the terminal's foreground job.
// Identity is process-first: terminal text alone can name an agent only while
// process inspection reports a non-shell foreground job it cannot name.
type AgentKind string

// Named kinds are the canonical labels of the embedded rule manifests
// (agentrules.Labels lists them all); Codex and Claude have constants because
// tests and fixtures reference them directly.
const (
	// AgentNone means the login shell (or nothing) owns the foreground.
	AgentNone AgentKind = ""
	// AgentCodex is the Codex CLI.
	AgentCodex AgentKind = "codex"
	// AgentClaude is Claude Code.
	AgentClaude AgentKind = "claude"
	// AgentUnknown is a non-shell foreground job that process inspection
	// could not name. Generic title/progress evidence still applies, so
	// unrecognized agents keep useful Working/Needs-input badges.
	AgentUnknown AgentKind = "unknown"
)

// AgentActivityState is the semantic activity of a detected agent. It is
// separate from the shell lifecycle status: a running terminal may host an
// idle, working, or blocked agent, or no agent at all.
type AgentActivityState string

const (
	// AgentActivityNone means no agent is detected.
	AgentActivityNone AgentActivityState = "none"
	// AgentActivityIdle means the agent is waiting at its prompt.
	AgentActivityIdle AgentActivityState = "idle"
	// AgentActivityWorking means the agent is actively processing.
	AgentActivityWorking AgentActivityState = "working"
	// AgentActivityBlocked means the agent explicitly signaled that it needs
	// human input. UI wording maps this to "Needs input".
	AgentActivityBlocked AgentActivityState = "blocked"
	// AgentActivityDone means an agent that was working returned to idle or
	// to the shell while the terminal was detached. It persists until the
	// next explicit attach acknowledges it.
	AgentActivityDone AgentActivityState = "done"
	// AgentActivityUnknown means an agent is present but the evidence is
	// insufficient to claim a state. Never presented as a confident error.
	AgentActivityUnknown AgentActivityState = "unknown"
)

// AgentReport is the client-visible semantic result of detection. It carries
// no screen evidence and no raw titles; Title is normalized and bounded.
// Reports are process-local and never persisted.
type AgentReport struct {
	Kind     AgentKind
	Activity AgentActivityState
	// Title is the normalized observed terminal title: control characters
	// removed, whitespace collapsed, spinner frames stripped, capped at 128
	// Unicode scalars. Empty when no title has been observed.
	Title string
	// UpdatedAt is when Kind, Activity, or Title last changed.
	UpdatedAt time.Time
}
