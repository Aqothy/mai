// Package store opens the daemon's database and persists terminal threads.
// The orchestration ledger and session cache share the database and own
// their tables.
package store

import "time"

// TerminalMeta contains the only durable terminal-thread values. Process
// state, dimensions, output, and run identity are deliberately absent: a
// daemon restart reconstructs these rows as stopped terminals.
type TerminalMeta struct {
	TerminalID string
	Title      string
	Cwd        string
	CreatedAt  time.Time
	UpdatedAt  time.Time
}

// TerminalStore persists terminal-thread metadata. Terminal output and input
// must never be written through this interface.
type TerminalStore interface {
	UpsertTerminal(meta TerminalMeta) error
	DeleteTerminal(terminalID string) error
	ListTerminals() ([]TerminalMeta, error)
}
