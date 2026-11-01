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
	ErrInputQueueFull    = errors.New("terminal input dropped: the program is not reading input")
	ErrAlreadyExists     = errors.New("terminal session already exists; use relaunch")
	ErrAlreadyRunning    = errors.New("terminal already has a live run")
	ErrServiceClosed     = errors.New("terminal service is closed")
)

// ColorScheme is whether a view's theme is light or dark.
type ColorScheme string

const (
	ColorSchemeLight ColorScheme = "light"
	ColorSchemeDark  ColorScheme = "dark"
)

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

// Events receives a run's output and lifecycle changes. Output, Resized and
// Exit are called in event order while the session holds its event lock, so
// they must not block or wait for anything that calls into the session.
type Events struct {
	// Output delivers one ordered PTY output chunk. The slice must not be
	// modified; it may be shared read-only.
	Output func(session *Session, data []byte)
	// Resized reports a new grid at its place in the output.
	Resized func(session *Session, columns, rows uint16)
	// Exit reports the end of a run after all output has been delivered; no
	// event follows it. exitCode is nil when the process could not report
	// one.
	Exit func(session *Session, status Status, exitCode *int)
	// ProgramChanged reports a changed title, working directory or program
	// status; read it with Session.Program.
	ProgramChanged func(terminalID string)
}
