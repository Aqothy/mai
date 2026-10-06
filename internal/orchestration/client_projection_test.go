package orchestration

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

func TestClientProjectionCompactsToolItemWithoutMutatingCanonicalItem(t *testing.T) {
	t.Parallel()

	locations := make([]provider.ToolLocation, maxToolSummaryEntries+1)
	changes := make([]provider.FileChange, maxToolSummaryEntries+1)
	attachments := make([]provider.Attachment, maxToolSummaryEntries+1)
	for index := range locations {
		locations[index] = provider.ToolLocation{Path: "path"}
		changes[index] = provider.FileChange{Path: "file.go", Kind: provider.FileChangeUpdate, Diff: "large-diff", OldText: "large-old-text", NewText: "large-new-text"}
		attachments[index] = provider.Attachment{Kind: "image", Name: "preview", Data: "large-inline-data"}
	}
	item := Item{
		ID: "tool-1", Kind: provider.ItemKindCommandExecution, Status: provider.ItemStatusCompleted,
		ToolCall: &provider.ToolCall{
			Action:      provider.ToolActionExecute,
			Command:     strings.Repeat("c", maxToolSummaryFieldRunes+1),
			Output:      strings.Repeat("o", maxToolSummaryOutputRunes+1),
			Locations:   locations,
			Changes:     changes,
			Attachments: attachments,
		},
		Payload: json.RawMessage(`{"private":"tool-payload"}`),
	}

	projected := projectItemForClient(item)
	if projected.ToolCall != nil || projected.Payload != nil || !projected.DetailAvailable {
		t.Fatalf("projected item = %#v, want full detail replaced by a detail marker", projected)
	}
	summary := projected.ToolCallSummary
	if summary == nil ||
		len([]rune(summary.CommandPreview)) != maxToolSummaryFieldRunes ||
		len([]rune(summary.OutputPreview)) != maxToolSummaryOutputRunes ||
		len(summary.Locations) != maxToolSummaryEntries ||
		len(summary.Changes) != maxToolSummaryEntries ||
		len(summary.Attachments) != maxToolSummaryEntries ||
		summary.LocationCount != len(locations) ||
		summary.ChangeCount != len(changes) ||
		summary.AttachmentCount != len(attachments) ||
		summary.Changes[0].Path != "file.go" ||
		!summary.Truncated {
		t.Fatalf("unexpected bounded summary: %#v", summary)
	}
	wire, err := json.Marshal(projected)
	if err != nil {
		t.Fatalf("marshal projected item: %v", err)
	}
	for _, omitted := range []string{"large-diff", "large-old-text", "large-new-text", "large-inline-data", "tool-payload"} {
		if strings.Contains(string(wire), omitted) {
			t.Fatalf("projected item exposed %q", omitted)
		}
	}
	if item.ToolCall.Changes[0].OldText != "large-old-text" || item.ToolCall.Attachments[0].Data != "large-inline-data" || string(item.Payload) != `{"private":"tool-payload"}` {
		t.Fatalf("canonical item was mutated: %#v", item)
	}
}

func TestClientProjectionKeepsNonToolPayload(t *testing.T) {
	t.Parallel()

	item := Item{ID: "reasoning-1", Kind: provider.ItemKindReasoning, Status: provider.ItemStatusCompleted, Payload: json.RawMessage(`{"text":"explanation"}`)}
	projected := projectItemForClient(item)
	if string(projected.Payload) != string(item.Payload) || projected.DetailAvailable {
		t.Fatalf("non-tool projection = %#v", projected)
	}
	projected.Payload[0] = '['
	if item.Payload[0] != '{' {
		t.Fatal("projected non-tool payload aliases canonical state")
	}
}

// Snapshots carry the compact item; orchestration.getItemDetail returns the
// full canonical item, detached, keyed by the latest upsert's sequence (which
// changes even when two upserts share a timestamp).
func TestThreadSnapshotOmitsFullToolDetailAndGetItemDetailReturnsIt(t *testing.T) {
	t.Parallel()

	engine := NewEngine()
	defer engine.Close()
	threadID := ThreadID("thread-1")
	mustDispatch(t, engine, Command{Type: CommandThreadCreate, CommandID: "create-detail", ThreadID: threadID})
	occurredAt := time.Unix(2, 0)
	var sequences []uint64
	for _, newText := range []string{"draft", "after"} {
		result := mustAppend(t, engine, EventInput{Type: EventThreadItemUpserted, ThreadID: threadID, OccurredAt: occurredAt, Payload: EventPayload{Item: &Item{
			ID: "tool-1", Kind: provider.ItemKindFileChange, Status: provider.ItemStatusCompleted,
			ToolCall: &provider.ToolCall{Action: provider.ToolActionEdit, Changes: []provider.FileChange{{Path: "main.go", Kind: provider.FileChangeUpdate, OldText: "before", NewText: newText}}},
		}}})
		sequences = append(sequences, result.Sequence)
	}

	stream, err := engine.SubscribeThread(SubscribeThreadInput{ThreadID: threadID})
	if err != nil {
		t.Fatalf("SubscribeThread: %v", err)
	}
	snapshotItem := stream.Snapshot.Thread.Timeline[0].Item
	if snapshotItem.ToolCall != nil || snapshotItem.ToolCallSummary == nil || len(snapshotItem.ToolCallSummary.Changes) != 1 ||
		sequences[0] >= sequences[1] || snapshotItem.Sequence != sequences[1] || snapshotItem.CreatedAt != occurredAt {
		t.Fatalf("snapshot item = %#v (sequences %v)", snapshotItem, sequences)
	}

	getDetail := func() Item {
		t.Helper()
		detail, err := engine.GetItemDetail(GetItemDetailInput{ThreadID: threadID, ItemID: "tool-1"})
		if err != nil {
			t.Fatalf("GetItemDetail: %v", err)
		}
		return detail
	}
	detail := getDetail()
	if detail.ToolCall == nil || detail.ToolCall.Changes[0].OldText != "before" || detail.ToolCall.Changes[0].NewText != "after" ||
		detail.ToolCallSummary != nil || detail.DetailAvailable || detail.Sequence != snapshotItem.Sequence {
		t.Fatalf("item detail = %#v", detail)
	}
	detail.ToolCall.Changes[0].OldText = "mutated"
	if getDetail().ToolCall.Changes[0].OldText != "before" {
		t.Fatal("item detail aliases canonical state")
	}
}

func TestProjectEventForClientCompactsToolUpdatesWithoutMutatingCanonicalEvent(t *testing.T) {
	t.Parallel()

	// A sparse provider update may omit the item kind; it must still compact.
	for _, kind := range []provider.ItemKind{"", provider.ItemKindCommandExecution} {
		event := Event{
			Type: EventThreadItemUpserted,
			Payload: EventPayload{Item: &Item{
				ID:     "tool-1",
				Kind:   kind,
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
			t.Fatalf("kind %q: projected event = %#v", kind, projected)
		}
		if event.Payload.Item.ToolCall == nil || event.Payload.Item.ToolCall.Output != "complete output" {
			t.Fatalf("kind %q: projecting event mutated canonical event", kind)
		}
	}
}
