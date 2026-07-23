package orchestration

import (
	"testing"
	"time"
)

func TestNormalizeEventCompletesItemTimestamps(t *testing.T) {
	occurredAt := time.Date(2026, time.July, 23, 12, 0, 0, 0, time.UTC)
	original := &Item{ID: "item-1"}

	event := normalizeEvent(Event{
		Type:       EventThreadItemUpserted,
		OccurredAt: occurredAt,
		Payload:    EventPayload{Item: original},
	})

	if event.Payload.Item == nil {
		t.Fatal("normalized event item is nil")
	}
	if !event.Payload.Item.CreatedAt.Equal(occurredAt) {
		t.Fatalf("item createdAt = %v, want %v", event.Payload.Item.CreatedAt, occurredAt)
	}
	if !event.Payload.Item.UpdatedAt.Equal(occurredAt) {
		t.Fatalf("item updatedAt = %v, want %v", event.Payload.Item.UpdatedAt, occurredAt)
	}
	if !original.CreatedAt.IsZero() || !original.UpdatedAt.IsZero() {
		t.Fatalf("normalization mutated caller-owned item: %#v", original)
	}
}

func TestProjectionDerivesStaleSessionClearingFromProviderSelection(t *testing.T) {
	for _, tc := range []struct {
		name      string
		eventType EventType
		payload   EventPayload
	}{
		{
			name:      "meta update",
			eventType: EventThreadMetaUpdated,
			payload:   EventPayload{ProviderInstanceID: "provider-b"},
		},
		{
			name:      "turn start",
			eventType: EventThreadTurnStartRequested,
			payload:   EventPayload{ProviderInstanceID: "provider-b", TurnID: "turn-1"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			threadID := ThreadID("thread-stale-session-" + tc.name)
			now := time.Now()
			projection := NewProjection()
			projection.Apply(Event{Type: EventThreadCreated, OccurredAt: now, Payload: EventPayload{ThreadID: threadID, ProviderInstanceID: "provider-a"}})
			projection.Apply(Event{Type: EventThreadSessionStatusSet, OccurredAt: now.Add(time.Second), Payload: EventPayload{ThreadID: threadID, Session: &SessionBinding{ThreadID: threadID, ProviderInstanceID: "provider-a", Status: SessionStatusReady}}})

			payload := tc.payload
			payload.ThreadID = threadID
			projection.Apply(Event{Type: tc.eventType, OccurredAt: now.Add(2 * time.Second), Payload: payload})

			thread, ok := projection.Thread(threadID)
			if !ok {
				t.Fatalf("thread missing")
			}
			if thread.ProviderInstanceID != "provider-b" || thread.ModelSelection != nil {
				t.Fatalf("thread provider selection = %#v / %#v, want provider-b", thread.ProviderInstanceID, thread.ModelSelection)
			}
			if thread.Session != nil {
				t.Fatalf("thread session after provider switch without sessionCleared = %#v, want cleared", thread.Session)
			}
		})
	}
}
