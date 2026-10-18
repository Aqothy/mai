package claudecode

import (
	"cmp"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/Aqothy/maiD/internal/adapters/elicitation"
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
		h.beginCLIStartedTurnIfIdle(session)
		h.handleStreamEvent(session, message)
	case "assistant":
		h.beginCLIStartedTurnIfIdle(session)
		h.handleAssistant(session, message)
	case "user":
		if message.IsReplay {
			// The CLI took a written message into a query. Orchestration
			// recorded the prompt when it was sent, so only the ack matters.
			h.mu.Lock()
			delete(session.unechoedInput, message.UUID)
			h.mu.Unlock()
			return
		}
		h.handleUserMessage(session, message)
	case "result":
		h.handleResult(session, message)
	case "conversation_reset":
		h.clearConversation(session, message)
	default:
		// rate_limit_event, tool_progress, tool_use_summary, auth_status,
		// prompt_suggestion, and future kinds are intentionally ignored.
	}
}

// beginCLIStartedTurnIfIdle gives output the CLI produced on its own (a
// background task or agent finishing wakes it) a turn of its own, so its
// content, approvals and result are attributed like any other turn's.
func (h *Instance) beginCLIStartedTurnIfIdle(session *claudeSession) {
	h.mu.Lock()
	if session.activeLocalTurn != "" {
		h.mu.Unlock()
		return
	}
	turn := "claude:" + newSessionUUID()
	session.activeLocalTurn = turn
	session.cliStartedTurn = true
	h.mu.Unlock()
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventTurnStarted, ThreadID: session.localThreadID, TurnID: turn})
}

func (h *Instance) handleSystem(session *claudeSession, message sdkMessage) {
	switch message.Subtype {
	case "init":
		var init systemInit
		if json.Unmarshal(message.Raw, &init) != nil {
			return
		}
		h.adoptSessionID(session, init.SessionID)
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
			h.compaction(session, provider.ItemStatusInProgress, "")
		case status.CompactResult == "failed":
			h.compaction(session, provider.ItemStatusFailed, status.CompactError)
		}
	case "compact_boundary":
		h.compaction(session, provider.ItemStatusCompleted, "")
	case "task_started":
		// Every task registers while the tool that starts it still runs.
		var started struct {
			TaskID    string `json:"task_id"`
			ToolUseID string `json:"tool_use_id"`
		}
		if json.Unmarshal(message.Raw, &started) == nil {
			h.mu.Lock()
			if state := session.toolStates[started.ToolUseID]; state != nil {
				state.taskID = started.TaskID
			}
			h.mu.Unlock()
		}
	case "task_notification":
		var notification taskNotification
		if json.Unmarshal(message.Raw, &notification) == nil {
			h.finishBackground(session, notification)
		}
	case "api_retry":
		var retry apiRetry
		if json.Unmarshal(message.Raw, &retry) == nil {
			h.emitWarning(session, retry.message())
		}
	case "informational":
		// Warnings, and notices that stop the turn (a hook blocking the
		// prompt), are the only reason the user gets for what happened.
		var notice systemInformational
		if json.Unmarshal(message.Raw, &notice) == nil && strings.TrimSpace(notice.Content) != "" && (notice.Level == "warning" || notice.PreventContinuation) {
			h.emitWarning(session, strings.TrimSpace(notice.Content))
		}
	}
}

// adoptSessionID follows the CLI to the session id it reports: a resume of
// a missing transcript starts a fresh session, and /clear continues in a new
// one. The next StartSession persists it as the thread's resume cursor.
func (h *Instance) adoptSessionID(session *claudeSession, sessionID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if sessionID == "" || sessionID == session.nativeSessionID {
		return
	}
	if h.localByNative[session.nativeSessionID] == session.localThreadID {
		delete(h.localByNative, session.nativeSessionID)
	}
	session.nativeSessionID = sessionID
	h.localByNative[sessionID] = session.localThreadID
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
		session.configOptions = h.configOptionsLocked(session.model, session.effort, session.permissionMode)
	}
	snapshot := append([]provider.ConfigOption(nil), session.configOptions...)
	h.mu.Unlock()
	if changed {
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventConfigOptionsUpdated, ThreadID: session.localThreadID, Payload: provider.RuntimeEventPayload{ConfigOptions: snapshot}})
	}
}

// compaction shows a compaction as one item: in progress while the CLI
// compacts, then completed or failed.
func (h *Instance) compaction(session *claudeSession, status provider.ItemStatus, errorText string) {
	h.mu.Lock()
	turn := session.activeLocalTurn
	itemID := session.compactionItem
	if status == provider.ItemStatusInProgress && itemID != "" {
		h.mu.Unlock()
		return
	}
	if itemID == "" {
		itemID = "compaction:" + newSessionUUID()
	}
	session.compactionItem = ""
	eventType, title := provider.RuntimeEventItemCompleted, "Compacted context"
	switch status {
	case provider.ItemStatusInProgress:
		session.compactionItem = itemID
		eventType, title = provider.RuntimeEventItemStarted, "Compacting context"
	case provider.ItemStatusFailed:
		title = trimmedOrDefault(errorText, "Compaction failed")
	}
	h.mu.Unlock()
	h.emitEvent(provider.RuntimeEvent{Type: eventType, ThreadID: session.localThreadID, TurnID: turn, ItemID: itemID, Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindContextCompaction, ItemStatus: status, Title: title}})
}

// clearConversation handles conversation_reset (/clear, or leaving plan mode
// with a cleared context): the CLI continues in a new session, so the thread
// follows it and marks where the context was cleared.
func (h *Instance) clearConversation(session *claudeSession, message sdkMessage) {
	h.adoptSessionID(session, message.NewConversationID)
	h.mu.Lock()
	turn := session.activeLocalTurn
	session.tasks = taskPlan{}
	session.seenAssistant = make(map[string]bool)
	h.mu.Unlock()
	itemID := "reset:" + trimmedOrDefault(message.UUID, newSessionUUID())
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventItemCompleted, ThreadID: session.localThreadID, TurnID: turn, ItemID: itemID, Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindContextCompaction, ItemStatus: provider.ItemStatusCompleted, Title: "Cleared context"}})
}

// finishBackground completes the item of a tool whose background task ended,
// in the turn that started it.
func (h *Instance) finishBackground(session *claudeSession, notification taskNotification) {
	h.mu.Lock()
	tool, running := session.background[notification.ToolUseID]
	delete(session.background, notification.ToolUseID)
	var status provider.ItemStatus
	var call provider.ToolCall
	if running {
		status = tool.state.finish(notification)
		call = tool.state.call
	}
	h.mu.Unlock()
	if running {
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventItemCompleted, ThreadID: session.localThreadID, TurnID: tool.turn, ItemID: notification.ToolUseID, Payload: provider.RuntimeEventPayload{ItemType: tool.state.itemKind, ItemStatus: status, Title: tool.state.title, ToolCall: &call}})
	}
}

func (h *Instance) emitWarning(session *claudeSession, message string) {
	h.mu.Lock()
	turn := session.activeLocalTurn
	h.mu.Unlock()
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventRuntimeWarning, ThreadID: session.localThreadID, TurnID: turn, Payload: provider.RuntimeEventPayload{Message: message}})
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
		session.contextTokens = used
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
	// ProviderKind is the tool's full name; Name is shortened for MCP tools.
	rebuilt := newToolState(state.call.ProviderKind, input)
	// A result already recorded wins; otherwise keep what the input itself
	// shows (ExitPlanMode's plan).
	rebuilt.call.Output = cmp.Or(state.call.Output, rebuilt.call.Output)
	rebuilt.call.Error = state.call.Error
	state.call = rebuilt.call
	state.title = rebuilt.title
	state.itemKind = rebuilt.itemKind
	state.input = rebuilt.input
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
	if message.Error == "authentication_failed" {
		h.markSignedOut()
	}
	var api apiMessage
	if json.Unmarshal(message.Message, &api) != nil {
		return
	}
	h.mu.Lock()
	turn := session.activeLocalTurn
	// After /compact the CLI sends the last kept assistant message again.
	duplicate := message.UUID != "" && session.seenAssistant[message.UUID]
	if message.UUID != "" {
		session.seenAssistant[message.UUID] = true
	}
	h.mu.Unlock()
	// A failed API request comes as an assistant message whose text is the
	// error; the failed result carries the same error for the turn.
	if duplicate || message.Error != "" && message.Error != "max_output_tokens" {
		return
	}
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
// Echoes of written prompts never reach it (handleMessage acks them).
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
		if state == nil {
			h.mu.Unlock()
			continue
		}
		if state.itemKind == "" {
			changed := !block.IsError && session.tasks.apply(state.call.ProviderKind, state.input, message.ToolUseResult)
			entries := session.tasks.entries()
			h.mu.Unlock()
			if changed {
				h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventTurnPlanUpdated, ThreadID: session.localThreadID, TurnID: turn, Payload: provider.RuntimeEventPayload{PlanEntries: entries}})
			}
			continue
		}
		status := state.applyResult(block, message.ToolUseResult)
		eventType := provider.RuntimeEventItemCompleted
		if status == provider.ItemStatusInProgress {
			session.background[block.ToolUseID] = backgroundTool{state: state, turn: turn}
			eventType = provider.RuntimeEventItemUpdated
		}
		call := state.call
		kind := state.itemKind
		title := state.title
		h.mu.Unlock()
		h.emitEvent(provider.RuntimeEvent{Type: eventType, ThreadID: session.localThreadID, TurnID: turn, ItemID: block.ToolUseID, Payload: provider.RuntimeEventPayload{ItemType: kind, ItemStatus: status, Title: title, ToolCall: &call}})
	}
}

func (h *Instance) handleResult(session *claudeSession, message sdkMessage) {
	var result resultMessage
	if json.Unmarshal(message.Raw, &result) != nil {
		return
	}
	h.mu.Lock()
	turn := session.activeLocalTurn
	// Messages written mid-turn that the CLI did not fold in run as one more
	// query, batched together; its result ends the turn.
	continues := turn != "" && len(session.unechoedInput) > 0
	if continues {
		session.unechoedInput = nil
	} else {
		session.endTurnLocked()
	}
	session.resetStreamStateLocked()
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
	if turn == "" {
		// A resume handshake emits an empty result with no active local turn;
		// emitting turn lifecycle there would corrupt session state.
		return
	}
	if usage != nil {
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventThreadTokenUsage, ThreadID: session.localThreadID, TurnID: turn, Payload: provider.RuntimeEventPayload{TokenUsage: usage}})
	}
	h.publishTitle(session)
	if continues {
		return
	}
	state, stopReason, errorMessage := turnStateFromResult(result)
	payload := provider.RuntimeEventPayload{TurnState: state, StopReason: stopReason, Message: errorMessage}
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventTurnCompleted, ThreadID: session.localThreadID, TurnID: turn, Payload: payload})
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
	h.mu.Lock()
	turn := session.activeLocalTurn
	h.mu.Unlock()
	if request.Subtype == "elicitation" {
		h.openElicitation(session, proc, requestID, request, raw, turn)
		return
	}
	pending := &pendingApproval{
		controlRequestID: requestID,
		requestID:        "claude:" + requestID,
		localThread:      session.localThreadID,
		localTurn:        turn,
		input:            append(json.RawMessage(nil), request.Input...),
		suggestions:      request.PermissionSuggestions,
		client:           proc.client,
	}
	detail := approvalDetail(request)
	// Like the CLI, offer a lasting approval only with a rule to approve:
	// its suggestions, unless it says this request must not get one.
	options := []provider.ApprovalOption{{ID: "accept", Name: "Allow once", Kind: "allow_once"}}
	if len(request.PermissionSuggestions) > 0 && !request.SuppressAlwaysAllowRule {
		options = append(options, provider.ApprovalOption{ID: "acceptForSession", Name: "Allow for session", Kind: "allow_always"})
	}
	options = append(options, provider.ApprovalOption{ID: "decline", Name: "Decline", Kind: "reject_once"})
	pending.requestType = approvalRequestType(request.ToolName)
	var userInput *provider.UserInputRequest
	switch request.ToolName {
	case "AskUserQuestion":
		var question askUserQuestion
		if json.Unmarshal(request.Input, &question) != nil || len(question.Questions) == 0 {
			_ = proc.client.respondControl(requestID, map[string]any{"behavior": "deny", "message": "The question could not be shown. Ask the user in plain text."})
			return
		}
		pending.question = &question
		input := question.userInput()
		userInput, options = &input, nil
	case "ExitPlanMode":
		pending.reviewsPlan = true
		input := planReviewInput(request.Input)
		userInput, options = &input, nil
	}
	h.mu.Lock()
	h.pendingApprovals[pending.requestID] = pending
	h.mu.Unlock()
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventRequestOpened, ThreadID: session.localThreadID, TurnID: turn, ItemID: request.ToolUseID, RequestID: pending.requestID, Payload: provider.RuntimeEventPayload{RequestType: pending.requestType, Detail: detail, Args: append(json.RawMessage(nil), raw...), Options: options, UserInput: userInput}})
}

// openElicitation surfaces an MCP server's elicitation as questions, or as a
// permission request when it only asks yes or no.
func (h *Instance) openElicitation(session *claudeSession, proc *sessionProcess, requestID string, request controlRequestBody, raw json.RawMessage, turn string) {
	input, form, err := elicitation.Parse(request.Message, request.Mode, request.URL, request.RequestedSchema)
	if err != nil {
		// The user never saw it, so it was neither accepted nor declined.
		_ = proc.client.respondControl(requestID, map[string]any{"action": elicitation.ActionCancel})
		return
	}
	pending := &pendingApproval{
		controlRequestID: requestID,
		requestID:        "claude:" + requestID,
		localThread:      session.localThreadID,
		localTurn:        turn,
		isElicitation:    true,
		form:             form,
		client:           proc.client,
	}
	h.mu.Lock()
	h.pendingApprovals[pending.requestID] = pending
	h.mu.Unlock()
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventRequestOpened, ThreadID: session.localThreadID, TurnID: turn, RequestID: pending.requestID, Payload: elicitation.RequestPayload(input, form, raw)})
}

func (h *Instance) RespondToRequest(_ context.Context, input provider.RespondToRequestInput) error {
	h.mu.Lock()
	pending := h.pendingApprovals[input.RequestID]
	h.mu.Unlock()
	if pending == nil {
		return fmt.Errorf("Claude Code approval request %q is not pending", input.RequestID)
	}
	// Build the reply before claiming the request: an invalid answer must
	// leave the question answerable.
	payload, resolved, err := approvalResponse(pending, input)
	if err != nil {
		return err
	}
	h.mu.Lock()
	if h.pendingApprovals[input.RequestID] != pending {
		h.mu.Unlock()
		return fmt.Errorf("Claude Code approval request %q is not pending", input.RequestID)
	}
	delete(h.pendingApprovals, input.RequestID)
	h.mu.Unlock()
	if err := pending.client.respondControl(pending.controlRequestID, payload); err != nil {
		h.mu.Lock()
		if _, exists := h.pendingApprovals[input.RequestID]; !exists {
			h.pendingApprovals[input.RequestID] = pending
		}
		h.mu.Unlock()
		return err
	}
	answers := input.Answers
	if resolved != provider.ApprovalDecisionAccept {
		answers = nil
	}
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventRequestResolved, ThreadID: pending.localThread, TurnID: pending.localTurn, RequestID: pending.requestID, Payload: provider.RuntimeEventPayload{RequestType: pending.requestType, Decision: resolved, Answers: answers}})
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

// publishTitle shows the session's title once it has one. The CLI streams no
// title; it writes the user's /rename and its own generated title to the
// transcript, so the transcript is read after each result.
func (h *Instance) publishTitle(session *claudeSession) {
	h.mu.Lock()
	sessionID := session.nativeSessionID
	h.mu.Unlock()
	path, err := h.findTranscript(sessionID)
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
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventThreadMetadataUpdate, ThreadID: session.localThreadID, Payload: provider.RuntimeEventPayload{Title: title}})
	}
}
