package orchestration

import (
	"encoding/json"
	"fmt"
	"slices"
	"strings"

	"github.com/Aqothy/maiD/internal/provider"
)

// ForkSource is what a fork of a thread starts from: the thread's settings
// and the turns the fork keeps.
type ForkSource struct {
	Title                 string
	ProviderInstanceID    provider.InstanceID
	Cwd                   string
	AdditionalDirectories []string
	// ConfigSelections start a new session where the thread's runs now,
	// its model among them, so a client can show and send them as its own.
	ConfigSelections []provider.ConfigOptionSelection
	// ThroughTurnID is the provider's id for the last turn the fork keeps;
	// empty when it keeps none.
	ThroughTurnID string
	// Conversation is the kept turns as text, for a fork the provider can't
	// make natively (see provider.PromptWithForkContext).
	Conversation string
}

// ForkSource resolves a fork of the thread's turns through the turn through,
// or up to the turn before, or, with neither, all of them. It keeps only the
// turns the provider ran to the end, as its native session does: the
// provider has no record of the others and can't fork a running one.
func (e *Engine) ForkSource(threadID ThreadID, through, before TurnID) (ForkSource, error) {
	if through != "" && before != "" {
		return ForkSource{}, fmt.Errorf("a fork ends through one turn or before one, not both")
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	thread := e.projection.liveThread(threadID)
	if thread == nil {
		return ForkSource{}, fmt.Errorf("thread %q not found", threadID)
	}
	if thread.ReplayHistoryPending {
		return ForkSource{}, fmt.Errorf("thread %q has not loaded its history yet", threadID)
	}
	turns := slices.Clone(thread.PreviousTurns)
	if thread.LatestTurn != nil {
		turns = append(turns, *thread.LatestTurn)
	}
	index := func(id TurnID) (int, error) {
		at := slices.IndexFunc(turns, func(turn Turn) bool { return turn.ID == id })
		if at < 0 {
			return 0, fmt.Errorf("thread %q has no turn %q", threadID, id)
		}
		return at, nil
	}
	end := len(turns)
	switch {
	case through != "":
		at, err := index(through)
		if err != nil {
			return ForkSource{}, err
		}
		end = at + 1
	case before != "":
		at, err := index(before)
		if err != nil {
			return ForkSource{}, err
		}
		end = at
	}
	source := ForkSource{
		Title:                 thread.Title,
		ProviderInstanceID:    thread.ProviderInstanceID,
		Cwd:                   thread.Cwd,
		AdditionalDirectories: slices.Clone(thread.AdditionalDirectories),
		ConfigSelections:      forkConfigSelections(*thread),
	}
	kept := make(map[TurnID]bool, end)
	for _, turn := range turns[:end] {
		if turn.ProviderTurnID != "" {
			kept[turn.ID] = true
			source.ThroughTurnID = turn.ProviderTurnID
		}
	}
	source.Conversation = conversationText(thread.Timeline, kept)
	return source, nil
}

// forkConfigSelections are the selections a session resumes the thread with
// plus its model, which sessions otherwise take from ModelSelection.
func forkConfigSelections(thread Thread) []provider.ConfigOptionSelection {
	session := cloneSessionPtr(thread.Session)
	selections := configSelectionsFromProviderView(ThreadProviderView{
		ConfigSelections: slices.Clone(thread.ConfigSelections),
		Session:          session,
	})
	if session == nil || thread.ModelSelection == nil || thread.ModelSelection.Model == "" {
		return selections
	}
	at := slices.IndexFunc(session.ConfigOptions, func(option provider.ConfigOption) bool {
		return option.ID != "" && option.Category == provider.ConfigOptionCategoryModel
	})
	if at < 0 {
		return selections
	}
	model := provider.ConfigOptionSelection{
		OptionID: session.ConfigOptions[at].ID,
		Value:    thread.ModelSelection.Model,
		Category: provider.ConfigOptionCategoryModel,
	}
	if at := slices.IndexFunc(selections, func(selection provider.ConfigOptionSelection) bool {
		return selection.OptionID == model.OptionID
	}); at >= 0 {
		selections[at] = model
		return selections
	}
	return append(selections, model)
}

// conversationText writes the kept turns as a transcript a model can read:
// the messages, and each tool call with its bounded previews. Reasoning,
// warnings and approvals stay out; the conversation an earlier fork handed
// the thread comes first.
func conversationText(timeline Timeline, kept map[TurnID]bool) string {
	var text strings.Builder
	earlier := forkContextText(timeline)
	add := func(block string) {
		if earlier != "" {
			text.WriteString(earlier)
			earlier = ""
		}
		if text.Len() > 0 {
			text.WriteString("\n\n")
		}
		text.WriteString(block)
	}
	section := func(heading, body string) {
		if body = strings.TrimSpace(body); body != "" {
			add(heading + ":\n" + body)
		}
	}
	for _, entry := range timeline {
		switch {
		case entry.Message != nil && kept[entry.Message.TurnID]:
			message := entry.Message
			switch {
			case message.Role == MessageRoleAssistant:
				section("Assistant", message.Text)
			case message.Delivery == "":
				section("User", promptTextWithAnnotations(message.Text, message.Annotations))
			}
		case entry.Item != nil && kept[entry.Item.TurnID] && isToolItem(entry.Item.Kind):
			section("Tool call", toolCallText(*entry.Item))
		}
	}
	return text.String()
}

func toolCallText(item Item) string {
	summary := summarizeToolCall(item.ToolCall)
	if summary == nil {
		return item.Title
	}
	lines := []string{firstNonEmpty(item.Title, summary.Name)}
	for _, field := range []string{summary.CommandPreview, summary.QueryPreview, summary.OutputPreview, summary.ErrorPreview} {
		if field = strings.TrimSpace(field); field != "" {
			lines = append(lines, field)
		}
	}
	for _, change := range summary.Changes {
		lines = append(lines, fmt.Sprintf("%s %s", firstNonEmpty(string(change.Kind), "changed"), change.Path))
	}
	return strings.Join(lines, "\n")
}

// forkContextItem shows the conversation a fork handed its session in front
// of the message messageID.
func forkContextItem(messageID MessageID, conversation string) *Item {
	return &Item{
		ID:      forkContextItemID(messageID),
		Kind:    provider.ItemKindForkContext,
		Title:   "Earlier conversation",
		Status:  provider.ItemStatusCompleted,
		Payload: marshalEventPayload(map[string]string{"text": conversation}),
	}
}

func forkContextItemID(messageID MessageID) string { return "fork-context:" + string(messageID) }

// ForkHandoff is the conversation a fork still has to hand the thread's
// agent session, with the next turn the thread starts.
type ForkHandoff struct {
	Conversation string
	// FreshSession: turns reached the agent but failed before it answered,
	// so its session may or may not hold the conversation. A new session
	// gets it exactly once.
	FreshSession bool
}

// forkHandoff is what the thread's session still needs of the conversation
// a fork handed the thread: nothing once a turn reached the agent and it
// answered or the turn didn't fail, as the session then holds it.
func forkHandoff(thread Thread) *ForkHandoff {
	conversation := forkContextText(thread.Timeline)
	if conversation == "" {
		return nil
	}
	turns := thread.PreviousTurns
	if thread.LatestTurn != nil {
		turns = append(slices.Clip(turns), *thread.LatestTurn)
	}
	handoff := &ForkHandoff{Conversation: conversation}
	for _, turn := range turns {
		if turn.ProviderTurnID == "" {
			continue
		}
		if turn.State != TurnStateError || answered(thread.Timeline, turn.ID) {
			return nil
		}
		handoff.FreshSession = true
	}
	return handoff
}

// answered reports whether the agent produced anything in the turn, which
// it can only have done with the turn's prompt.
func answered(timeline Timeline, turnID TurnID) bool {
	return slices.ContainsFunc(timeline, func(entry TimelineEntry) bool {
		switch {
		case entry.Message != nil:
			return entry.Message.TurnID == turnID && entry.Message.Role == MessageRoleAssistant
		case entry.Item != nil:
			return entry.Item.TurnID == turnID && entry.Item.Kind != provider.ItemKindError && entry.Item.Kind != provider.ItemKindWarning
		case entry.Approval != nil:
			return entry.Approval.TurnID == turnID
		}
		return false
	})
}

// forkContextText is the conversation a fork handed the thread, if any.
func forkContextText(timeline Timeline) string {
	for _, entry := range timeline {
		if entry.Item != nil && entry.Item.Kind == provider.ItemKindForkContext {
			return forkContextOf(*entry.Item)
		}
	}
	return ""
}

func forkContextOf(item Item) string {
	var payload struct {
		Text string `json:"text"`
	}
	_ = json.Unmarshal(item.Payload, &payload)
	return payload.Text
}
