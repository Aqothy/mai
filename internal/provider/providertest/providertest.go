// Package providertest has the host side of the provider contract for
// adapter tests: an event recorder and an in-memory mirror.
package providertest

import (
	"context"
	"encoding/json"
	"slices"
	"sync"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// Recorder collects an instance's events, emitted from its goroutines.
type Recorder struct {
	// Timeout bounds WaitFor; live tests against real agents raise it.
	Timeout time.Duration
	mu      sync.Mutex
	events  []provider.Event
	added   chan struct{}
}

func NewRecorder() *Recorder {
	return &Recorder{Timeout: 5 * time.Second, added: make(chan struct{}, 1)}
}

// Emit is the Host.Emit.
func (r *Recorder) Emit(event provider.Event) {
	r.mu.Lock()
	r.events = append(r.events, event)
	r.mu.Unlock()
	select {
	case r.added <- struct{}{}:
	default:
	}
}

func (r *Recorder) Snapshot() []provider.Event {
	r.mu.Lock()
	defer r.mu.Unlock()
	return slices.Clone(r.events)
}

// WaitFor waits until an event matches, and returns it.
func (r *Recorder) WaitFor(t *testing.T, desc string, match func(provider.Event) bool) provider.Event {
	t.Helper()
	deadline := time.After(r.Timeout)
	for {
		for _, event := range r.Snapshot() {
			if match(event) {
				return event
			}
		}
		select {
		case <-r.added:
		case <-deadline:
			t.Fatalf("timed out waiting for %s; events: %#v", desc, r.Snapshot())
		}
	}
}

// LiveTurns folds the session's live events the way History folds replayed
// ones, less the Local entries History never has.
func (r *Recorder) LiveTurns(session string) []provider.HistoryTurn {
	var builder provider.HistoryBuilder
	for _, event := range r.Snapshot() {
		if upserted, ok := event.Body.(provider.EntryUpserted); ok && upserted.Entry.Local {
			continue
		}
		if event.Session == session {
			builder.Add(event)
		}
	}
	return builder.Turns()
}

// Settled matches the settle of turn.
func Settled(turn string) func(provider.Event) bool {
	return func(event provider.Event) bool {
		settled, ok := event.Body.(provider.TurnSettled)
		return ok && settled.Turn == turn
	}
}

// Mirror is the host's mirror, in memory.
type Mirror struct {
	mu       sync.Mutex
	sessions map[string][]json.RawMessage
}

func NewMirror() *Mirror { return &Mirror{sessions: make(map[string][]json.RawMessage)} }

func (m *Mirror) Append(session string, frames []json.RawMessage) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sessions[session] = append(m.sessions[session], frames...)
}

func (m *Mirror) Load(_ context.Context, session string) ([]json.RawMessage, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return slices.Clone(m.sessions[session]), nil
}

func (m *Mirror) Fork(_ context.Context, session, into string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sessions[into] = slices.Clone(m.sessions[session])
	return nil
}

func (m *Mirror) Delete(_ context.Context, session string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.sessions, session)
	return nil
}
