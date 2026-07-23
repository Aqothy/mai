package orchestration

import (
	"sync"
	"time"
)

// EventSequencer stamps live events with process-local ordering metadata. It
// deliberately retains no event history; reconnecting clients recover from an
// authoritative snapshot instead of replaying missed transport events.
type EventSequencer struct {
	mu   sync.Mutex
	next uint64
}

func NewEventSequencer() *EventSequencer {
	return &EventSequencer{}
}

func (s *EventSequencer) Stamp(event Event) Event {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.next++
	event.Sequence = s.next
	if event.EventID == "" {
		event.EventID = EventID(newID("evt"))
	}
	if event.OccurredAt.IsZero() {
		event.OccurredAt = time.Now()
	}
	return event
}
