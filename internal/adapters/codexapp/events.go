package codexapp

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// handleNotification maps app-server notifications to events of the native
// thread they name: maiD's threads and their children alike, since a child's
// notifications arrive on its parent's connection.
func (h *Instance) handleNotification(method string, raw json.RawMessage) {
	switch method {
	case "turn/started":
		var notification struct {
			ThreadID string  `json:"threadId"`
			Turn     appTurn `json:"turn"`
		}
		if json.Unmarshal(raw, &notification) == nil {
			h.turnStarted(notification.ThreadID, notification.Turn.ID)
		}
	case "turn/completed":
		var notification struct {
			ThreadID string  `json:"threadId"`
			Turn     appTurn `json:"turn"`
		}
		if json.Unmarshal(raw, &notification) == nil {
			h.turnCompleted(notification.ThreadID, notification.Turn)
		}
	case "item/started", "item/completed":
		var notification struct {
			ThreadID      string  `json:"threadId"`
			TurnID        string  `json:"turnId"`
			Item          appItem `json:"item"`
			StartedAtMs   int64   `json:"startedAtMs"`
			CompletedAtMs int64   `json:"completedAtMs"`
		}
		if json.Unmarshal(raw, &notification) == nil {
			h.item(method == "item/completed", notification.ThreadID, notification.TurnID, notification.Item, notification.StartedAtMs, notification.CompletedAtMs)
		}
	case "item/agentMessage/delta":
		h.textDelta(raw, provider.StreamAssistant, "")
	case "item/reasoning/summaryTextDelta":
		h.textDelta(raw, provider.StreamReasoning, "summary")
	case "item/reasoning/textDelta":
		h.textDelta(raw, provider.StreamReasoning, "content")
	case "item/reasoning/summaryPartAdded":
		// Part boundaries are derived from the index every reasoning delta
		// carries, so this notification adds nothing.
	case "item/commandExecution/outputDelta":
		h.commandOutput(raw)
	case "item/fileChange/patchUpdated":
		h.filePatch(raw)
	case "turn/plan/updated":
		h.plan(raw)
	case "thread/tokenUsage/updated":
		h.tokenUsage(raw)
	case "thread/name/updated":
		var notification struct {
			ThreadID   string `json:"threadId"`
			ThreadName string `json:"threadName"`
		}
		if json.Unmarshal(raw, &notification) == nil && notification.ThreadName != "" {
			h.emit(notification.ThreadID, provider.TitleChanged{Title: notification.ThreadName})
		}
	case "thread/goal/updated":
		var notification struct {
			ThreadID string  `json:"threadId"`
			TurnID   *string `json:"turnId"`
			Goal     appGoal `json:"goal"`
		}
		if json.Unmarshal(raw, &notification) != nil {
			return
		}
		if goal, ok := goalOf(&notification.Goal); ok {
			h.emit(notification.ThreadID, provider.GoalChanged{Goal: goal})
		}
		// thread/goal/set reports its change without a turn; changes a turn
		// makes carry its id.
		if notification.TurnID == nil {
			h.finishGoalChange(notification.ThreadID, notification.Goal)
		}
	case "thread/goal/cleared":
		var notification struct {
			ThreadID string `json:"threadId"`
		}
		if json.Unmarshal(raw, &notification) == nil {
			h.emit(notification.ThreadID, provider.GoalChanged{})
		}
	case "serverRequest/resolved":
		h.resolveServerRequest(raw)
	case "thread/closed", "thread/deleted":
		h.threadClosed(raw)
	case "error":
		var notification struct {
			ThreadID  string `json:"threadId"`
			TurnID    string `json:"turnId"`
			WillRetry bool   `json:"willRetry"`
			Error     struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if json.Unmarshal(raw, &notification) != nil || strings.TrimSpace(notification.Error.Message) == "" {
			return
		}
		// An error Codex retries is not fatal to the turn, and one outside a
		// turn has none to fail; otherwise the failed turn/completed that
		// follows carries it.
		if notification.WillRetry || notification.TurnID == "" {
			h.emit(notification.ThreadID, provider.Warning{Turn: notification.TurnID, Message: notification.Error.Message})
		}
	case "warning", "guardianWarning":
		var notification struct {
			ThreadID *string `json:"threadId"`
			Message  string  `json:"message"`
		}
		if json.Unmarshal(raw, &notification) == nil {
			if notification.ThreadID == nil {
				h.logger.Warn("Codex warning", "message", notification.Message)
				return
			}
			h.emit(*notification.ThreadID, provider.Warning{Message: notification.Message})
		}
	case "configWarning", "deprecationNotice":
		// Not about a thread: there is no conversation to show them in.
		var notification struct {
			Summary string  `json:"summary"`
			Details *string `json:"details"`
		}
		if json.Unmarshal(raw, &notification) == nil {
			h.logger.Warn("Codex "+method, "summary", notification.Summary, "details", stringValue(notification.Details))
		}
	case "model/rerouted":
		var notification struct {
			ThreadID, TurnID, FromModel, ToModel, Reason string
		}
		if json.Unmarshal(raw, &notification) == nil {
			message := fmt.Sprintf("Codex switched from %s to %s for this turn (%s).", notification.FromModel, notification.ToModel, notification.Reason)
			h.emit(notification.ThreadID, provider.Warning{Turn: notification.TurnID, Message: message})
		}
	case "mcpServer/startupStatus/updated":
		var notification struct {
			ThreadID *string `json:"threadId"`
			Name     string  `json:"name"`
			Status   string  `json:"status"`
			Error    *string `json:"error"`
		}
		if json.Unmarshal(raw, &notification) == nil && notification.Status == "failed" {
			message := fmt.Sprintf("MCP server %s failed to start", notification.Name)
			if detail := strings.TrimSpace(stringValue(notification.Error)); detail != "" {
				message += ": " + detail
			}
			if notification.ThreadID == nil {
				h.logger.Warn(message)
				return
			}
			h.emit(*notification.ThreadID, provider.Warning{Message: message})
		}
	case "account/updated", "account/login/completed":
		if method == "account/login/completed" {
			h.mu.Lock()
			h.pendingLoginID = ""
			h.mu.Unlock()
		}
		go func() {
			ctx, cancel := context.WithTimeout(h.ctx, 30*time.Second)
			defer cancel()
			if err := h.refreshAccount(ctx); err != nil {
				h.logger.Debug("refresh account after notification", "error", err)
			}
			h.emit("", provider.InstanceChanged{Info: h.Info()})
		}()
	case "skills/changed":
		go h.refreshActiveSkills()
	default:
		h.logger.Debug("ignored Codex app-server notification", "method", method)
	}
}

// turnStarted reports a turn Codex started: the pending delivery's, when one
// waits for a turn, else Codex's own.
func (h *Instance) turnStarted(thread, turn string) {
	h.mu.Lock()
	session := h.sessionLocked(thread)
	if session.started[turn] {
		h.mu.Unlock()
		return
	}
	session.started[turn] = true
	session.activeTurn = turn
	started := provider.TurnStarted{Turn: turn, By: provider.TurnByProvider}
	typed := ""
	if pending := session.pending; pending != nil && pending.awaits == awaitsCodexTurn {
		started.By, started.Delivery, typed = provider.TurnByClient, pending.delivery, pending.text
		session.pending = nil
	}
	h.mu.Unlock()
	h.emit(thread, started)
	if typed != "" {
		h.emitTyped(thread, turn, started.Delivery, typed)
	}
}

func (h *Instance) turnCompleted(thread string, turn appTurn) {
	state, settled := turnState(turn.Status)
	if !settled {
		state = provider.TurnCompleted
	}
	h.mu.Lock()
	session := h.sessionLocked(thread)
	first := !session.started[turn.ID]
	session.started[turn.ID] = true
	if session.activeTurn == turn.ID {
		session.activeTurn = ""
	}
	session.streamed = make(map[string]streamedItem)
	clear(session.entries)
	h.mu.Unlock()
	if first {
		h.emit(thread, provider.TurnStarted{Turn: turn.ID, By: provider.TurnByProvider})
	}
	h.emit(thread, provider.TurnSettled{Turn: turn.ID, State: state, Error: turnError(turn)})
}

// item reports an item's entries as it starts and completes, mapped as
// History maps the item, so the completed entry is the replayed one.
func (h *Instance) item(completed bool, thread, turn string, item appItem, startedMs, completedMs int64) {
	at := time.Now()
	status := provider.ItemStatusInProgress
	if completed {
		status = completedStatus(item)
		if completedMs > 0 {
			at = time.UnixMilli(completedMs)
		}
	} else {
		if startedMs > 0 {
			at = time.UnixMilli(startedMs)
		}
		if started := itemStatusFromApp(item.Status); started != "" {
			status = started
		}
	}
	entries := itemEntries(turn, item, status, at)
	h.mu.Lock()
	session := h.sessionLocked(thread)
	for _, entry := range entries {
		if completed {
			delete(session.entries, entry.Ref)
			delete(session.streamed, entry.Ref)
		} else {
			session.entries[entry.Ref] = entry
			if entry.Kind == provider.ItemKindAssistantMessage || entry.Kind == provider.ItemKindReasoning {
				session.streamed[entry.Ref] = streamedItem{text: entry.Text}
			}
		}
	}
	h.mu.Unlock()
	for _, entry := range entries {
		h.emit(thread, provider.EntryUpserted{Entry: entry})
	}
	for _, seen := range subagentsOf(item) {
		seen.Parent = thread
		h.emit(thread, seen)
	}
}

// textDelta streams an item's text. partKind is "summary" or "content" for
// reasoning deltas (naming which index identifies the part) and "" for
// assistant text. The completed reasoning item joins its parts as paragraphs
// (reasoningText), so a part change inserts the same break live, and the
// streamed text matches the completed entry.
func (h *Instance) textDelta(raw json.RawMessage, stream provider.StreamKind, partKind string) {
	var notification struct {
		ThreadID     string `json:"threadId"`
		TurnID       string `json:"turnId"`
		ItemID       string `json:"itemId"`
		Delta        string `json:"delta"`
		SummaryIndex int    `json:"summaryIndex"`
		ContentIndex int    `json:"contentIndex"`
	}
	if json.Unmarshal(raw, &notification) != nil || notification.Delta == "" {
		return
	}
	part := ""
	switch partKind {
	case "summary":
		part = fmt.Sprintf("summary:%d", notification.SummaryIndex)
	case "content":
		part = fmt.Sprintf("content:%d", notification.ContentIndex)
	}
	delta := notification.Delta
	h.mu.Lock()
	session := h.sessionLocked(notification.ThreadID)
	item, streaming := session.streamed[notification.ItemID]
	if part != "" && item.part != "" && item.part != part {
		delta = paragraphBreak(item.text) + delta
	}
	session.streamed[notification.ItemID] = streamedItem{text: item.text + delta, part: part}
	h.mu.Unlock()
	if !streaming {
		// The entry the text streams onto, should item/started not have made
		// one.
		kind := provider.ItemKindAssistantMessage
		if stream == provider.StreamReasoning {
			kind = provider.ItemKindReasoning
		}
		h.emit(notification.ThreadID, provider.EntryUpserted{Entry: provider.Entry{Ref: notification.ItemID, Turn: notification.TurnID, Kind: kind, Status: provider.ItemStatusInProgress, Text: delta, At: time.Now()}})
		return
	}
	h.emit(notification.ThreadID, provider.TextAppended{Entry: notification.ItemID, Turn: notification.TurnID, Stream: stream, Text: delta})
}

// paragraphBreak returns the newlines that make text end in a blank line.
func paragraphBreak(text string) string {
	switch {
	case text == "" || strings.HasSuffix(text, "\n\n"):
		return ""
	case strings.HasSuffix(text, "\n"):
		return "\n"
	default:
		return "\n\n"
	}
}

// commandOutput adds streamed output to a command's entry. Every update
// re-sends the whole entry, so output past the limit is dropped;
// item/completed carries the bounded aggregate anyway.
func (h *Instance) commandOutput(raw json.RawMessage) {
	var notification struct{ ThreadID, TurnID, ItemID, Delta string }
	if json.Unmarshal(raw, &notification) != nil || notification.Delta == "" {
		return
	}
	h.mu.Lock()
	session := h.sessionLocked(notification.ThreadID)
	entry, known := session.entries[notification.ItemID]
	if !known || entry.Tool == nil || len(entry.Tool.Output) >= appToolOutputLimit {
		h.mu.Unlock()
		return
	}
	tool := *entry.Tool
	tool.Output = boundedAppOutput(tool.Output + notification.Delta)
	entry.Tool = &tool
	session.entries[notification.ItemID] = entry
	h.mu.Unlock()
	h.emit(notification.ThreadID, provider.EntryUpserted{Entry: entry})
}

func (h *Instance) filePatch(raw json.RawMessage) {
	var notification struct {
		ThreadID, TurnID, ItemID string
		Changes                  []appFileUpdateChange `json:"changes"`
	}
	if json.Unmarshal(raw, &notification) != nil {
		return
	}
	h.mu.Lock()
	session := h.sessionLocked(notification.ThreadID)
	entry, known := session.entries[notification.ItemID]
	if !known {
		entry = provider.Entry{Ref: notification.ItemID, Turn: notification.TurnID, Kind: provider.ItemKindFileChange, Status: provider.ItemStatusInProgress, Title: "Changed files", At: time.Now()}
	}
	tool := provider.ToolCall{ProviderKind: "fileChange", Changes: providerFileChanges(notification.Changes)}
	entry.Tool = &tool
	session.entries[notification.ItemID] = entry
	h.mu.Unlock()
	h.emit(notification.ThreadID, provider.EntryUpserted{Entry: entry})
}

func (h *Instance) plan(raw json.RawMessage) {
	var notification struct {
		ThreadID, TurnID string
		Plan             []struct{ Step, Status string } `json:"plan"`
	}
	if json.Unmarshal(raw, &notification) != nil {
		return
	}
	steps := make([]appPlanStep, 0, len(notification.Plan))
	for _, step := range notification.Plan {
		steps = append(steps, appPlanStep{Step: step.Step, Status: step.Status})
	}
	h.emit(notification.ThreadID, provider.PlanChanged{Entries: planEntriesFromApp(steps)})
}

func (h *Instance) tokenUsage(raw json.RawMessage) {
	// total sums every request of the thread; last is the newest request,
	// whose tokens are what the context window holds now (as the Codex TUI
	// computes it).
	var notification struct {
		ThreadID, TurnID string
		TokenUsage       struct {
			Last struct {
				TotalTokens int `json:"totalTokens"`
			} `json:"last"`
			ModelContextWindow *int `json:"modelContextWindow"`
		} `json:"tokenUsage"`
	}
	if json.Unmarshal(raw, &notification) != nil {
		return
	}
	window := 0
	if notification.TokenUsage.ModelContextWindow != nil {
		window = *notification.TokenUsage.ModelContextWindow
	}
	h.emit(notification.ThreadID, provider.UsageChanged{Usage: provider.TokenUsage{UsedTokens: notification.TokenUsage.Last.TotalTokens, MaxTokens: window}})
}
