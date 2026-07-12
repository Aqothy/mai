package orchestration

import (
	"sort"
	"sync"
	"time"
)

type EventStore struct {
	mu     sync.Mutex
	next   uint64
	events []Event
}

func NewEventStore() *EventStore { return &EventStore{} }

func (s *EventStore) Append(event Event) Event {
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
	s.events = append(s.events, event)
	return event
}

// Replay returns events after the given sequence, optionally filtered to one
// thread and capped at Limit. Per-thread + limited replay keeps reconnect
// catch-up proportional to what a client actually watches instead of shipping
// every thread's stream in one unbounded response.
func (s *EventStore) Replay(input ReplayEventsInput) []Event {
	s.mu.Lock()
	defer s.mu.Unlock()
	// Events are append-ordered by sequence; binary search the start.
	start := sort.Search(len(s.events), func(i int) bool {
		return s.events[i].Sequence > input.FromSequenceExclusive
	})
	capacity := len(s.events) - start
	if input.Limit > 0 && capacity > input.Limit {
		capacity = input.Limit
	}
	result := make([]Event, 0, capacity)
	for _, event := range s.events[start:] {
		if input.ThreadID != "" && event.ThreadID() != input.ThreadID {
			continue
		}
		result = append(result, event)
		if input.Limit > 0 && len(result) == input.Limit {
			break
		}
	}
	return result
}
