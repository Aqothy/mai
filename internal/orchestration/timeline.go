package orchestration

// Timeline is the canonical ordered conversation projection. Entries never
// move: new identities append and lifecycle updates mutate the matching entry.
type Timeline []TimelineEntry

// Lookups scan from the END: a streamed update addresses the entry it just
// appended or one near it, and these run under the engine's write lock.
func (t Timeline) Message(id MessageID) *Message {
	for i := len(t) - 1; i >= 0; i-- {
		if message := t[i].Message; message != nil && message.ID == id {
			return message
		}
	}
	return nil
}

func (t Timeline) Item(id string) *Item {
	for i := len(t) - 1; i >= 0; i-- {
		if item := t[i].Item; item != nil && item.ID == id {
			return item
		}
	}
	return nil
}

func (t Timeline) Approval(requestID string) *Approval {
	for i := len(t) - 1; i >= 0; i-- {
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

// Messages is a typed view for deciders. Conversation clients should iterate
// Timeline directly.
func (t Timeline) Messages() []Message {
	messages := make([]Message, 0)
	for _, entry := range t {
		if entry.Message != nil {
			messages = append(messages, *entry.Message)
		}
	}
	return messages
}
