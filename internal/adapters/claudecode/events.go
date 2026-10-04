package claudecode

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/Aqothy/maiD/internal/provider"
)

// handleMessage receives every non-control stdout line of one session process
// in read order. It fences on the process pointer so a replaced process can
// never mutate its successor's state.
func (h *Instance) handleMessage(session *claudeSession, proc *sessionProcess, message sdkMessage) {
	h.mu.Lock()
	current := session.proc == proc
	h.mu.Unlock()
	if !current {
		return
	}
	// Subagent traffic is tagged with the spawning tool_use id. The parent
	// Task tool item already represents the delegation; nested narration and
	// tool calls would interleave confusingly with the main thread.
	if message.ParentToolUseID != nil && *message.ParentToolUseID != "" {
		return
	}
	switch message.Type {
	case "system":
		h.handleSystem(session, message)
	case "stream_event":
		h.handleStreamEvent(session, message)
	case "assistant":
		h.handleAssistant(session, message)
	case "user":
		h.handleUserMessage(session, message)
	case "result":
		h.handleResult(session, message)
	default:
		// rate_limit_event, tool_progress, tool_use_summary, auth_status,
		// prompt_suggestion, and future kinds are intentionally ignored.
	}
}

func (h *Instance) handleSystem(session *claudeSession, message sdkMessage) {
	switch message.Subtype {
	case "init":
		var init systemInit
		if json.Unmarshal(message.Raw, &init) != nil {
			return
		}
		h.mu.Lock()
		if init.SessionID != "" && init.SessionID != session.nativeSessionID {
			// The CLI is authoritative for the durable session id (a resume
			// of a missing transcript falls back to a fresh session).
			if h.localByNative[session.nativeSessionID] == session.localThreadID {
				delete(h.localByNative, session.nativeSessionID)
			}
			session.nativeSessionID = init.SessionID
			h.localByNative[init.SessionID] = session.localThreadID
		}
		changedMode := init.PermissionMode != "" && init.PermissionMode != session.permissionMode
		if changedMode {
			session.permissionMode = init.PermissionMode
			session.configOptions = h.configOptionsLocked(session.model, session.effort, session.permissionMode)
		}
		snapshot := append([]provider.ConfigOption(nil), session.configOptions...)
		h.mu.Unlock()
		if changedMode {
			h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventConfigOptionsUpdated, ThreadID: session.localThreadID, Payload: provider.RuntimeEventPayload{ConfigOptions: snapshot}})
		}
	case "status":
		var status systemStatus
		if json.Unmarshal(message.Raw, &status) != nil || status.PermissionMode == "" {
			return
		}
		h.mu.Lock()
		changed := status.PermissionMode != session.permissionMode
		if changed {
			session.permissionMode = status.PermissionMode
			session.configOptions = h.configOptionsLocked(session.model, session.effort, session.permissionMode)
		}
		snapshot := append([]provider.ConfigOption(nil), session.configOptions...)
		h.mu.Unlock()
		if changed {
			h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventConfigOptionsUpdated, ThreadID: session.localThreadID, Payload: provider.RuntimeEventPayload{ConfigOptions: snapshot}})
		}
	case "compact_boundary":
		var boundary compactBoundary
		_ = json.Unmarshal(message.Raw, &boundary)
		h.mu.Lock()
		turn := session.activeLocalTurn
		h.mu.Unlock()
		itemID := "compaction:" + trimmedOrDefault(message.UUID, session.nativeSessionID)
		payload := provider.RuntimeEventPayload{ItemType: provider.ItemKindContextCompaction, ItemStatus: provider.ItemStatusCompleted, Title: "Compacted context"}
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventItemCompleted, ThreadID: session.localThreadID, TurnID: turn, ItemID: itemID, Payload: payload})
	}
}

func (h *Instance) handleStreamEvent(session *claudeSession, message sdkMessage) {
	var event streamEvent
	if json.Unmarshal(message.Event, &event) != nil {
		return
	}
	h.mu.Lock()
	turn := session.activeLocalTurn
	h.mu.Unlock()
	switch event.Type {
	case "content_block_start":
		if event.ContentBlock == nil {
			return
		}
		block := event.ContentBlock
		switch block.Type {
		case "text", "thinking":
			prefix := "text"
			if block.Type == "thinking" {
				prefix = "reasoning"
			}
			h.mu.Lock()
			session.itemSeq++
			itemID := fmt.Sprintf("claude:%s:%s:%d", prefix, turn, session.itemSeq)
			session.openBlocks[event.Index] = itemID
			session.streamedText[itemID] = ""
			h.mu.Unlock()
		case "tool_use", "server_tool_use", "mcp_tool_use":
			state := newToolState(block.Name, block.Input)
			h.mu.Lock()
			session.openBlocks[event.Index] = block.ID
			session.toolStates[block.ID] = state
			h.mu.Unlock()
			if state.itemKind == "" {
				return // plan-only tools surface through turn.plan.updated
			}
			call := state.call
			h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventItemStarted, ThreadID: session.localThreadID, TurnID: turn, ItemID: block.ID, Payload: provider.RuntimeEventPayload{ItemType: state.itemKind, ItemStatus: provider.ItemStatusInProgress, Title: state.title, ToolCall: &call}})
		}
	case "content_block_delta":
		if event.Delta == nil {
			return
		}
		h.mu.Lock()
		itemID := session.openBlocks[event.Index]
		h.mu.Unlock()
		if itemID == "" {
			return
		}
		switch event.Delta.Type {
		case "text_delta", "thinking_delta":
			delta := event.Delta.Text
			kind := provider.RuntimeContentAssistantText
			if event.Delta.Type == "thinking_delta" {
				delta = event.Delta.Thinking
				kind = provider.RuntimeContentReasoningText
			}
			if delta == "" {
				return
			}
			h.mu.Lock()
			session.streamedText[itemID] += delta
			h.mu.Unlock()
			h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventContentDelta, ThreadID: session.localThreadID, TurnID: turn, ItemID: itemID, Payload: provider.RuntimeEventPayload{StreamKind: kind, Delta: delta}})
		case "input_json_delta":
			h.mu.Lock()
			state := session.toolStates[itemID]
			if state != nil {
				state.partialJSON += event.Delta.PartialJSON
			}
			h.mu.Unlock()
			if state != nil {
				h.refreshToolInput(session, turn, itemID, state, []byte(state.partialJSON))
			}
		}
	case "content_block_stop":
		h.mu.Lock()
		itemID := session.openBlocks[event.Index]
		delete(session.openBlocks, event.Index)
		state := session.toolStates[itemID]
		h.mu.Unlock()
		if state != nil && state.partialJSON != "" {
			h.refreshToolInput(session, turn, itemID, state, []byte(state.partialJSON))
		}
	case "message_delta":
		if event.Usage == nil {
			return
		}
		used := event.Usage.contextTokens()
		if used <= 0 {
			return
		}
		h.mu.Lock()
		window := session.contextWindow
		cost := session.costUSD
		h.mu.Unlock()
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventThreadTokenUsage, ThreadID: session.localThreadID, TurnID: turn, Payload: provider.RuntimeEventPayload{TokenUsage: &provider.TokenUsage{UsedTokens: used, MaxTokens: window, Cost: cost, Currency: costCurrency(cost)}}})
	}
}

// refreshToolInput re-parses a tool's (possibly partial) input JSON and emits
// a complete merged snapshot when the parse produced something new.
func (h *Instance) refreshToolInput(session *claudeSession, turn, itemID string, state *toolState, inputJSON []byte) {
	var input json.RawMessage
	if len(inputJSON) == 0 || json.Unmarshal(inputJSON, &input) != nil {
		return
	}
	fingerprint := string(input)
	h.mu.Lock()
	if state.fingerprint == fingerprint {
		h.mu.Unlock()
		return
	}
	state.fingerprint = fingerprint
	rebuilt := newToolState(state.call.Name, input)
	rebuilt.call.Output = state.call.Output
	rebuilt.call.Error = state.call.Error
	state.call = rebuilt.call
	state.title = rebuilt.title
	state.itemKind = rebuilt.itemKind
	call := state.call
	kind := state.itemKind
	title := state.title
	h.mu.Unlock()
	if kind == "" {
		if entries := planEntriesFromInput(input); entries != nil {
			h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventTurnPlanUpdated, ThreadID: session.localThreadID, TurnID: turn, Payload: provider.RuntimeEventPayload{PlanEntries: entries}})
		}
		return
	}
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventItemUpdated, ThreadID: session.localThreadID, TurnID: turn, ItemID: itemID, Payload: provider.RuntimeEventPayload{ItemType: kind, Title: title, ToolCall: &call}})
}

// handleAssistant treats per-block assistant snapshots as flush checkpoints:
// any text the deltas did not deliver is emitted as a final suffix, and tool
// blocks that never streamed are materialized.
func (h *Instance) handleAssistant(session *claudeSession, message sdkMessage) {
	var api apiMessage
	if json.Unmarshal(message.Message, &api) != nil {
		return
	}
	h.mu.Lock()
	turn := session.activeLocalTurn
	h.mu.Unlock()
	for _, block := range api.Content {
		switch block.Type {
		case "text", "thinking":
			kind := provider.RuntimeContentAssistantText
			itemKind := provider.ItemKindAssistantMessage
			snapshot := block.Text
			if block.Type == "thinking" {
				kind = provider.RuntimeContentReasoningText
				itemKind = provider.ItemKindReasoning
				snapshot = block.Thinking
			}
			itemID, missing := h.settleStreamedText(session, block.Type, snapshot)
			if missing != "" {
				h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventContentDelta, ThreadID: session.localThreadID, TurnID: turn, ItemID: itemID, Payload: provider.RuntimeEventPayload{StreamKind: kind, Delta: missing}})
			}
			if itemID != "" {
				h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventItemCompleted, ThreadID: session.localThreadID, TurnID: turn, ItemID: itemID, Payload: provider.RuntimeEventPayload{ItemType: itemKind, ItemStatus: provider.ItemStatusCompleted}})
			}
		case "tool_use", "server_tool_use", "mcp_tool_use":
			h.mu.Lock()
			state := session.toolStates[block.ID]
			known := state != nil
			h.mu.Unlock()
			if !known {
				state = newToolState(block.Name, block.Input)
				h.mu.Lock()
				session.toolStates[block.ID] = state
				h.mu.Unlock()
				if state.itemKind == "" {
					if entries := planEntriesFromInput(block.Input); entries != nil {
						h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventTurnPlanUpdated, ThreadID: session.localThreadID, TurnID: turn, Payload: provider.RuntimeEventPayload{PlanEntries: entries}})
					}
					continue
				}
				call := state.call
				h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventItemStarted, ThreadID: session.localThreadID, TurnID: turn, ItemID: block.ID, Payload: provider.RuntimeEventPayload{ItemType: state.itemKind, ItemStatus: provider.ItemStatusInProgress, Title: state.title, ToolCall: &call}})
				continue
			}
			h.refreshToolInput(session, turn, block.ID, state, block.Input)
		}
	}
}

// settleStreamedText matches an assistant snapshot block against the most
// recent open streamed item of the same kind and returns the missing suffix.
func (h *Instance) settleStreamedText(session *claudeSession, blockType, snapshot string) (string, string) {
	prefix := "claude:text:"
	if blockType == "thinking" {
		prefix = "claude:reasoning:"
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	var itemID string
	for _, id := range session.openBlocks {
		if strings.HasPrefix(id, prefix) {
			itemID = id
		}
	}
	if itemID == "" {
		// Streaming may be disabled or the block already closed; find the
		// latest streamed entry of this kind instead.
		for id := range session.streamedText {
			if strings.HasPrefix(id, prefix) && id > itemID {
				itemID = id
			}
		}
	}
	if itemID == "" {
		if snapshot == "" {
			return "", ""
		}
		session.itemSeq++
		itemID = fmt.Sprintf("%s%s:%d", prefix, session.activeLocalTurn, session.itemSeq)
		session.streamedText[itemID] = snapshot
		return itemID, snapshot
	}
	streamed := session.streamedText[itemID]
	delete(session.streamedText, itemID)
	if strings.HasPrefix(snapshot, streamed) && len(snapshot) > len(streamed) {
		return itemID, snapshot[len(streamed):]
	}
	return itemID, ""
}

// handleUserMessage carries tool_result blocks back to their tool items.
// Live user prompt echoes never appear here because maiD records the client
// prompt before dispatch and the CLI does not replay them without
// --replay-user-messages.
func (h *Instance) handleUserMessage(session *claudeSession, message sdkMessage) {
	var api userAPIMessage
	if json.Unmarshal(message.Message, &api) != nil {
		return
	}
	blocks, _ := api.blocks()
	h.mu.Lock()
	turn := session.activeLocalTurn
	h.mu.Unlock()
	for _, block := range blocks {
		if block.Type != "tool_result" || block.ToolUseID == "" {
			continue
		}
		h.mu.Lock()
		state := session.toolStates[block.ToolUseID]
		if state == nil || state.itemKind == "" {
			h.mu.Unlock()
			continue
		}
		output, attachments := toolResultContent(block.Content)
		status := provider.ItemStatusCompleted
		if block.IsError {
			status = provider.ItemStatusFailed
			state.call.Error = boundedOutput(output)
		} else {
			state.call.Output = boundedOutput(output)
		}
		if len(attachments) > 0 {
			state.call.Attachments = append(state.call.Attachments, attachments...)
		}
		state.completed = true
		call := state.call
		kind := state.itemKind
		title := state.title
		h.mu.Unlock()
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventItemCompleted, ThreadID: session.localThreadID, TurnID: turn, ItemID: block.ToolUseID, Payload: provider.RuntimeEventPayload{ItemType: kind, ItemStatus: status, Title: title, ToolCall: &call}})
	}
}

func (h *Instance) handleResult(session *claudeSession, message sdkMessage) {
	var result resultMessage
	if json.Unmarshal(message.Raw, &result) != nil {
		return
	}
	h.mu.Lock()
	turn := session.activeLocalTurn
	session.activeLocalTurn = ""
	var nextTurn string
	if len(session.queuedTurns) > 0 {
		nextTurn = session.queuedTurns[0]
		session.queuedTurns = session.queuedTurns[1:]
		session.activeLocalTurn = nextTurn
	}
	session.resetStreamStateLocked()
	usage := tokenUsageFromResult(result)
	if usage != nil {
		if usage.MaxTokens > 0 {
			session.contextWindow = usage.MaxTokens
		} else {
			usage.MaxTokens = session.contextWindow
		}
		session.costUSD = usage.Cost
	}
	h.mu.Unlock()
	if turn == "" {
		// A resume handshake emits an empty result with no active local turn;
		// emitting turn lifecycle there would corrupt session state.
		return
	}
	if usage != nil {
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventThreadTokenUsage, ThreadID: session.localThreadID, TurnID: turn, Payload: provider.RuntimeEventPayload{TokenUsage: usage}})
	}
	state, stopReason, errorMessage := turnStateFromResult(result)
	payload := provider.RuntimeEventPayload{TurnState: state, StopReason: stopReason, Message: errorMessage}
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventTurnCompleted, ThreadID: session.localThreadID, TurnID: turn, Payload: payload})
	if nextTurn != "" {
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventTurnStarted, ThreadID: session.localThreadID, TurnID: nextTurn})
	}
}

func (h *Instance) handleControlRequest(session *claudeSession, proc *sessionProcess, requestID string, request controlRequestBody, raw json.RawMessage) {
	h.mu.Lock()
	current := session.proc == proc
	h.mu.Unlock()
	if !current {
		_ = proc.client.respondControlError(requestID, "session process was replaced")
		return
	}
	if request.Subtype != "can_use_tool" {
		_ = proc.client.respondControlError(requestID, fmt.Sprintf("control request %q is not supported by maiD", request.Subtype))
		return
	}
	h.mu.Lock()
	turn := session.activeLocalTurn
	h.mu.Unlock()
	pending := &pendingApproval{
		controlRequestID: requestID,
		requestID:        "claude:" + requestID,
		localThread:      session.localThreadID,
		localTurn:        turn,
		toolName:         request.ToolName,
		input:            append(json.RawMessage(nil), request.Input...),
		suggestions:      request.PermissionSuggestions,
		client:           proc.client,
	}
	detail := approvalDetail(request)
	options := []provider.ApprovalOption{
		{ID: "accept", Name: "Allow once", Kind: "allow_once"},
		{ID: "acceptForSession", Name: "Allow for session", Kind: "allow_always"},
		{ID: "decline", Name: "Decline", Kind: "reject_once"},
	}
	pending.requestType = approvalRequestType(request.ToolName)
	switch request.ToolName {
	case "AskUserQuestion":
		var question askUserQuestion
		if json.Unmarshal(request.Input, &question) == nil && len(question.Questions) == 1 {
			pending.question = &question
			first := question.Questions[0]
			detail = first.Question
			options = options[:0]
			for index, option := range first.Options {
				name := option.Label
				options = append(options, provider.ApprovalOption{ID: fmt.Sprintf("answer:%d", index), Name: name, Kind: "allow_once"})
			}
			options = append(options, provider.ApprovalOption{ID: "decline", Name: "Dismiss", Kind: "reject_once"})
		} else {
			// Multi-question prompts cannot be expressed as one approval;
			// steer the model to plain text instead of wedging the turn.
			_ = proc.client.respondControl(requestID, map[string]any{"behavior": "deny", "message": "Structured multi-question prompts are not supported by this client. Ask the user in plain text."})
			return
		}
	case "ExitPlanMode":
		options = []provider.ApprovalOption{
			{ID: "accept", Name: "Approve plan", Kind: "allow_once"},
			{ID: "decline", Name: "Keep planning", Kind: "reject_once"},
		}
	}
	h.mu.Lock()
	h.pendingApprovals[pending.requestID] = pending
	h.mu.Unlock()
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventRequestOpened, ThreadID: session.localThreadID, TurnID: turn, ItemID: request.ToolUseID, RequestID: pending.requestID, Payload: provider.RuntimeEventPayload{RequestType: pending.requestType, Detail: detail, Args: append(json.RawMessage(nil), raw...), Options: options}})
}

func (h *Instance) RespondToRequest(_ context.Context, input provider.RespondToRequestInput) error {
	h.mu.Lock()
	pending := h.pendingApprovals[input.RequestID]
	if pending != nil {
		delete(h.pendingApprovals, input.RequestID)
	}
	h.mu.Unlock()
	if pending == nil {
		return fmt.Errorf("Claude Code approval request %q is not pending", input.RequestID)
	}
	decision := string(input.Decision)
	if input.OptionID != "" {
		decision = input.OptionID
	}
	payload, resolved := permissionResponse(pending, decision)
	if err := pending.client.respondControl(pending.controlRequestID, payload); err != nil {
		h.mu.Lock()
		if _, exists := h.pendingApprovals[input.RequestID]; !exists {
			h.pendingApprovals[input.RequestID] = pending
		}
		h.mu.Unlock()
		return err
	}
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventRequestResolved, ThreadID: pending.localThread, TurnID: pending.localTurn, RequestID: pending.requestID, Payload: provider.RuntimeEventPayload{RequestType: pending.requestType, Decision: resolved}})
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
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventRequestResolved, ThreadID: cancelled.localThread, TurnID: cancelled.localTurn, RequestID: cancelled.requestID, Payload: provider.RuntimeEventPayload{RequestType: cancelled.requestType, Decision: provider.ApprovalDecisionCancel, Cancelled: true}})
	}
}

func (h *Instance) cancelPendingApprovals() {
	h.mu.Lock()
	pending := h.pendingApprovals
	h.pendingApprovals = make(map[string]*pendingApproval)
	h.mu.Unlock()
	for _, request := range pending {
		_ = request.client.respondControl(request.controlRequestID, map[string]any{"behavior": "deny", "message": "The session is shutting down.", "interrupt": true})
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventRequestResolved, ThreadID: request.localThread, TurnID: request.localTurn, RequestID: request.requestID, Payload: provider.RuntimeEventPayload{RequestType: request.requestType, Decision: provider.ApprovalDecisionCancel, Cancelled: true}})
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
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventRequestResolved, ThreadID: pending.localThread, TurnID: pending.localTurn, RequestID: pending.requestID, Payload: provider.RuntimeEventPayload{RequestType: pending.requestType, Decision: provider.ApprovalDecisionCancel, Cancelled: true}})
	}
}
