package orchestration

import (
	"context"
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

func mustDispatch(t *testing.T, engine *Engine, command Command) DispatchResult {
	t.Helper()
	result, err := engine.Dispatch(context.Background(), command)
	if err != nil {
		t.Fatalf("dispatch %s: %v", command.Type, err)
	}
	return result
}

func mustAppend(t *testing.T, engine *Engine, input EventInput) DispatchResult {
	t.Helper()
	result, err := engine.AppendEvent(context.Background(), input)
	if err != nil {
		t.Fatalf("append %s: %v", input.Type, err)
	}
	return result
}
