package orchestration

import (
	"encoding/json"
	"fmt"

	"github.com/Aqothy/maiD/internal/provider"
)

// Timeline is the canonical ordered conversation projection. Entries never
// move: new identities append and lifecycle updates mutate the matching entry.
type Timeline []TimelineEntry

func (t Timeline) Message(id MessageID) *Message {
	for i := range t {
		if message := t[i].Message; message != nil && message.ID == id {
			return message
		}
	}
	return nil
}

func (t Timeline) Item(id string) *Item {
	for i := range t {
		if item := t[i].Item; item != nil && item.ID == id {
			return item
		}
	}
	return nil
}

func (t Timeline) Approval(requestID string) *Approval {
	for i := range t {
		if approval := t[i].Approval; approval != nil && approval.RequestID == requestID {
			return approval
		}
	}
	return nil
}

func (t *Timeline) AppendMessage(message Message) {
	*t = append(*t, TimelineEntry{Kind: TimelineEntryMessage, Message: &message})
}

func (t *Timeline) AppendItem(item Item) {
	*t = append(*t, TimelineEntry{Kind: TimelineEntryItem, Item: &item})
}

func (t *Timeline) AppendApproval(approval Approval) {
	*t = append(*t, TimelineEntry{Kind: TimelineEntryApproval, Approval: &approval})
}

// Typed views are convenience reads for deciders, sidebar projections, and
// tests. Conversation clients should iterate Timeline directly.
func (t Timeline) Messages() []Message {
	messages := make([]Message, 0)
	for _, entry := range t {
		if entry.Message != nil {
			messages = append(messages, *entry.Message)
		}
	}
	return messages
}

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

func (t Timeline) Clone() Timeline {
	clone := make(Timeline, len(t))
	for i, entry := range t {
		clone[i].Kind = entry.Kind
		if entry.Message != nil {
			message := *entry.Message
			message.Attachments = append([]provider.Attachment(nil), entry.Message.Attachments...)
			clone[i].Message = &message
		}
		if entry.Item != nil {
			item := *entry.Item
			item.Payload = cloneRawMessage(entry.Item.Payload)
			clone[i].Item = &item
		}
		if entry.Approval != nil {
			approval := *entry.Approval
			approval.Args = cloneRawMessage(entry.Approval.Args)
			approval.Options = append([]provider.ApprovalOption(nil), entry.Approval.Options...)
			clone[i].Approval = &approval
		}
	}
	return clone
}

// Validate protects the tagged-union invariant at projection/test seams.
func (t Timeline) Validate() error {
	for i, entry := range t {
		payloads := 0
		if entry.Message != nil {
			payloads++
		}
		if entry.Item != nil {
			payloads++
		}
		if entry.Approval != nil {
			payloads++
		}
		kindMatches := entry.Kind == TimelineEntryMessage && entry.Message != nil ||
			entry.Kind == TimelineEntryItem && entry.Item != nil ||
			entry.Kind == TimelineEntryApproval && entry.Approval != nil
		if payloads != 1 || !kindMatches {
			encoded, _ := json.Marshal(entry)
			return fmt.Errorf("timeline entry %d is invalid: %s", i, encoded)
		}
	}
	return nil
}
