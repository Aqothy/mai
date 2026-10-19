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

type TerminalProgramState = terminal.ProgramState
type TerminalProgramNeed = terminal.ProgramNeed
type TerminalColorScheme = terminal.ColorScheme

// TerminalSummary describes one terminal thread for lists and snapshots.
// Fields other than identity/title/cwd reflect the current live run and are
// not durable. The program fields are what the running program reports about
// itself; their text comes from the program and is sanitized, not trusted.
type TerminalSummary struct {
	TerminalID string         `json:"terminalId"`
	Title      string         `json:"title"`
	Cwd        string         `json:"cwd"`
	Status     TerminalStatus `json:"status"`
	ExitCode   *int           `json:"exitCode,omitempty"`
	CreatedAt  time.Time      `json:"createdAt"`
	UpdatedAt  time.Time      `json:"updatedAt"`

	// ProgramTitle is the window title the program set (OSC 0/2), without
	// control characters or spinner frames, capped at 128 scalars.
	ProgramTitle string `json:"programTitle,omitempty"`
	// Pwd is the working directory the shell reported (OSC 7).
	Pwd string `json:"pwd,omitempty"`
	// ProgramStatus is the program's most pressing status report (OSC
	// 7501), if it sends any.
	ProgramStatus *TerminalProgramStatus `json:"programStatus,omitempty"`
}

// TerminalProgramStatus is a program's report about what it is doing
// (the program status protocol, OSC 7501).
type TerminalProgramStatus struct {
	State TerminalProgramState `json:"state"`
	// Need is what a blocked program needs, when it said.
	Need TerminalProgramNeed `json:"need,omitempty"`
	// Progress is 0-100; absent when the program gave no percentage.
	Progress *int `json:"progress,omitempty"`
	// App names the program for grouping or an icon, not for display.
	App string `json:"app,omitempty"`
	// Title labels the report.
	Title string `json:"title,omitempty"`
	// Message is one line about what the program is doing.
	Message   string    `json:"message,omitempty"`
	UpdatedAt time.Time `json:"updatedAt"`
}

// TerminalAppearance is a view's theme. The daemon answers the program's
// color and light/dark queries (OSC 10/11/4, CSI ? 996 n) with the
// appearance of the view that last attached or resized.
type TerminalAppearance struct {
	ColorScheme TerminalColorScheme `json:"colorScheme"`
	// Foreground and Background are "#rrggbb".
	Foreground string `json:"foreground"`
	Background string `json:"background"`
	// Palette overrides the first entries of the 256-color palette, as
	// "#rrggbb".
	Palette []string `json:"palette,omitempty"`
}

// TerminalAttachSnapshot is the authoritative attach point for one run.
// Snapshot is a complete native Ghostty terminal model captured at Sequence
// and Columns by Rows. Clients must validate SnapshotFormat, install Snapshot
// transactionally, then consume only live output whose run ID matches and
// whose sequence is greater than Sequence.
type TerminalAttachSnapshot struct {
	Terminal       TerminalSummary `json:"terminal"`
	RunID          string          `json:"runId"`
	Sequence       uint64          `json:"sequence"`
	Columns        uint16          `json:"columns"`
	Rows           uint16          `json:"rows"`
	SnapshotFormat string          `json:"snapshotFormat"`
	Snapshot       []byte          `json:"snapshot"`
}

// TerminalStreamItem is one terminal.subscribe notification payload.
type TerminalStreamItem struct {
	Kind       TerminalStreamItemKind `json:"kind"`
	TerminalID string                 `json:"terminalId"`
	RunID      string                 `json:"runId,omitempty"`
	Sequence   uint64                 `json:"sequence,omitempty"`
	Data       []byte                 `json:"data,omitempty"`
	// Columns and Rows are the grid of a resized item.
	Columns  uint16         `json:"columns,omitempty"`
	Rows     uint16         `json:"rows,omitempty"`
	Status   TerminalStatus `json:"status,omitempty"`
	ExitCode *int           `json:"exitCode,omitempty"`
	Message  string         `json:"message,omitempty"`
}

type TerminalCreateParams struct {
	Title        string             `json:"title,omitempty"`
	Cwd          string             `json:"cwd"`
	Columns      uint16             `json:"columns"`
	Rows         uint16             `json:"rows"`
	AttachmentID string             `json:"attachmentId"`
	Appearance   TerminalAppearance `json:"appearance"`
}

type TerminalIDParams struct {
	TerminalID string `json:"terminalId"`
}

// TerminalAttachParams attaches the calling client to a terminal (or, for
// terminal.relaunch, to a fresh run) with the client's measured grid.
// AttachmentID is client-generated and names the view that owns the
// attachment; a connection has one attachment per terminal, and a newer one
// replaces the older.
type TerminalAttachParams struct {
	TerminalID   string             `json:"terminalId"`
	Columns      uint16             `json:"columns"`
	Rows         uint16             `json:"rows"`
	AttachmentID string             `json:"attachmentId"`
	Appearance   TerminalAppearance `json:"appearance"`
}

// TerminalDetachParams releases control without terminating the shell. A
// detach for an attachment that a newer one already replaced is ignored.
type TerminalDetachParams struct {
	TerminalID   string `json:"terminalId"`
	AttachmentID string `json:"attachmentId"`
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

// TerminalResizeParams asks for the view's grid. A resize claims the size:
// the PTY takes the grid of the view that last attached or resized, and the
// daemon answers queries with that view's appearance.
type TerminalResizeParams struct {
	TerminalID string             `json:"terminalId"`
	RunID      string             `json:"runId"`
	Columns    uint16             `json:"columns"`
	Rows       uint16             `json:"rows"`
	Appearance TerminalAppearance `json:"appearance"`
}
