package daemon

import (
	"sync"
	"testing"

	"github.com/Aqothy/maiD/internal/orchestration"
)

type serverEventRecorder struct {
	mu     sync.Mutex
	events []orchestration.Event
}

func observeServerEvents(t *testing.T, server *Server) *serverEventRecorder {
	t.Helper()
	recorder := &serverEventRecorder{}
	cancel := server.orchestration.OnEvent(func(event orchestration.Event) {
		recorder.mu.Lock()
		recorder.events = append(recorder.events, event)
		recorder.mu.Unlock()
	})
	t.Cleanup(cancel)
	return recorder
}

func (r *serverEventRecorder) matching(threadID orchestration.ThreadID, minimumSequence uint64) []orchestration.Event {
	r.mu.Lock()
	defer r.mu.Unlock()
	events := make([]orchestration.Event, 0, len(r.events))
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
