package claudecode

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/Aqothy/maiD/internal/adapters/elicitation"
	"github.com/Aqothy/maiD/internal/provider"
)

// handleMessage receives every non-control stdout line of one session process
// in read order and maps it as the transcript line it becomes would be
// (mapper). It fences on the process pointer so a replaced process can never
// touch its successor's state.
func (h *Instance) handleMessage(session *claudeSession, proc *sessionProcess, message sdkMessage) {
	h.mu.Lock()
	current := session.proc == proc
	h.mu.Unlock()
	if !current {
		return
	}
	settled := false
	session.mapMu.Lock()
	m := session.live
	if parent := message.ParentToolUseID; parent != nil && *parent != "" {
		// A subagent's message, tagged with the tool use that runs it.
		sub := session.subagents[*parent]
		if sub == nil {
			session.mapMu.Unlock()
			return
		}
		m = sub.live
	}
	now := time.Now()
	switch message.Type {
	case "system":
		h.handleSystem(session, message, now)
	case "stream_event":
		h.handleStreamEvent(session, m, message, now)
	case "assistant":
		if message.Error == "authentication_failed" {
			h.markSignedOut()
		}
		var api apiMessage
		// A failed API request comes as an assistant message whose text is
		// the error; the failed result carries the same error for the turn.
		if json.Unmarshal(message.Message, &api) == nil && (message.Error == "" || message.Error == "max_output_tokens") {
			for _, block := range api.Content {
				m.assistant(firstNonEmpty(api.ID, message.UUID), block, now)
			}
		}
	case "user":
		var api userAPIMessage
		if json.Unmarshal(message.Message, &api) != nil {
			break
		}
		blocks, text := api.blocks()
		if message.IsReplay {
			if !session.unechoed[message.UUID] {
				// The CLI echoes messages it wrote itself too, such as a
				// background subagent's report; they wake it, as the
				// transcript replays them.
				m.wake(now)
				break
			}
			delete(session.unechoed, message.UUID)
			text, attachments := promptContent(blocks, text)
			m.echo(message.UUID, text, attachments, now)
			break
		}
		for _, block := range blocks {
			if block.Type == "tool_result" {
				h.toolResult(session, m, block, message.ToolUseResult, now)
			}
		}
	case "result":
		settled = h.handleResult(session, message, now)
	case "conversation_reset":
		h.clearConversation(session, message.NewConversationID, now)
	default:
		// rate_limit_event, tool_progress, tool_use_summary, auth_status,
		// prompt_suggestion, and future kinds are intentionally ignored.
	}
	session.mapMu.Unlock()
	if settled {
		h.publishTitle(session)
	}
}

// toolResult records a tool's result; one that ran a subagent ends the
// subagent's run.
func (h *Instance) toolResult(session *claudeSession, m *mapper, block contentBlock, structured json.RawMessage, at time.Time) {
	m.toolResult(block, structured, at)
	if _, running := m.tools[block.ToolUseID]; running {
		return
	}
	delete(session.tasks, block.ToolUseID)
	if session.subagents[block.ToolUseID] != nil {
		h.endSubagent(session, block.ToolUseID, block.IsError, at)
	}
}

// endSubagent settles the subagent's run, whose messages end with its tool.
func (h *Instance) endSubagent(session *claudeSession, toolUseID string, failed bool, at time.Time) {
	sub := session.subagents[toolUseID]
	delete(session.subagents, toolUseID)
	sub.live.cutOff(at)
	state := provider.TurnCompleted
	if failed {
		state = provider.TurnFailed
	}
	sub.live.settle(state, "", "", at)
}

func (h *Instance) handleSystem(session *claudeSession, message sdkMessage, at time.Time) {
	m := session.live
	switch message.Subtype {
	case "init":
		var init systemInit
		if json.Unmarshal(message.Raw, &init) != nil {
			return
		}
		h.mu.Lock()
		session.activeModel = init.Model
		h.mu.Unlock()
		h.syncSettings(session, init.PermissionMode, init.Model)
	case "status":
		var status systemStatus
		if json.Unmarshal(message.Raw, &status) != nil {
			return
		}
		h.syncSettings(session, status.PermissionMode, "")
		switch {
		case status.Status != nil && *status.Status == "compacting":
			m.compaction(provider.ItemStatusInProgress, "", at)
		case status.CompactResult == "failed":
			m.compaction(provider.ItemStatusFailed, status.CompactError, at)
		}
	case "compact_boundary":
		m.compaction(provider.ItemStatusCompleted, "", at)
	case "task_started":
		// Every task registers while the tool that starts it still runs; an
		// agent's task is the agent, whose id names its transcript.
		var started struct {
			TaskID       string `json:"task_id"`
			ToolUseID    string `json:"tool_use_id"`
			Description  string `json:"description"`
			SubagentType string `json:"subagent_type"`
		}
		if json.Unmarshal(message.Raw, &started) != nil || started.ToolUseID == "" || started.TaskID == "" {
			return
		}
		session.tasks[started.ToolUseID] = started.TaskID
		if started.SubagentType == "" || session.subagents[started.ToolUseID] != nil {
			return
		}
		parent := session.live
		for _, sub := range session.subagents {
			if _, ok := sub.live.tools[started.ToolUseID]; ok {
				parent = sub.live
			}
		}
		key := subagentKey(session.id, started.TaskID)
		sub := &subagent{key: key}
		sub.live = newMapper(key, func(body provider.EventBody, at time.Time) { h.emitAt(key, body, at) })
		sub.live.agent = started.TaskID
		session.subagents[started.ToolUseID] = sub
		// Named before anything streams into its session.
		h.emitAt(parent.session, provider.SubagentSeen{
			Parent: parent.session, Item: started.ToolUseID, Session: key, Name: firstNonEmpty(started.Description, started.SubagentType),
		}, at)
		var input struct {
			Prompt string `json:"prompt"`
		}
		if tool := parent.tools[started.ToolUseID]; tool != nil && json.Unmarshal(tool.state.input, &input) == nil && input.Prompt != "" {
			sub.live.prompt("", input.Prompt, nil, at)
		}
	case "task_notification":
		var notification taskNotification
		if json.Unmarshal(message.Raw, &notification) != nil {
			return
		}
		delete(session.tasks, notification.ToolUseID)
		for _, mapped := range h.mappers(session) {
			mapped.taskEnded(notification, at)
		}
		if session.subagents[notification.ToolUseID] != nil {
			h.endSubagent(session, notification.ToolUseID, notification.Status == "failed", at)
		}
	case "api_retry":
		var retry apiRetry
		if json.Unmarshal(message.Raw, &retry) == nil {
			h.emitAt(session.id, provider.Warning{Turn: m.turn, Message: retry.message()}, at)
		}
	case "informational":
		// Warnings, and notices that stop the turn (a hook blocking the
		// prompt), are the only reason the user gets for what happened.
		var notice systemInformational
		if json.Unmarshal(message.Raw, &notice) == nil && strings.TrimSpace(notice.Content) != "" && (notice.Level == "warning" || notice.PreventContinuation) {
			h.emitAt(session.id, provider.Warning{Turn: m.turn, Message: strings.TrimSpace(notice.Content)}, at)
		}
	}
}

// mappers are the session's and its live subagents'.
func (h *Instance) mappers(session *claudeSession) []*mapper {
	mappers := []*mapper{session.live}
	for _, sub := range session.subagents {
		mappers = append(mappers, sub.live)
	}
	return mappers
}

// syncSettings records the permission mode and model the CLI reports, which
// change through the CLI itself too (plan mode exit, /model), and publishes
// the options when they changed.
func (h *Instance) syncSettings(session *claudeSession, mode, model string) {
	h.mu.Lock()
	changed := false
	if mode != "" && mode != session.permissionMode {
		session.permissionMode, changed = mode, true
	}
	if value := h.modelValueLocked(session.model, model); value != session.model {
		session.model, changed = value, true
	}
	if changed {
		session.options = h.configOptionsLocked(session.model, session.effort, session.permissionMode)
	}
	options := append([]provider.ConfigOption(nil), session.options...)
	h.mu.Unlock()
	if changed {
		h.emit(session.id, provider.ConfigChanged{Options: options})
	}
}

// clearConversation handles conversation_reset (/clear, or leaving plan mode
// with a cleared context): the CLI continues in a new session, which the
// thread follows.
func (h *Instance) clearConversation(session *claudeSession, next string, at time.Time) {
	if next == "" || next == session.id {
		return
	}
	previous := session.id
	session.live.settle(provider.TurnCompleted, "", "", at)
	h.mu.Lock()
	if h.sessions[previous] == session {
		delete(h.sessions, previous)
	}
	session.id = next
	h.sessions[next] = session
	h.mu.Unlock()
	session.live = newMapper(next, func(body provider.EventBody, at time.Time) { h.emitAt(session.id, body, at) })
	h.emitAt(previous, provider.SessionReplaced{New: next}, at)
}

func (h *Instance) handleStreamEvent(session *claudeSession, m *mapper, message sdkMessage, at time.Time) {
	var event streamEvent
	if json.Unmarshal(message.Event, &event) != nil {
		return
	}
	switch event.Type {
	case "message_start":
		if event.Message != nil {
			m.streaming = event.Message.ID
		}
	case "content_block_start":
		if event.ContentBlock != nil && m.streaming != "" {
			m.streamStart(m.streaming, event.Index, *event.ContentBlock, at)
		}
	case "content_block_delta":
		if event.Delta == nil {
			return
		}
		switch event.Delta.Type {
		case "text_delta":
			m.streamText(event.Index, event.Delta.Text, at)
		case "thinking_delta":
			m.streamText(event.Index, event.Delta.Thinking, at)
		case "input_json_delta":
			m.streamInput(event.Index, event.Delta.PartialJSON, at)
		}
	case "content_block_stop":
		m.streamStop(event.Index)
	case "message_delta":
		if event.Usage == nil || m != session.live {
			return
		}
		used := event.Usage.contextTokens()
		if used <= 0 {
			return
		}
		h.mu.Lock()
		session.contextTokens = used
		usage := provider.TokenUsage{UsedTokens: used, MaxTokens: session.contextWindow, Cost: session.costUSD, Currency: costCurrency(session.costUSD)}
		h.mu.Unlock()
		h.emitAt(session.id, provider.UsageChanged{Usage: usage}, at)
	}
}

// handleResult ends the query's turn and reports whether one ended.
func (h *Instance) handleResult(session *claudeSession, message sdkMessage, at time.Time) bool {
	var result resultMessage
	if json.Unmarshal(message.Raw, &result) != nil {
		return false
	}
	h.mu.Lock()
	usage := tokenUsageFromResult(result, session.activeModel)
	if usage != nil {
		if usage.MaxTokens > 0 {
			session.contextWindow = usage.MaxTokens
		} else {
			usage.MaxTokens = session.contextWindow
		}
		// A local command (/context, /model) makes no API request, so its
		// result reports no usage while the context is unchanged.
		if usage.UsedTokens > 0 {
			session.contextTokens = usage.UsedTokens
		} else {
			usage.UsedTokens = session.contextTokens
		}
		session.costUSD = usage.Cost
	}
	h.mu.Unlock()
	// A resume handshake emits an empty result with no turn running.
	if session.live.turn == "" {
		return false
	}
	if usage != nil {
		h.emitAt(session.id, provider.UsageChanged{Usage: *usage}, at)
	}
	state, stopReason, errorText := turnStateFromResult(result)
	session.live.settle(state, stopReason, errorText, at)
	return true
}

func (h *Instance) handleControlRequest(session *claudeSession, proc *sessionProcess, requestID string, request controlRequestBody, raw json.RawMessage) {
	h.mu.Lock()
	current := session.proc == proc
	h.mu.Unlock()
	if !current {
		_ = proc.client.respondControlError(requestID, "session process was replaced")
		return
	}
	if request.Subtype != "can_use_tool" && request.Subtype != "elicitation" {
		_ = proc.client.respondControlError(requestID, fmt.Sprintf("control request %q is not supported by maiD", request.Subtype))
		return
	}
	// A subagent's request belongs to its session, in its run.
	session.mapMu.Lock()
	key, turn := session.id, session.live.turn
	for _, sub := range session.subagents {
		if request.AgentID != "" && sub.live.agent == request.AgentID {
			key, turn = sub.key, sub.live.turn
		}
	}
	session.mapMu.Unlock()
	pending := &pendingApproval{controlRequestID: requestID, requestID: "claude:" + requestID, session: key, client: proc.client}
	var asked provider.Request
	entry := request.ToolUseID
	if request.Subtype == "elicitation" {
		var form *elicitation.Form
		var err error
		asked, form, err = elicitation.Parse(request.Message, request.Mode, request.URL, request.RequestedSchema)
		if err != nil {
			// The user never saw it, so it was neither accepted nor declined.
			_ = proc.client.respondControl(requestID, map[string]any{"action": elicitation.ActionCancel})
			return
		}
		pending.isElicitation, pending.form = true, form
		if form.Confirms() {
			asked.Details = append(json.RawMessage(nil), raw...)
		}
		entry = ""
	} else {
		pending.input = append(json.RawMessage(nil), request.Input...)
		pending.suggestions = request.PermissionSuggestions
		// Like the CLI, offer a lasting approval only with a rule to approve:
		// its suggestions, unless it says this request must not get one.
		asked = provider.Request{Message: approvalDetail(request), Details: append(json.RawMessage(nil), raw...), Actions: []provider.RequestAction{{ID: "accept", Label: "Allow once", Decision: provider.ApprovalDecisionAccept}}}
		if len(request.PermissionSuggestions) > 0 && !request.SuppressAlwaysAllowRule {
			asked.Actions = append(asked.Actions, provider.RequestAction{ID: "acceptForSession", Label: "Allow for session", Decision: provider.ApprovalDecisionAcceptForSession})
		}
		asked.Actions = append(asked.Actions, provider.RequestAction{ID: "decline", Label: "Decline", Decision: provider.ApprovalDecisionDecline})
		switch request.ToolName {
		case "AskUserQuestion":
			var question askUserQuestion
			if json.Unmarshal(request.Input, &question) != nil || len(question.Questions) == 0 {
				_ = proc.client.respondControl(requestID, map[string]any{"behavior": "deny", "message": "The question could not be shown. Ask the user in plain text."})
				return
			}
			pending.question = &question
			asked = question.request()
		case "ExitPlanMode":
			pending.reviewsPlan = true
			asked = planReviewRequest(request.Input)
		}
	}
	h.mu.Lock()
	h.pendingApprovals[pending.requestID] = pending
	h.mu.Unlock()
	h.emit(key, provider.RequestOpened{Request: pending.requestID, Turn: turn, Entry: entry, Ask: asked})
}

func (h *Instance) Respond(_ context.Context, key, request string, answer provider.RequestAnswer) error {
	h.mu.Lock()
	pending := h.pendingApprovals[request]
	h.mu.Unlock()
	if pending == nil || pending.session != key {
		return fmt.Errorf("Claude Code request %q is not pending", request)
	}
	// Build the reply before claiming the request: an invalid answer must
	// leave the question answerable.
	payload, err := approvalResponse(pending, answer)
	if err != nil {
		return err
	}
	h.mu.Lock()
	if h.pendingApprovals[request] != pending {
		h.mu.Unlock()
		return fmt.Errorf("Claude Code request %q is not pending", request)
	}
	delete(h.pendingApprovals, request)
	h.mu.Unlock()
	if err := pending.client.respondControl(pending.controlRequestID, payload); err != nil {
		h.mu.Lock()
		if _, exists := h.pendingApprovals[request]; !exists {
			h.pendingApprovals[request] = pending
		}
		h.mu.Unlock()
		return err
	}
	var answers map[string][]string
	if answer.Action.Submit {
		answers = answer.Answers
	}
	h.emit(key, provider.RequestResolved{Request: request, Action: answer.Action.ID, Answers: answers})
	return nil
}

func (h *Instance) handleControlCancel(requestID string) {
	var cancelled *pendingApproval
	h.mu.Lock()
	for key, pending := range h.pendingApprovals {
		if pending.controlRequestID == requestID {
			cancelled = pending
			delete(h.pendingApprovals, key)
			break
		}
	}
	h.mu.Unlock()
	if cancelled != nil {
		h.emit(cancelled.session, provider.RequestResolved{Request: cancelled.requestID})
	}
}

func (h *Instance) cancelApprovalsForClient(client *streamClient) {
	var resolved []*pendingApproval
	h.mu.Lock()
	for key, pending := range h.pendingApprovals {
		if pending.client == client {
			resolved = append(resolved, pending)
			delete(h.pendingApprovals, key)
		}
	}
	h.mu.Unlock()
	for _, pending := range resolved {
		h.emit(pending.session, provider.RequestResolved{Request: pending.requestID})
	}
}

// publishTitle shows the session's title once it has one. The CLI streams no
// title; it writes the user's /rename and its own generated title to the
// transcript, so the transcript is read after each result.
func (h *Instance) publishTitle(session *claudeSession) {
	h.mu.Lock()
	key := session.id
	h.mu.Unlock()
	path, err := h.findTranscript(key)
	if err != nil {
		return
	}
	file, err := os.Open(path)
	if err != nil {
		return
	}
	title := transcriptTitle(file)
	_ = file.Close()
	h.mu.Lock()
	changed := title != "" && title != session.title
	session.title = title
	h.mu.Unlock()
	if changed {
		h.emit(key, provider.TitleChanged{Title: title})
	}
}
