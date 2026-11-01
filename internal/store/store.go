// Package store opens the daemon's database and persists provider instance
// specs and terminal threads. The orchestration ledger and session cache
// share the database and own their tables.
package store

import (
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// InstanceStore persists configured provider instances.
type InstanceStore interface {
	SaveInstance(spec provider.InstanceSpec) error
	LoadInstances() ([]provider.InstanceSpec, error)
}

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
