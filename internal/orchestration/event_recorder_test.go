package orchestration

import (
	"sync"
	"testing"
)

type testEventRecorder struct {
	mu     sync.Mutex
	events []Event
}

func observeEvents(t *testing.T, engine *Engine) *testEventRecorder {
	t.Helper()
	recorder := &testEventRecorder{}
	cancel := engine.OnEvent(func(event Event) {
		recorder.mu.Lock()
		recorder.events = append(recorder.events, event)
		recorder.mu.Unlock()
	})
	t.Cleanup(cancel)
	return recorder
}

func (r *testEventRecorder) matching(threadID ThreadID, minimumSequence uint64) []Event {
	r.mu.Lock()
	defer r.mu.Unlock()
	events := make([]Event, 0, len(r.events))
	for _, event := range r.events {
		if event.Sequence <= minimumSequence {
			continue
		}
		if threadID != "" && event.ThreadID() != threadID {
			continue
		}
		events = append(events, event)
	}
	return events
}
