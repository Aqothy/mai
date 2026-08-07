package wire

import (
	"time"

	"github.com/Aqothy/maiD/internal/terminal"
)

// Terminal thread methods. terminal.write, terminal.resize, and
// terminal.detach are sent by clients as JSON-RPC notifications;
// terminal.subscribe is the server-to-client stream method registered by
// terminal.create, terminal.attach, and terminal.relaunch.
const (
	MethodTerminalCreate        = "terminal.create"
	MethodTerminalAttach        = "terminal.attach"
	MethodTerminalRelaunch      = "terminal.relaunch"
	MethodTerminalDetach        = "terminal.detach"
	MethodTerminalRename        = "terminal.rename"
	MethodTerminalTerminate     = "terminal.terminate"
	MethodTerminalDelete        = "terminal.delete"
	MethodTerminalWrite         = "terminal.write"
	MethodTerminalResize        = "terminal.resize"
	MethodTerminalSubscribe     = "terminal.subscribe"
	MethodTerminalSubscribeList = "terminal.subscribeList"
)

// TerminalListStreamItemKind discriminates terminal.subscribeList payloads.
type TerminalListStreamItemKind string

const (
	// TerminalListItemSnapshot carries every terminal summary.
	TerminalListItemSnapshot TerminalListStreamItemKind = "snapshot"
	// TerminalListItemUpserted carries one created/updated summary.
	TerminalListItemUpserted TerminalListStreamItemKind = "terminal-upserted"
	// TerminalListItemRemoved carries one deleted terminal id.
	TerminalListItemRemoved TerminalListStreamItemKind = "terminal-removed"
)

// TerminalListStreamItem is one terminal.subscribeList snapshot or update.
// The server publishes updates only for identity and lifecycle changes,
// never for raw output, input, resize, or attach.
type TerminalListStreamItem struct {
	Kind       TerminalListStreamItemKind `json:"kind"`
	Terminals  []TerminalSummary          `json:"terminals,omitempty"`
	Terminal   *TerminalSummary           `json:"terminal,omitempty"`
	TerminalID string                     `json:"terminalId,omitempty"`
}

// Client-visible terminal vocabularies.
type TerminalStatus = terminal.Status
type TerminalStreamItemKind = terminal.StreamItemKind

// TerminalAgentKind is an open label naming the detected foreground agent
// ("codex", "claude", ...). Clients must tolerate values they do not know
// and treat them as display labels, not behavior switches.
type TerminalAgentKind = terminal.AgentKind

// TerminalAgentActivity is the closed semantic activity vocabulary; see the
// TerminalAgentActivity vocabulary definition.
type TerminalAgentActivity = terminal.AgentActivityState

// TerminalSummary describes one terminal thread for lists and snapshots.
// Fields other than identity/title/cwd reflect the current live run and are
// not durable. The agent fields are the detector's semantic result only;
// screen evidence and raw titles never cross the wire.
type TerminalSummary struct {
	TerminalID string         `json:"terminalId"`
	Title      string         `json:"title"`
	Cwd        string         `json:"cwd"`
	Status     TerminalStatus `json:"status"`
	Columns    uint16         `json:"columns"`
	Rows       uint16         `json:"rows"`
	ExitCode   *int           `json:"exitCode,omitempty"`
	CreatedAt  time.Time      `json:"createdAt"`
	UpdatedAt  time.Time      `json:"updatedAt"`

	// ObservedTitle is the normalized terminal title (control characters
	// and spinner frames removed, capped at 128 scalars).
	ObservedTitle string `json:"observedTitle,omitempty"`
	// AgentKind names the detected foreground agent; empty when none.
	AgentKind TerminalAgentKind `json:"agentKind,omitempty"`
	// AgentActivity is the semantic agent state for the current run.
	AgentActivity TerminalAgentActivity `json:"agentActivity,omitempty"`
	// AgentActivityUpdatedAt is when the semantic activity last changed.
	AgentActivityUpdatedAt *time.Time `json:"agentActivityUpdatedAt,omitempty"`
}

// TerminalAttachSnapshot is the authoritative attach point for one run.
// Clients apply the replay bytes, then consume only live output items whose
// run ID matches and whose sequence is greater than Sequence.
type TerminalAttachSnapshot struct {
	Terminal        TerminalSummary `json:"terminal"`
	RunID           string          `json:"runId"`
	Sequence        uint64          `json:"sequence"`
	Replay          []byte          `json:"replay,omitempty"`
	ReplayTruncated bool            `json:"replayTruncated,omitempty"`
}

// TerminalStreamItem is one terminal.subscribe notification payload.
type TerminalStreamItem struct {
	Kind       TerminalStreamItemKind `json:"kind"`
	TerminalID string                 `json:"terminalId"`
	RunID      string                 `json:"runId,omitempty"`
	Sequence   uint64                 `json:"sequence,omitempty"`
	Data       []byte                 `json:"data,omitempty"`
	Status     TerminalStatus         `json:"status,omitempty"`
	ExitCode   *int                   `json:"exitCode,omitempty"`
	Message    string                 `json:"message,omitempty"`
}

type TerminalCreateParams struct {
	Title   string `json:"title,omitempty"`
	Cwd     string `json:"cwd"`
	Columns uint16 `json:"columns"`
	Rows    uint16 `json:"rows"`
}

type TerminalIDParams struct {
	TerminalID string `json:"terminalId"`
}

// TerminalAttachParams attaches the calling client to a terminal (or, for
// terminal.relaunch, to a fresh run) with the client's measured grid.
type TerminalAttachParams struct {
	TerminalID string `json:"terminalId"`
	Columns    uint16 `json:"columns"`
	Rows       uint16 `json:"rows"`
}

// TerminalDetachParams releases control without terminating the shell. RunID
// fences the detach so it cannot release a newer attachment or run.
type TerminalDetachParams struct {
	TerminalID string `json:"terminalId"`
	RunID      string `json:"runId"`
}

// TerminalRenameParams gives a terminal a user-chosen title.
type TerminalRenameParams struct {
	TerminalID string `json:"terminalId"`
	Title      string `json:"title"`
}

// TerminalWriteParams carries terminal input bytes. Data is base64-encoded by
// the JSON coders; terminal bytes are not necessarily valid UTF-8.
type TerminalWriteParams struct {
	TerminalID string `json:"terminalId"`
	RunID      string `json:"runId"`
	Data       []byte `json:"data"`
}

type TerminalResizeParams struct {
	TerminalID string `json:"terminalId"`
	RunID      string `json:"runId"`
	Columns    uint16 `json:"columns"`
	Rows       uint16 `json:"rows"`
}
