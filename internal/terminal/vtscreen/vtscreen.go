// Package vtscreen wraps the daemon's headless libghostty-vt terminals:
// the detector's zero-scrollback screen (formatted as plain text for agent
// classification) and each run's attach model (bounded scrollback, exported
// as a native Ghostty snapshot at attach). Both are fed the same PTY output
// the clients render.
//
// The package links a static libghostty-vt through cgo; `make ghostty-vt`
// builds the pinned library and `make build`/`make test` point pkg-config
// at it (see docs/TERMINAL_AGENT_DETECTION.md).
//
// A screen is deliberately passive: it never answers PTY queries or renders.
// The caller serializes all access.
package vtscreen

import "errors"

// ErrUnavailable reports use of a closed screen.
var ErrUnavailable = errors.New("terminal screen is closed")

// Screen is one headless terminal state. Callers must serialize all calls.
type Screen interface {
	// Feed applies PTY output bytes in stream order.
	Feed(data []byte)
	// Resize matches the screen to the PTY grid.
	Resize(columns, rows uint16) error
	// Text formats the current active screen as plain text with trailing
	// whitespace trimmed. It reflects cursor movement, clear-screen, and
	// alternate-screen state rather than raw byte order.
	Text() (string, error)
	// Close releases the screen's native resources.
	Close()
}

// SnapshotScreen additionally exports exact attach state from the terminal
// model. The binary GHOSTSNP payload carries scrollback, both screens, cursor,
// parser continuation, modes, margins, tabstops, and styling without
// approximating them as a synthetic VT redraw.
type SnapshotScreen interface {
	Screen
	Snapshot() ([]byte, error)
}
