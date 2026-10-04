package orchestration

import (
	"testing"

	"github.com/Aqothy/maiD/internal/provider"
)

// Lookups scan backwards for the streaming hot path, so they must still return
// the one matching entry regardless of where it sits.
func TestTimelineAppendsAndFindsEntriesAtEveryPosition(t *testing.T) {
	var timeline Timeline
	for _, id := range []string{"a", "b", "c"} {
		timeline.AppendMessage(Message{ID: MessageID("message-" + id), Text: id})
		timeline.AppendItem(Item{ID: "item-" + id, Kind: provider.ItemKindToolCall, Title: id})
		timeline.AppendApproval(Approval{RequestID: "approval-" + id, OptionID: id})
	}
	if len(timeline) != 9 || timeline[0].Kind != TimelineEntryMessage || timeline[1].Kind != TimelineEntryItem || timeline[2].Kind != TimelineEntryApproval {
		t.Fatalf("timeline order = %#v", timeline)
	}

	for _, id := range []string{"a", "b", "c"} {
		message := timeline.Message(MessageID("message-" + id))
		if message == nil || message.Text != id {
			t.Fatalf("Message(%q) = %#v, want the entry appended for %q", "message-"+id, message, id)
		}
		item := timeline.Item("item-" + id)
		if item == nil || item.Title != id {
			t.Fatalf("Item(%q) = %#v, want the entry appended for %q", "item-"+id, item, id)
		}
		approval := timeline.Approval("approval-" + id)
		if approval == nil || approval.OptionID != id {
			t.Fatalf("Approval(%q) = %#v, want the entry appended for %q", "approval-"+id, approval, id)
		}
	}
	if timeline.Message("missing") != nil || timeline.Item("missing") != nil || timeline.Approval("missing") != nil {
		t.Fatalf("lookup of an absent id returned an entry: %#v", timeline)
	}
}

func TestTimelineCloneOwnsMutablePayloads(t *testing.T) {
	var timeline Timeline
	timeline.AppendMessage(Message{ID: "message-1", Attachments: []provider.Attachment{{
		Name: "before",
		Annotations: &provider.ContentAnnotations{
			Audience: []string{"assistant"},
			Metadata: map[string]any{"nested": map[string]any{"value": "before"}},
		},
		Metadata: map[string]any{
			"items": []any{map[string]any{"value": "before"}},
			"raw":   []byte("before"),
		},
		ResourceMetadata: map[string]any{"value": "before"},
	}}})
	timeline.AppendItem(Item{ID: "item-1", Payload: []byte(`{"value":"before"}`), ToolCall: &provider.ToolCall{
		Action:      provider.ToolActionOther,
		Attachments: []provider.Attachment{{Name: "before"}},
	}})
	timeline.AppendApproval(Approval{RequestID: "approval-1", Args: []byte(`{"value":"before"}`), Options: []provider.ApprovalOption{{ID: "before"}}})

	clone := timeline.Clone()
	attachment := clone[0].Message.Attachments[0]
	attachment.Name = "after"
	attachment.Annotations.Audience[0] = "user"
	attachment.Annotations.Metadata["nested"].(map[string]any)["value"] = "after"
	attachment.Metadata["items"].([]any)[0].(map[string]any)["value"] = "after"
	attachment.Metadata["raw"].([]byte)[0] = 'X'
	attachment.ResourceMetadata["value"] = "after"
	clone[0].Message.Attachments[0] = attachment
	clone[1].Item.Payload[0] = '['
	clone[1].Item.ToolCall.Attachments[0].Name = "after"
	clone[2].Approval.Args[0] = '['
	clone[2].Approval.Options[0].ID = "after"

	original := timeline[0].Message.Attachments[0]
	if original.Name != "before" ||
		original.Annotations.Audience[0] != "assistant" ||
		original.Annotations.Metadata["nested"].(map[string]any)["value"] != "before" ||
		original.Metadata["items"].([]any)[0].(map[string]any)["value"] != "before" ||
		string(original.Metadata["raw"].([]byte)) != "before" ||
		original.ResourceMetadata["value"] != "before" ||
		string(timeline[1].Item.Payload) != `{"value":"before"}` ||
		timeline[1].Item.ToolCall.Attachments[0].Name != "before" ||
		string(timeline[2].Approval.Args) != `{"value":"before"}` ||
		timeline[2].Approval.Options[0].ID != "before" {
		t.Fatalf("clone mutated source: %#v", timeline)
	}
}
