// Package vtscreen wraps the daemon's passive, zero-scrollback
// libghostty-vt screen used for coding-agent classification.
//
// The package links a static libghostty-vt through cgo; `make ghostty-vt`
// builds the pinned library and `make build`/`make test` point pkg-config at
// it. A screen never answers PTY queries or renders, and callers serialize
// all access.
package vtscreen

import "errors"

// ErrUnavailable reports use of a closed screen.
var ErrUnavailable = errors.New("terminal screen is closed")

// Screen is one headless terminal state. Callers must serialize all calls.
type Screen interface {
	// Feed applies PTY output bytes in stream order.
	Feed(data []byte)
	// Resize matches the screen to the PTY grid.
	Resize(columns, rows uint16)
	// Text formats the current active screen as plain text with trailing
	// whitespace trimmed. It reflects cursor movement, clear-screen, and
	// alternate-screen state rather than raw byte order.
	Text() (string, error)
	// Close releases the screen's native resources.
	Close()
}
