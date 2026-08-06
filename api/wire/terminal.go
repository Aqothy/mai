package wire

import (
	"time"

	"github.com/Aqothy/maiD/internal/terminal"
)

// Terminal thread methods. terminal.write and terminal.resize are sent by
// clients as JSON-RPC notifications; terminal.subscribe is the server-to-client
// stream method registered by terminal.create (and later terminal.attach).
const (
	MethodTerminalCreate    = "terminal.create"
	MethodTerminalTerminate = "terminal.terminate"
	MethodTerminalWrite     = "terminal.write"
	MethodTerminalResize    = "terminal.resize"
	MethodTerminalSubscribe = "terminal.subscribe"
)

// Client-visible terminal vocabularies.
type TerminalStatus = terminal.Status
type TerminalStreamItemKind = terminal.StreamItemKind

// TerminalSummary describes one terminal thread for lists and snapshots.
// Fields other than identity/title/cwd reflect the current live run and are
// not durable.
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
