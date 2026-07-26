package orchestration

import (
	"encoding/json"
	"testing"

	"github.com/Aqothy/maiD/internal/provider"
)

func TestTimelineAppendsAndFindsTypedUnion(t *testing.T) {
	var timeline Timeline
	timeline.AppendMessage(Message{ID: "message-1", Text: "hello"})
	timeline.AppendItem(Item{ID: "tool-1", Kind: provider.ItemKindToolCall})
	timeline.AppendApproval(Approval{RequestID: "approval-1"})

	if len(timeline) != 3 || timeline[0].Kind != TimelineEntryMessage || timeline[1].Kind != TimelineEntryItem || timeline[2].Kind != TimelineEntryApproval {
		t.Fatalf("timeline order = %#v", timeline)
	}
	if timeline.Message("message-1") == nil || timeline.Item("tool-1") == nil || timeline.Approval("approval-1") == nil {
		t.Fatalf("typed lookup failed: %#v", timeline)
	}
	if timeline.Message("missing") != nil || timeline.Item("missing") != nil || timeline.Approval("missing") != nil {
		t.Fatalf("lookup of an absent id returned an entry: %#v", timeline)
	}
}

// Lookups scan backwards for the streaming hot path, so they must still return
// the one matching entry regardless of where it sits.
func TestTimelineLookupFindsEntriesAtEveryPosition(t *testing.T) {
	var timeline Timeline
	for _, id := range []string{"a", "b", "c"} {
		timeline.AppendMessage(Message{ID: MessageID("message-" + id), Text: id})
		timeline.AppendItem(Item{ID: "item-" + id, Kind: provider.ItemKindToolCall, Title: id})
		timeline.AppendApproval(Approval{RequestID: "approval-" + id, OptionID: id})
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
}

func TestTimelineCloneOwnsMutablePayloads(t *testing.T) {
	var timeline Timeline
	timeline.AppendMessage(Message{ID: "message-1", Attachments: []provider.Attachment{{Name: "before", Metadata: map[string]json.RawMessage{"value": json.RawMessage(`"before"`)}}}})
	timeline.AppendItem(Item{ID: "item-1", Payload: []byte(`{"value":"before"}`), ToolCall: &provider.ToolCall{
		Action: provider.ToolActionOther,
		Attachments: []provider.Attachment{{
			Raw:      json.RawMessage(`{"value":"before"}`),
			Metadata: map[string]json.RawMessage{"value": json.RawMessage(`"before"`)},
		}},
	}})
	timeline.AppendApproval(Approval{RequestID: "approval-1", Args: []byte(`{"value":"before"}`), Options: []provider.ApprovalOption{{ID: "before"}}})

	clone := timeline.Clone()
	clone[0].Message.Attachments[0].Name = "after"
	clone[0].Message.Attachments[0].Metadata["value"][1] = 'a'
	clone[1].Item.Payload[0] = '['
	clone[1].Item.ToolCall.Attachments[0].Raw[0] = '['
	clone[1].Item.ToolCall.Attachments[0].Metadata["value"][1] = 'a'
	clone[2].Approval.Args[0] = '['
	clone[2].Approval.Options[0].ID = "after"

	if timeline[0].Message.Attachments[0].Name != "before" ||
		string(timeline[0].Message.Attachments[0].Metadata["value"]) != `"before"` ||
		string(timeline[1].Item.Payload) != `{"value":"before"}` ||
		string(timeline[1].Item.ToolCall.Attachments[0].Raw) != `{"value":"before"}` ||
		string(timeline[1].Item.ToolCall.Attachments[0].Metadata["value"]) != `"before"` ||
		string(timeline[2].Approval.Args) != `{"value":"before"}` ||
		timeline[2].Approval.Options[0].ID != "before" {
		t.Fatalf("clone mutated source: %#v", timeline)
	}
}
