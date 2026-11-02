package wire

import (
	"time"

	"github.com/Aqothy/maiD/internal/terminal"
)

// Terminal thread methods. terminal.write, terminal.resize, terminal.focus,
// and terminal.detach are sent by clients as JSON-RPC notifications.
// terminal.create, terminal.attach, and terminal.relaunch return a ticket for
// the view's terminal stream.
const (
	MethodTerminalCreate        = "terminal.create"
	MethodTerminalAttach        = "terminal.attach"
	MethodTerminalRelaunch      = "terminal.relaunch"
	MethodTerminalDetach        = "terminal.detach"
	MethodTerminalRename        = "terminal.rename"
	MethodTerminalDelete        = "terminal.delete"
	MethodTerminalWrite         = "terminal.write"
	MethodTerminalResize        = "terminal.resize"
	MethodTerminalFocus         = "terminal.focus"
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
// appearance of the active view (see TerminalAttachParams).
type TerminalAppearance struct {
	ColorScheme TerminalColorScheme `json:"colorScheme"`
	// Foreground and Background are "#rrggbb".
	Foreground string `json:"foreground"`
	Background string `json:"background"`
	// Palette overrides the first entries of the 256-color palette, as
	// "#rrggbb".
	Palette []string `json:"palette,omitempty"`
}

// TerminalAttachResult answers terminal.create, terminal.attach and
// terminal.relaunch. StreamTicket opens the view's terminal stream (see
// TerminalStreamPath); it works once, within TerminalStreamTicketLifetime,
// for a stream opened while this connection and view are still attached.
// Issuing it closes the view's earlier stream.
type TerminalAttachResult struct {
	Terminal     TerminalSummary `json:"terminal"`
	StreamTicket string          `json:"streamTicket"`
}

// The terminal stream carries one view's terminal from the daemon, separate
// from the JSON-RPC connection so output never delays it. The client opens a
// WebSocket at TerminalStreamPath with subprotocol TerminalStreamSubprotocol
// and, within 5 seconds, sends one binary message: the 16 bytes of the ticket,
// decoded from unpadded base64url. It never sends anything else. Every later
// message is one binary record from the daemon: a TerminalStreamRecordKind
// byte, then its payload.
//
// Close codes: 1000 the view ended (detached, replaced by a new ticket, or its
// terminal removed by a delete or its shell exiting), don't reconnect; 1001 the
// daemon is shutting down or the view's connection closed, the connection's
// reconnect reattaches; 1002 or 1008 a protocol or handshake error; 1011 an
// internal error.
const (
	TerminalStreamPath           = "/terminal"
	TerminalStreamSubprotocol    = "maid.terminal.v1"
	TerminalStreamTicketLifetime = 30 * time.Second
)

// TerminalStreamRecordKind is the first byte of a terminal stream record.
type TerminalStreamRecordKind byte

const (
	// TerminalRecordSnapshot's payload is a TerminalStreamSnapshot (JSON). A
	// stream begins with one, and another can arrive at any time; it abandons
	// a partial snapshot and replaces the terminal.
	TerminalRecordSnapshot TerminalStreamRecordKind = 0x01
	// TerminalRecordSnapshotData's payload is the next part of the
	// snapshot, at most 64 KiB; the snapshot is complete once the parts add
	// up to its Size.
	TerminalRecordSnapshotData TerminalStreamRecordKind = 0x02
	// TerminalRecordOutput's payload is program output, at most 64 KiB.
	TerminalRecordOutput TerminalStreamRecordKind = 0x03
	// TerminalRecordResized's payload is a TerminalStreamResized (JSON).
	TerminalRecordResized TerminalStreamRecordKind = 0x04
	// TerminalRecordExited's payload is a TerminalStreamExited (JSON). The
	// stream stays open unless the exit removes the terminal, which can also
	// close it before this record is sent.
	TerminalRecordExited TerminalStreamRecordKind = 0x05
)

// TerminalStreamSnapshot starts a terminal stream, or replaces its terminal:
// after a relaunch, or when the client fell too far behind to be sent the
// output it missed. The next Size bytes of snapshot data are a complete
// native Ghostty terminal at the run's grid; clients validate SnapshotFormat
// and install it, then apply the records that follow.
type TerminalStreamSnapshot struct {
	RunID          string         `json:"runId"`
	Status         TerminalStatus `json:"status"`
	ExitCode       *int           `json:"exitCode,omitempty"`
	SnapshotFormat string         `json:"snapshotFormat"`
	Size           int            `json:"size"`
}

// TerminalStreamResized is the run's new grid at its place in the output.
type TerminalStreamResized struct {
	Columns uint16 `json:"columns"`
	Rows    uint16 `json:"rows"`
}

// TerminalStreamExited reports that the run ended: it exited, was stopped,
// or failed. No output follows.
type TerminalStreamExited struct {
	Status   TerminalStatus `json:"status"`
	ExitCode *int           `json:"exitCode,omitempty"`
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

// TerminalAttachParams attaches the calling client's view to a terminal with
// the grid that fits it. A terminal has one size: the active view's. A view
// becomes active when it creates or relaunches the terminal, attaches with
// Focus or while no other view is attached, sends terminal.focus, or writes;
// when it leaves, the view that was active before it takes over.
// AttachmentID is client-generated and names the view; a connection has one
// view per terminal, and a newer one replaces the older in its place.
type TerminalAttachParams struct {
	TerminalID   string             `json:"terminalId"`
	Columns      uint16             `json:"columns"`
	Rows         uint16             `json:"rows"`
	AttachmentID string             `json:"attachmentId"`
	Appearance   TerminalAppearance `json:"appearance"`
	// Focus is set when the user opens the terminal, and not when a view
	// attaches again (after a reconnect or another view's relaunch), so
	// reattaching never takes the size from the device in use.
	Focus bool `json:"focus,omitempty"`
}

// TerminalRelaunchParams starts a fresh run at the calling view's grid and
// attaches the view to it as the active view. If the terminal already has a
// live run, another client got there first and the view attaches to that one:
// a relaunch never ends a running shell.
type TerminalRelaunchParams struct {
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

// TerminalResizeParams reports the grid that now fits the calling view, and
// its appearance. The terminal takes them only while the view is active;
// otherwise the daemon keeps them for when the view becomes active.
type TerminalResizeParams struct {
	TerminalID string             `json:"terminalId"`
	Columns    uint16             `json:"columns"`
	Rows       uint16             `json:"rows"`
	Appearance TerminalAppearance `json:"appearance"`
}
