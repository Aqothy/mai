package orchestration

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

func TestClientProjectionCompactsEveryToolKindWithoutMutatingCanonicalItem(t *testing.T) {
	t.Parallel()

	for _, kind := range []provider.ItemKind{
		provider.ItemKindCommandExecution,
		provider.ItemKindFileChange,
		provider.ItemKindMCPToolCall,
		provider.ItemKindToolCall,
	} {
		t.Run(string(kind), func(t *testing.T) {
			t.Parallel()

			locations := make([]provider.ToolLocation, maxToolSummaryEntries+1)
			changes := make([]provider.FileChange, maxToolSummaryEntries+1)
			attachments := make([]provider.Attachment, maxToolSummaryEntries+1)
			for index := range locations {
				locations[index] = provider.ToolLocation{Path: "path"}
				changes[index] = provider.FileChange{
					Path:    "file.go",
					Kind:    provider.FileChangeUpdate,
					Diff:    "large-diff",
					OldText: "large-old-text",
					NewText: "large-new-text",
				}
				attachments[index] = provider.Attachment{
					Kind: "image",
					Name: "preview",
					Data: "large-inline-data",
				}
			}
			item := Item{
				ID:     "tool-1",
				Kind:   kind,
				Status: provider.ItemStatusCompleted,
				ToolCall: &provider.ToolCall{
					Action:      provider.ToolActionExecute,
					Command:     strings.Repeat("c", maxToolSummaryFieldRunes+1),
					Output:      strings.Repeat("o", maxToolSummaryOutputRunes+1),
					Locations:   locations,
					Changes:     changes,
					Attachments: attachments,
				},
				Payload:   json.RawMessage(`{"private":"tool-payload"}`),
				CreatedAt: time.Unix(1, 0),
				UpdatedAt: time.Unix(2, 0),
			}

			projected := projectItemForClient(item)

			if projected.ToolCall != nil || projected.Payload != nil {
				t.Fatalf("projected item retained full detail: %#v", projected)
			}
			if !projected.DetailAvailable || projected.ToolCallSummary == nil {
				t.Fatalf("projected item has no detail marker/summary: %#v", projected)
			}
			summary := projected.ToolCallSummary
			if len([]rune(summary.CommandPreview)) != maxToolSummaryFieldRunes ||
				len([]rune(summary.OutputPreview)) != maxToolSummaryOutputRunes ||
				len(summary.Locations) != maxToolSummaryEntries ||
				len(summary.Changes) != maxToolSummaryEntries ||
				len(summary.Attachments) != maxToolSummaryEntries ||
				summary.LocationCount != len(locations) ||
				summary.ChangeCount != len(changes) ||
				summary.AttachmentCount != len(attachments) ||
				!summary.Truncated {
				t.Fatalf("unexpected bounded summary: %#v", summary)
			}
			for _, change := range summary.Changes {
				if change.Path == "" {
					t.Fatal("projected file change lost its path")
				}
			}
			wire, err := json.Marshal(projected)
			if err != nil {
				t.Fatalf("marshal projected item: %v", err)
			}
			for _, omitted := range []string{
				"large-diff",
				"large-old-text",
				"large-new-text",
				"large-inline-data",
				"tool-payload",
			} {
				if strings.Contains(string(wire), omitted) {
					t.Fatalf("projected item exposed %q", omitted)
				}
			}
			if item.ToolCall == nil ||
				item.ToolCall.Changes[0].OldText != "large-old-text" ||
				item.ToolCall.Attachments[0].Data != "large-inline-data" ||
				string(item.Payload) != `{"private":"tool-payload"}` {
				t.Fatalf("canonical item was mutated: %#v", item)
			}
		})
	}
}

func TestClientProjectionKeepsNonToolPayload(t *testing.T) {
	t.Parallel()

	item := Item{
		ID:        "reasoning-1",
		Kind:      provider.ItemKindReasoning,
		Status:    provider.ItemStatusCompleted,
		Payload:   json.RawMessage(`{"text":"explanation"}`),
		CreatedAt: time.Unix(1, 0),
		UpdatedAt: time.Unix(2, 0),
	}
	projected := projectItemForClient(item)

	if string(projected.Payload) != string(item.Payload) || projected.DetailAvailable {
		t.Fatalf("non-tool projection = %#v", projected)
	}
	projected.Payload[0] = '['
	if item.Payload[0] != '{' {
		t.Fatal("projected non-tool payload aliases canonical state")
	}
}

func TestThreadSnapshotOmitsFullToolDetailAndGetItemDetailReturnsIt(t *testing.T) {
	t.Parallel()

	engine := NewEngine()
	defer engine.Close()

	threadID := ThreadID("thread-1")
	fullItem := Item{
		ID:     "tool-1",
		Kind:   provider.ItemKindFileChange,
		Status: provider.ItemStatusCompleted,
		ToolCall: &provider.ToolCall{
			Action: provider.ToolActionEdit,
			Changes: []provider.FileChange{{
				Path:    "main.go",
				Kind:    provider.FileChangeUpdate,
				OldText: "before",
				NewText: "after",
			}},
		},
		CreatedAt: time.Unix(1, 0),
		UpdatedAt: time.Unix(2, 0),
	}

	engine.mu.Lock()
	engine.projection.threads[threadID] = &Thread{
		ID:        threadID,
		Title:     "Thread",
		Timeline:  Timeline{{Kind: TimelineEntryItem, Item: &fullItem}},
		CreatedAt: time.Unix(1, 0),
		UpdatedAt: time.Unix(1, 0),
	}
	engine.mu.Unlock()

	stream, err := engine.SubscribeThread(SubscribeThreadInput{ThreadID: threadID})
	if err != nil {
		t.Fatalf("SubscribeThread: %v", err)
	}
	snapshotItem := stream.Snapshot.Thread.Timeline[0].Item
	if snapshotItem.ToolCall != nil ||
		snapshotItem.ToolCallSummary == nil ||
		len(snapshotItem.ToolCallSummary.Changes) != 1 {
		t.Fatalf("snapshot item = %#v", snapshotItem)
	}

	detail, err := engine.GetItemDetail(GetItemDetailInput{
		ThreadID: threadID,
		ItemID:   fullItem.ID,
	})
	if err != nil {
		t.Fatalf("GetItemDetail: %v", err)
	}
	if detail.ToolCall == nil ||
		detail.ToolCall.Changes[0].OldText != "before" ||
		detail.ToolCall.Changes[0].NewText != "after" ||
		detail.ToolCallSummary != nil ||
		detail.DetailAvailable {
		t.Fatalf("item detail = %#v", detail)
	}

	detail.ToolCall.Changes[0].OldText = "mutated"
	again, err := engine.GetItemDetail(GetItemDetailInput{
		ThreadID: threadID,
		ItemID:   fullItem.ID,
	})
	if err != nil {
		t.Fatalf("second GetItemDetail: %v", err)
	}
	if again.ToolCall.Changes[0].OldText != "before" {
		t.Fatal("item detail aliases canonical state")
	}
}

func TestItemSequenceChangesWhenUpdateTimestampsMatch(t *testing.T) {
	t.Parallel()

	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-item-sequence")
	if _, err := engine.Dispatch(context.Background(), Command{
		Type: CommandThreadCreate, CommandID: "create-item-sequence", ThreadID: threadID,
	}); err != nil {
		t.Fatalf("create thread: %v", err)
	}

	occurredAt := time.Unix(2, 0)
	var sequences []uint64
	for index, output := range []string{"running", "completed"} {
		result, err := engine.AppendEvent(context.Background(), EventInput{
			Type: EventThreadItemUpserted, ThreadID: threadID, OccurredAt: occurredAt,
			Payload: EventPayload{Item: &Item{
				ID: "tool-1", Kind: provider.ItemKindCommandExecution,
				Status:   provider.ItemStatusCompleted,
				ToolCall: &provider.ToolCall{Action: provider.ToolActionExecute, Output: output},
			}},
		})
		if err != nil {
			t.Fatalf("append item %d: %v", index, err)
		}
		sequences = append(sequences, result.Sequence)
	}
	if sequences[0] >= sequences[1] {
		t.Fatalf("item sequences = %v, want increasing", sequences)
	}

	stream, err := engine.SubscribeThread(SubscribeThreadInput{ThreadID: threadID})
	if err != nil {
		t.Fatalf("subscribe thread: %v", err)
	}
	item := stream.Snapshot.Thread.Timeline[0].Item
	detail, err := engine.GetItemDetail(GetItemDetailInput{ThreadID: threadID, ItemID: "tool-1"})
	if err != nil {
		t.Fatalf("get item detail: %v", err)
	}
	if item.Sequence != sequences[1] || detail.Sequence != item.Sequence || item.UpdatedAt != occurredAt ||
		detail.ToolCall == nil || detail.ToolCall.Output != "completed" {
		t.Fatalf("snapshot item = %#v, detail = %#v", item, detail)
	}
}

func TestProjectEventForClientCompactsSparseToolUpdateWithoutKind(t *testing.T) {
	t.Parallel()

	event := Event{
		Type: EventThreadItemUpserted,
		Payload: EventPayload{Item: &Item{
			ID:     "tool-1",
			Status: provider.ItemStatusCompleted,
			ToolCall: &provider.ToolCall{
				Action: provider.ToolActionExecute,
				Output: "complete output",
			},
		}},
	}

	projected := ProjectEventForClient(event)
	if projected.Payload.Item.ToolCall != nil ||
		projected.Payload.Item.ToolCallSummary == nil ||
		projected.Payload.Item.ToolCallSummary.OutputPreview != "complete output" {
		t.Fatalf("projected sparse event = %#v", projected)
	}
}

func TestProjectEventForClientDoesNotExposeFullToolDetail(t *testing.T) {
	t.Parallel()

	event := Event{
		Type: EventThreadItemUpserted,
		Payload: EventPayload{Item: &Item{
			ID:     "tool-1",
			Kind:   provider.ItemKindCommandExecution,
			Status: provider.ItemStatusCompleted,
			ToolCall: &provider.ToolCall{
				Action: provider.ToolActionExecute,
				Output: "complete output",
			},
		}},
	}

	projected := ProjectEventForClient(event)
	if projected.Payload.Item.ToolCall != nil ||
		projected.Payload.Item.ToolCallSummary == nil ||
		projected.Payload.Item.ToolCallSummary.OutputPreview != "complete output" {
		t.Fatalf("projected event = %#v", projected)
	}
	if event.Payload.Item.ToolCall == nil || event.Payload.Item.ToolCall.Output != "complete output" {
		t.Fatal("projecting event mutated canonical event")
	}
}
