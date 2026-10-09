package claudecode

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// replayEventsFromTranscript rebuilds the event stream a session produced
// live from its transcript, so a reopened thread shows what the user saw:
// only the current conversation (see conversation), one turn per prompt,
// steers inside their turn, and turns that were interrupted or failed as
// such. Event ids are deterministic and timestamps are nudged by microsecond
// offsets so ordering is stable, mirroring codexapp replay.
func replayEventsFromTranscript(threadID string, lines []transcriptLine) []provider.RuntimeEvent {
	r := &replay{threadID: threadID, tools: make(map[string]*replayTool)}
	// A title the user chose wins over one the CLI generated.
	customTitle, aiTitle := "", ""
	onConversation := conversation(lines)
	for index, line := range lines {
		if line.IsSidechain || line.chained() && !onConversation[index] {
			continue
		}
		switch line.Type {
		case "custom-title":
			customTitle = firstNonEmpty(line.CustomTitle, customTitle)
		case "ai-title":
			aiTitle = firstNonEmpty(line.AITitle, aiTitle)
		case "system":
			if line.Subtype == "compact_boundary" && r.turn != "" {
				itemID := "compaction:" + line.UUID
				r.emit(provider.RuntimeEventItemCompleted, itemID, "completed", r.at(line.Timestamp), provider.RuntimeEventPayload{ItemType: provider.ItemKindContextCompaction, ItemStatus: provider.ItemStatusCompleted, Title: "Compacted context"})
			}
		case "attachment":
			// A steer the CLI folded into a running query joins that turn,
			// as it did live.
			if text, attachments, ok := steeredPrompt(line.Attachment); ok {
				at := r.at(line.Timestamp)
				if r.turn == "" {
					r.startTurn(line.UUID, at)
				}
				r.userMessage(line.UUID, text, attachments, at)
			}
		case "user":
			r.user(line)
		case "assistant":
			r.assistant(line)
		}
	}
	// Tools with no recorded result were cut off mid-flight.
	for id, tool := range r.tools {
		if tool.state.itemKind == "" {
			continue
		}
		call := tool.state.call
		r.events = append(r.events, provider.RuntimeEvent{
			EventID: replayEventID(tool.turnID, id, "completed"), Type: provider.RuntimeEventItemCompleted,
			Provider: DriverKind, ThreadID: threadID, TurnID: tool.turnID, ItemID: id, CreatedAt: tool.at.Add(time.Millisecond),
			Payload: provider.RuntimeEventPayload{ItemType: tool.state.itemKind, ItemStatus: provider.ItemStatusInterrupted, Title: tool.state.title, ToolCall: &call},
		})
	}
	r.endTurn(r.lastAt.Add(time.Microsecond))
	if title := firstNonEmpty(customTitle, aiTitle); title != "" {
		r.events = append(r.events, provider.RuntimeEvent{
			EventID: provider.RuntimeEventID("claude:replay:title"), Type: provider.RuntimeEventThreadMetadataUpdate,
			Provider: DriverKind, ThreadID: threadID, CreatedAt: r.lastAt.Add(2 * time.Microsecond),
			Payload: provider.RuntimeEventPayload{Title: title},
		})
	}
	return r.events
}

type replayTool struct {
	state  *toolState
	turnID string
	at     time.Time
}

type replay struct {
	threadID string
	events   []provider.RuntimeEvent
	tools    map[string]*replayTool
	tasks    taskPlan
	// turn is the open turn; turnState and turnMessage say how it ends.
	turn        string
	turnState   provider.RuntimeTurnState
	turnMessage string
	lastAt      time.Time
	offset      int
}

func replayEventID(turn, item, suffix string) provider.RuntimeEventID {
	return provider.RuntimeEventID("claude:replay:" + turn + ":" + item + ":" + suffix)
}

// at is a line's timestamp, or just after the previous one when it has none.
func (r *replay) at(stamp string) time.Time {
	r.offset++
	if parsed, err := time.Parse(time.RFC3339Nano, stamp); err == nil {
		r.lastAt = parsed
		return parsed
	}
	return r.lastAt.Add(time.Duration(r.offset) * time.Microsecond)
}

// emit appends an event of the open turn.
func (r *replay) emit(eventType provider.RuntimeEventType, itemID, suffix string, at time.Time, payload provider.RuntimeEventPayload) {
	r.events = append(r.events, provider.RuntimeEvent{
		EventID: replayEventID(r.turn, itemID, suffix), Type: eventType, Provider: DriverKind,
		ThreadID: r.threadID, TurnID: r.turn, ItemID: itemID, CreatedAt: at, Payload: payload,
	})
}

func (r *replay) startTurn(id string, at time.Time) {
	r.endTurn(at)
	r.turn = firstNonEmpty(id, fmt.Sprintf("turn-%d", r.offset))
	r.turnState, r.turnMessage = provider.RuntimeTurnCompleted, ""
	r.emit(provider.RuntimeEventTurnStarted, "", "turn-started", at, provider.RuntimeEventPayload{})
}

func (r *replay) endTurn(at time.Time) {
	if r.turn == "" {
		return
	}
	r.emit(provider.RuntimeEventTurnCompleted, "", "turn-completed", at.Add(time.Nanosecond), provider.RuntimeEventPayload{TurnState: r.turnState, Message: r.turnMessage})
	r.turn = ""
}

func (r *replay) userMessage(id, text string, attachments []provider.Attachment, at time.Time) {
	r.emit(provider.RuntimeEventItemCompleted, "user:"+id, "user", at.Add(time.Nanosecond), provider.RuntimeEventPayload{ItemType: provider.ItemKindUserMessage, ItemStatus: provider.ItemStatusCompleted, Detail: text, Attachments: attachments})
}

func (r *replay) user(line transcriptLine) {
	var api userAPIMessage
	if json.Unmarshal(line.Message, &api) != nil {
		return
	}
	blocks, text := api.blocks()
	hasToolResult := false
	for _, block := range blocks {
		if block.Type != "tool_result" {
			continue
		}
		hasToolResult = true
		tool := r.tools[block.ToolUseID]
		if tool == nil {
			continue
		}
		delete(r.tools, block.ToolUseID)
		if tool.state.itemKind == "" {
			if !block.IsError && r.tasks.apply(tool.state.call.ProviderKind, tool.state.input, line.ToolUseResult) {
				r.events = append(r.events, provider.RuntimeEvent{
					EventID: replayEventID(tool.turnID, block.ToolUseID, "plan"), Type: provider.RuntimeEventTurnPlanUpdated,
					Provider: DriverKind, ThreadID: r.threadID, TurnID: tool.turnID, CreatedAt: r.at(line.Timestamp),
					Payload: provider.RuntimeEventPayload{PlanEntries: r.tasks.entries()},
				})
			}
			continue
		}
		status := tool.state.applyResult(block, line.ToolUseResult)
		call := tool.state.call
		r.events = append(r.events, provider.RuntimeEvent{
			EventID: replayEventID(tool.turnID, block.ToolUseID, "completed"), Type: provider.RuntimeEventItemCompleted,
			Provider: DriverKind, ThreadID: r.threadID, TurnID: tool.turnID, ItemID: block.ToolUseID, CreatedAt: r.at(line.Timestamp),
			Payload: provider.RuntimeEventPayload{ItemType: tool.state.itemKind, ItemStatus: status, Title: tool.state.title, ToolCall: &call},
		})
	}
	if hasToolResult {
		return
	}
	prompt := classifyUserLine(line, blocks, text)
	switch prompt.kind {
	case userLineInterrupt:
		if r.turn != "" {
			r.turnState = provider.RuntimeTurnInterrupted
		}
	case userLineWake:
		// A message from elsewhere (a background task finishing) wakes the
		// CLI into a turn of its own, as it did live, with no prompt.
		r.startTurn(line.UUID, r.at(line.Timestamp))
	case userLinePrompt:
		at := r.at(line.Timestamp)
		r.startTurn(line.UUID, at)
		r.userMessage(r.turn, prompt.text, prompt.attachments, at)
	}
}

func (r *replay) assistant(line transcriptLine) {
	var api apiMessage
	if json.Unmarshal(line.Message, &api) != nil {
		return
	}
	at := r.at(line.Timestamp)
	if r.turn == "" {
		// Output with no prompt before it is a turn the CLI started.
		r.startTurn(line.UUID, at)
	}
	if line.IsAPIErrorMessage {
		// The CLI writes a failed API request as an assistant message whose
		// text is the error; the turn failed with it.
		r.turnState = provider.RuntimeTurnFailed
		for _, block := range api.Content {
			r.turnMessage = firstNonEmpty(strings.TrimSpace(block.Text), r.turnMessage)
		}
		return
	}
	for index, block := range api.Content {
		itemID := fmt.Sprintf("%s:%d", firstNonEmpty(line.UUID, api.ID), index)
		blockAt := at.Add(time.Duration(index) * time.Microsecond)
		switch block.Type {
		case "text", "thinking":
			text, kind, itemKind := block.Text, provider.RuntimeContentAssistantText, provider.ItemKindAssistantMessage
			payload := provider.RuntimeEventPayload{ItemType: itemKind, ItemStatus: provider.ItemStatusCompleted}
			if block.Type == "thinking" {
				text, kind = block.Thinking, provider.RuntimeContentReasoningText
				payload = provider.RuntimeEventPayload{ItemType: provider.ItemKindReasoning, ItemStatus: provider.ItemStatusCompleted, Detail: text}
			}
			if text == "" {
				continue
			}
			r.emit(provider.RuntimeEventContentDelta, itemID, "content", blockAt, provider.RuntimeEventPayload{StreamKind: kind, Delta: text})
			r.emit(provider.RuntimeEventItemCompleted, itemID, "completed", blockAt.Add(time.Nanosecond), payload)
		case "tool_use", "server_tool_use", "mcp_tool_use":
			state := newToolState(block.Name, block.Input)
			if state.itemKind == "" {
				// TodoWrite's input is the plan; the Task tools' results are.
				if entries := planEntriesFromInput(block.Input); entries != nil {
					r.emit(provider.RuntimeEventTurnPlanUpdated, itemID, "plan", blockAt, provider.RuntimeEventPayload{PlanEntries: entries})
				}
				r.tools[block.ID] = &replayTool{state: state, turnID: r.turn, at: blockAt}
				continue
			}
			call := state.call
			r.emit(provider.RuntimeEventItemStarted, block.ID, "started", blockAt, provider.RuntimeEventPayload{ItemType: state.itemKind, ItemStatus: provider.ItemStatusInProgress, Title: state.title, ToolCall: &call})
			r.tools[block.ID] = &replayTool{state: state, turnID: r.turn, at: blockAt}
		}
	}
}

// userLineKind is what a user line without tool results is to the
// conversation.
type userLineKind int

const (
	// userLineHidden is CLI bookkeeping written as a user message: local
	// command output, the compaction summary, meta lines.
	userLineHidden userLineKind = iota
	userLinePrompt
	// userLineWake is a message from elsewhere (a background task finishing)
	// that starts a turn with no prompt.
	userLineWake
	// userLineInterrupt is the marker the CLI writes when the user
	// interrupts a turn.
	userLineInterrupt
)

type userLine struct {
	kind        userLineKind
	text        string
	attachments []provider.Attachment
}

var (
	commandNamePattern = regexp.MustCompile(`<command-name>(.*?)</command-name>`)
	commandArgsPattern = regexp.MustCompile(`(?s)<command-args>(.*?)</command-args>`)
)

// classifyUserLine sorts a user line, following the lines the SDK's session
// listing skips. A slash command is written as markup; it shows as typed.
func classifyUserLine(line transcriptLine, blocks []contentBlock, text string) userLine {
	text, attachments := promptContent(blocks, text)
	trimmed := strings.TrimSpace(text)
	switch {
	case line.IsMeta || line.IsCompactSummary || line.IsVisibleInTranscriptOnly:
		return userLine{kind: userLineHidden}
	case strings.HasPrefix(trimmed, "[Request interrupted by user"):
		return userLine{kind: userLineInterrupt}
	case strings.HasPrefix(trimmed, "<local-command-"):
		return userLine{kind: userLineHidden}
	case !line.Origin.fromUser():
		return userLine{kind: userLineWake}
	case trimmed == "" && len(attachments) == 0:
		return userLine{kind: userLineHidden}
	}
	if match := commandNamePattern.FindStringSubmatch(trimmed); match != nil {
		text = strings.TrimSpace(match[1])
		if args := commandArgsPattern.FindStringSubmatch(trimmed); args != nil && strings.TrimSpace(args[1]) != "" {
			text += " " + strings.TrimSpace(args[1])
		}
	}
	return userLine{kind: userLinePrompt, text: text, attachments: attachments}
}
