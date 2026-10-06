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

// Snapshots and provider views hand attachments to other goroutines, so a
// clone must not share nested metadata with the projection.
func TestCloneAttachmentsDetachesNestedMetadata(t *testing.T) {
	original := []provider.Attachment{{
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
	}}

	clone := cloneAttachments(original)
	clone[0].Name = "after"
	clone[0].Annotations.Audience[0] = "user"
	clone[0].Annotations.Metadata["nested"].(map[string]any)["value"] = "after"
	clone[0].Metadata["items"].([]any)[0].(map[string]any)["value"] = "after"
	clone[0].Metadata["raw"].([]byte)[0] = 'X'
	clone[0].ResourceMetadata["value"] = "after"

	attachment := original[0]
	if attachment.Name != "before" ||
		attachment.Annotations.Audience[0] != "assistant" ||
		attachment.Annotations.Metadata["nested"].(map[string]any)["value"] != "before" ||
		attachment.Metadata["items"].([]any)[0].(map[string]any)["value"] != "before" ||
		string(attachment.Metadata["raw"].([]byte)) != "before" ||
		attachment.ResourceMetadata["value"] != "before" {
		t.Fatalf("clone mutated source: %#v", attachment)
	}
}

// Thread returns a detached deep copy of a thread for test assertions.
func (e *Engine) Thread(threadID ThreadID) (Thread, bool) {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.projection.Thread(threadID)
}

func (p *Projection) Thread(id ThreadID) (Thread, bool) {
	thread := p.threads[id]
	if thread == nil {
		return Thread{}, false
	}
	clone := *thread
	clone.ModelSelection = cloneModelSelection(thread.ModelSelection)
	clone.AdditionalDirectories = append([]string(nil), thread.AdditionalDirectories...)
	clone.ConfigSelections = append([]provider.ConfigOptionSelection(nil), thread.ConfigSelections...)
	clone.Session = cloneSessionPtr(thread.Session)
	clone.LatestTurn = cloneTurnPtr(thread.LatestTurn)
	clone.PreviousTurns = cloneTurns(thread.PreviousTurns)
	clone.Plan = clonePlanPtr(thread.Plan)
	clone.Timeline = make(Timeline, len(thread.Timeline))
	for i, entry := range thread.Timeline {
		clone.Timeline[i].Kind = entry.Kind
		if entry.Message != nil {
			message := *entry.Message
			message.Attachments = cloneAttachments(entry.Message.Attachments)
			message.Annotations = append([]provider.PromptAnnotation(nil), entry.Message.Annotations...)
			clone.Timeline[i].Message = &message
		}
		if entry.Item != nil {
			item := *entry.Item
			item.Payload = cloneRawMessage(entry.Item.Payload)
			item.ToolCall = cloneToolCall(entry.Item.ToolCall)
			clone.Timeline[i].Item = &item
		}
		if entry.Approval != nil {
			approval := *entry.Approval
			approval.Args = cloneRawMessage(entry.Approval.Args)
			approval.Options = append([]provider.ApprovalOption(nil), entry.Approval.Options...)
			clone.Timeline[i].Approval = &approval
		}
	}
	return clone, true
}

// Items and Approvals are typed timeline views for test assertions.
func (t Timeline) Items() []Item {
	items := make([]Item, 0)
	for _, entry := range t {
		if entry.Item != nil {
			items = append(items, *entry.Item)
		}
	}
	return items
}

func (t Timeline) Approvals() []Approval {
	approvals := make([]Approval, 0)
	for _, entry := range t {
		if entry.Approval != nil {
			approvals = append(approvals, *entry.Approval)
		}
	}
	return approvals
}
