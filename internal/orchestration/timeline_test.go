package orchestration

import (
	"testing"

	"github.com/Aqothy/maiD/internal/provider"
)

func TestTimelineAppendsInOrderAndFindsByTypedIdentity(t *testing.T) {
	var timeline Timeline
	timeline.AppendMessage(Message{ID: "message-1", Text: "hello"})
	timeline.AppendItem(Item{ID: "tool-1", Kind: provider.ItemKindToolCall})
	timeline.AppendApproval(Approval{RequestID: "approval-1"})

	if err := timeline.Validate(); err != nil {
		t.Fatalf("Validate: %v", err)
	}
	if len(timeline) != 3 || timeline[0].Kind != TimelineEntryMessage || timeline[1].Kind != TimelineEntryItem || timeline[2].Kind != TimelineEntryApproval {
		t.Fatalf("timeline order = %#v", timeline)
	}
	if timeline.Message("message-1") == nil || timeline.Item("tool-1") == nil || timeline.Approval("approval-1") == nil {
		t.Fatalf("typed lookup failed: %#v", timeline)
	}
}

func TestTimelineCloneOwnsMutablePayloads(t *testing.T) {
	var timeline Timeline
	timeline.AppendMessage(Message{ID: "message-1", Attachments: []provider.Attachment{{Name: "before"}}})
	timeline.AppendItem(Item{ID: "item-1", Payload: []byte(`{"value":"before"}`)})
	timeline.AppendApproval(Approval{RequestID: "approval-1", Args: []byte(`{"value":"before"}`), Options: []provider.ApprovalOption{{ID: "before"}}})

	clone := timeline.Clone()
	clone[0].Message.Attachments[0].Name = "after"
	clone[1].Item.Payload[0] = '['
	clone[2].Approval.Args[0] = '['
	clone[2].Approval.Options[0].ID = "after"

	if timeline[0].Message.Attachments[0].Name != "before" || string(timeline[1].Item.Payload) != `{"value":"before"}` || string(timeline[2].Approval.Args) != `{"value":"before"}` || timeline[2].Approval.Options[0].ID != "before" {
		t.Fatalf("clone mutated source: %#v", timeline)
	}
}

func TestTimelineValidateRejectsMismatchedUnion(t *testing.T) {
	timeline := Timeline{{Kind: TimelineEntryMessage, Item: &Item{ID: "wrong"}}}
	if err := timeline.Validate(); err == nil {
		t.Fatal("Validate accepted mismatched timeline union")
	}
}
