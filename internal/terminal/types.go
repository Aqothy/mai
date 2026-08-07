// Package terminal owns interactive PTY shell sessions for terminal threads.
//
// The package is deliberately independent of agent orchestration: it must not
// import internal/orchestration, internal/providerservice, internal/provider,
// or internal/adapters/acp. Terminals are not providers and terminal input is
// not an orchestration command.
package terminal

import (
	"errors"
	"fmt"
)

// Status describes the lifecycle of one terminal run.
type Status string

const (
	// StatusStarting means shell spawn is in progress.
	StatusStarting Status = "starting"
	// StatusRunning means the PTY accepts input.
	StatusRunning Status = "running"
	// StatusExited means the process ended naturally; output remains
	// available for this daemon run.
	StatusExited Status = "exited"
	// StatusStopped means no live run exists, normally after an explicit
	// termination or a daemon restart.
	StatusStopped Status = "stopped"
	// StatusError means spawn or a PTY operation failed.
	StatusError Status = "error"
)

// Typed errors for stable RPC mapping. Messages must stay useful to a person
// and must never include terminal input or output contents.
var (
	ErrNotFound          = errors.New("terminal not found")
	ErrInvalidCwd        = errors.New("terminal cwd is not an existing directory")
	ErrInvalidDimensions = errors.New("terminal dimensions out of range")
	ErrNotRunning        = errors.New("terminal is not running")
	ErrAlreadyExists     = errors.New("terminal session already exists; use relaunch")
	ErrAlreadyRunning    = errors.New("terminal already has a live run")
	ErrServiceClosed     = errors.New("terminal service is closed")
)

// StreamItemKind discriminates terminal.subscribe notifications.
type StreamItemKind string

const (
	// StreamItemOutput carries raw terminal output bytes.
	StreamItemOutput StreamItemKind = "output"
	// StreamItemStatus reports a lifecycle status change for a run.
	StreamItemStatus StreamItemKind = "status"
)

// GhosttySnapshotFormat identifies the exact native snapshot contract shared
// by the daemon and client binary. GHOSTSNP v1 is intentionally not stable
// across arbitrary Ghostty revisions, so compatibility is pinned to the core
// commit used by both builds.
const GhosttySnapshotFormat = "ghostty-gsn-v1-7a9c369cf5da72d41946f683c48b0466a210cb7e"

const (
	minColumns = 2
	maxColumns = 500
	minRows    = 1
	maxRows    = 300
)

// ValidateSize checks the grid bounds shared by create, attach, and resize.
func ValidateSize(columns, rows uint16) error {
	if columns < minColumns || columns > maxColumns || rows < minRows || rows > maxRows {
		return fmt.Errorf("%w: %dx%d (columns %d-%d, rows %d-%d)",
			ErrInvalidDimensions, columns, rows, minColumns, maxColumns, minRows, maxRows)
	}
	return nil
}

// Events receives session output and lifecycle changes. Callbacks are invoked
// serially by the session in output order. A bounded downstream wait is
// allowed so slow clients apply PTY backpressure instead of losing bytes.
type Events struct {
	// Output delivers one ordered PTY output chunk. The slice is owned by the
	// callee.
	Output func(terminalID, runID string, seq uint64, data []byte)
	// Exit reports the end of a run after all output has been delivered.
	// exitCode is nil when the process could not report one.
	Exit func(terminalID, runID string, seq uint64, status Status, exitCode *int)
	// Agent reports a changed semantic agent state. Reports carry only the
	// normalized title and semantic fields, never screen evidence, and are
	// already deduplicated by the detector.
	Agent func(terminalID, runID string, report AgentReport)
}
