package orchestration

import "time"

// stamp assigns an event its process-local ordering metadata. No event history
// is retained; reconnecting clients recover from an authoritative snapshot.
//
// Called only from withLockNotify's append closure, which already holds e.mu,
// so nextSequence needs no lock of its own.
func (e *Engine) stamp(event Event) Event {
	e.nextSequence++
	event.Sequence = e.nextSequence
	if event.EventID == "" {
		event.EventID = EventID(newID("evt"))
	}
	if event.OccurredAt.IsZero() {
		event.OccurredAt = time.Now()
	}
	return event
}
