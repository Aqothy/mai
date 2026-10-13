package codexapp

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/Aqothy/maiD/internal/adapters/elicitation"
	"github.com/Aqothy/maiD/internal/provider"
)

func (h *Instance) handleNotification(method string, raw json.RawMessage) {
	switch method {
	case "turn/started":
		var notification struct {
			ThreadID string  `json:"threadId"`
			Turn     appTurn `json:"turn"`
		}
		if json.Unmarshal(raw, &notification) == nil {
			h.emitTurnStarted(notification.ThreadID, notification.Turn.ID)
		}
	case "turn/completed":
		var notification struct {
			ThreadID string  `json:"threadId"`
			Turn     appTurn `json:"turn"`
		}
		if json.Unmarshal(raw, &notification) == nil {
			h.emitTurnCompleted(notification.ThreadID, notification.Turn)
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
			h.emitItem(method, notification.ThreadID, notification.TurnID, notification.Item, notification.StartedAtMs, notification.CompletedAtMs)
		}
	case "item/agentMessage/delta":
		h.emitTextDelta(raw, provider.RuntimeContentAssistantText, "")
	case "item/reasoning/summaryTextDelta":
		h.emitTextDelta(raw, provider.RuntimeContentReasoningText, "summary")
	case "item/reasoning/textDelta":
		h.emitTextDelta(raw, provider.RuntimeContentReasoningText, "content")
	case "item/reasoning/summaryPartAdded":
		// Part boundaries are derived from the index every reasoning delta
		// carries, so this notification adds nothing.
	case "item/commandExecution/outputDelta":
		h.emitCommandOutput(raw)
	case "item/fileChange/patchUpdated":
		h.emitFilePatch(raw)
	case "turn/plan/updated":
		h.emitPlan(raw)
	case "thread/tokenUsage/updated":
		h.emitTokenUsage(raw)
	case "thread/name/updated":
		var notification struct {
			ThreadID   string `json:"threadId"`
			ThreadName string `json:"threadName"`
		}
		if json.Unmarshal(raw, &notification) == nil {
			if local, _, ok := h.resolveIDs(notification.ThreadID, ""); ok {
				h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventThreadMetadataUpdate, ThreadID: local, Payload: provider.RuntimeEventPayload{Title: notification.ThreadName}})
			}
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
		h.emitGoal(notification.ThreadID, &notification.Goal)
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
			h.emitGoal(notification.ThreadID, nil)
		}
	case "serverRequest/resolved":
		h.resolveServerRequest(raw)
	case "thread/closed", "thread/deleted":
		h.handleNativeThreadClosed(raw)
	case "error":
		var notification struct {
			ThreadID  string `json:"threadId"`
			TurnID    string `json:"turnId"`
			WillRetry bool   `json:"willRetry"`
			Error     struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if json.Unmarshal(raw, &notification) != nil {
			return
		}
		switch {
		case notification.WillRetry:
			// An error Codex retries is not fatal to the turn.
			h.emitThreadEvent(notification.ThreadID, notification.TurnID, provider.RuntimeEventRuntimeWarning, notification.Error.Message)
		case notification.TurnID == "":
			h.emitThreadEvent(notification.ThreadID, "", provider.RuntimeEventRuntimeError, notification.Error.Message)
		default:
			// The failed turn/completed that follows carries the same error.
		}
	case "warning", "guardianWarning":
		var notification struct {
			ThreadID *string `json:"threadId"`
			Message  string  `json:"message"`
		}
		if json.Unmarshal(raw, &notification) == nil {
			if notification.ThreadID == nil || !h.emitThreadEvent(*notification.ThreadID, "", provider.RuntimeEventRuntimeWarning, notification.Message) {
				h.logger.Warn("Codex warning", "message", notification.Message)
			}
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
			h.emitThreadEvent(notification.ThreadID, notification.TurnID, provider.RuntimeEventRuntimeWarning, message)
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
			if notification.ThreadID == nil || !h.emitThreadEvent(*notification.ThreadID, "", provider.RuntimeEventRuntimeWarning, message) {
				h.logger.Warn(message)
			}
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
		}()
	case "skills/changed":
		go h.refreshActiveSkills()
	default:
		h.logger.Debug("ignored Codex app-server notification", "method", method)
	}
}

// emitThreadEvent emits a warning or error on the thread bound to a native
// thread, and reports whether one is.
func (h *Instance) emitThreadEvent(nativeThread, nativeTurn string, eventType provider.RuntimeEventType, message string) bool {
	local, turn, ok := h.resolveIDs(nativeThread, nativeTurn)
	if ok && strings.TrimSpace(message) != "" {
		h.emitEvent(provider.RuntimeEvent{Type: eventType, ThreadID: local, TurnID: turn, Payload: provider.RuntimeEventPayload{Message: message}})
	}
	return ok
}

func (h *Instance) resolveIDs(nativeThread, nativeTurn string) (string, string, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	localThread := h.localByNative[nativeThread]
	if localThread == "" {
		return "", "", false
	}
	session := h.sessionsByLocal[localThread]
	if session == nil {
		return "", "", false
	}
	localTurn := ""
	if nativeTurn != "" {
		localTurn = h.resolveTurnLocked(session, nativeTurn)
	}
	return localThread, localTurn, true
}

// resolveTurnLocked names a native turn locally. The first turn Codex
// reports while the user's input awaits one carries it; any other turn is
// Codex's own and keeps its name.
func (h *Instance) resolveTurnLocked(session *sessionState, nativeTurn string) string {
	if local := session.nativeToLocalTurn[nativeTurn]; local != "" {
		return local
	}
	local := nativeTurn
	if session.pending != nil && session.pending.awaits == awaitsCodexTurn {
		local = session.pending.id
		session.pending = nil
	}
	session.nativeToLocalTurn[nativeTurn] = local
	session.localToNativeTurn[local] = nativeTurn
	return local
}

func (h *Instance) emitTurnStarted(nativeThread, nativeTurn string) {
	h.mu.Lock()
	session := h.sessionsByLocal[h.localByNative[nativeThread]]
	if session == nil {
		h.mu.Unlock()
		return
	}
	// The turn/start response may have reported the start already.
	if local := session.nativeToLocalTurn[nativeTurn]; local != "" && session.startedTurns[local] {
		h.mu.Unlock()
		return
	}
	localTurn := h.resolveTurnLocked(session, nativeTurn)
	session.startedTurns[localTurn] = true
	session.activeNativeTurn = nativeTurn
	h.mu.Unlock()
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventTurnStarted, ThreadID: session.localThreadID, TurnID: localTurn})
}

func (h *Instance) emitTurnCompleted(nativeThread string, turn appTurn) {
	localThread, localTurn, ok := h.resolveIDs(nativeThread, turn.ID)
	if !ok {
		return
	}
	state, _ := turnState(turn.Status)
	payload := provider.RuntimeEventPayload{TurnState: state}
	if turn.Error != nil {
		payload.Message = strings.TrimSpace(turn.Error.Message)
		if turn.Error.AdditionalDetails != nil {
			payload.Detail = strings.TrimSpace(*turn.Error.AdditionalDetails)
		}
	}
	h.mu.Lock()
	if session := h.sessionsByLocal[localThread]; session != nil {
		if session.activeNativeTurn == turn.ID {
			session.activeNativeTurn = ""
			session.streamed = make(map[string]streamedItem)
		}
	}
	h.mu.Unlock()
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventTurnCompleted, ThreadID: localThread, TurnID: localTurn, Payload: payload})
}

func (h *Instance) emitItem(method, nativeThread, nativeTurn string, item appItem, startedMs, completedMs int64) {
	// maiD records every client-authored prompt before dispatch. App-server
	// echoes that prompt as a live userMessage item, so publishing it again
	// would append a duplicate user bubble. Replay still converts userMessage
	// items through replayEvents, where no local command message exists.
	if item.Type == "userMessage" {
		return
	}
	localThread, localTurn, ok := h.resolveIDs(nativeThread, nativeTurn)
	if !ok {
		return
	}
	if method == "item/completed" {
		var kind provider.RuntimeContentStreamKind
		var snapshot string
		switch item.Type {
		case "agentMessage":
			kind = provider.RuntimeContentAssistantText
			snapshot = item.Text
		case "reasoning":
			kind = provider.RuntimeContentReasoningText
			snapshot = reasoningText(item)
		}
		if kind != "" {
			h.mu.Lock()
			streamed := ""
			if session := h.sessionsByLocal[localThread]; session != nil {
				streamed = session.streamed[item.ID].text
				delete(session.streamed, item.ID)
			}
			h.mu.Unlock()
			if strings.HasPrefix(snapshot, streamed) && len(snapshot) > len(streamed) {
				h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventContentDelta, ThreadID: localThread, TurnID: localTurn, ItemID: item.ID, Payload: provider.RuntimeEventPayload{StreamKind: kind, Delta: snapshot[len(streamed):]}})
			}
		}
	}
	eventType := provider.RuntimeEventItemStarted
	at := time.Now()
	if method == "item/completed" {
		eventType = provider.RuntimeEventItemCompleted
		if completedMs > 0 {
			at = time.UnixMilli(completedMs)
		}
	} else if startedMs > 0 {
		at = time.UnixMilli(startedMs)
	}
	event, ok := runtimeEventFromItem(localThread, localTurn, item, eventType, at)
	if !ok {
		return
	}
	if event.Payload.ToolCall != nil {
		h.mu.Lock()
		if session := h.sessionsByLocal[localThread]; session != nil {
			session.items[item.ID] = *event.Payload.ToolCall
		}
		h.mu.Unlock()
	}
	h.emitEvent(event)
}

// emitTextDelta forwards a live text delta. partKind is "summary" or
// "content" for reasoning deltas (naming which index on the notification
// identifies the part) and "" for assistant text. The completed reasoning
// item joins its parts as paragraphs (reasoningText), so a part change
// inserts the same break live; that keeps what the user watched, the tail
// emitted on completion, and the replayed thread identical.
func (h *Instance) emitTextDelta(raw json.RawMessage, kind provider.RuntimeContentStreamKind, partKind string) {
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
	local, turn, ok := h.resolveIDs(notification.ThreadID, notification.TurnID)
	if !ok {
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
	if session := h.sessionsByLocal[local]; session != nil {
		item := session.streamed[notification.ItemID]
		if part != "" && item.part != "" && item.part != part {
			delta = paragraphBreak(item.text) + delta
		}
		session.streamed[notification.ItemID] = streamedItem{text: item.text + delta, part: part}
	}
	h.mu.Unlock()
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventContentDelta, ThreadID: local, TurnID: turn, ItemID: notification.ItemID, Payload: provider.RuntimeEventPayload{StreamKind: kind, Delta: delta}})
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

func (h *Instance) emitCommandOutput(raw json.RawMessage) {
	var notification struct{ ThreadID, TurnID, ItemID, Delta string }
	if json.Unmarshal(raw, &notification) != nil || notification.Delta == "" {
		return
	}
	local, turn, ok := h.resolveIDs(notification.ThreadID, notification.TurnID)
	if !ok {
		return
	}
	h.mu.Lock()
	session := h.sessionsByLocal[local]
	if session == nil {
		h.mu.Unlock()
		return
	}
	// Output belongs to the snapshot recorded at item/started. Without one
	// there is nothing to merge into, and emitting a blank tool call would show
	// an empty row until the next full snapshot.
	tool, known := session.items[notification.ItemID]
	// Every update re-emits the whole snapshot, so output past the limit is
	// dropped; item/completed carries the bounded aggregate anyway.
	if !known || len(tool.Output) >= appToolOutputLimit {
		h.mu.Unlock()
		return
	}
	tool.Output = boundedAppOutput(tool.Output + notification.Delta)
	session.items[notification.ItemID] = tool
	h.mu.Unlock()
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventItemUpdated, ThreadID: local, TurnID: turn, ItemID: notification.ItemID, Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindCommandExecution, ToolCall: &tool}})
}

func (h *Instance) emitFilePatch(raw json.RawMessage) {
	var notification struct {
		ThreadID, TurnID, ItemID string
		Changes                  []appFileUpdateChange `json:"changes"`
	}
	if json.Unmarshal(raw, &notification) != nil {
		return
	}
	local, turn, ok := h.resolveIDs(notification.ThreadID, notification.TurnID)
	if !ok {
		return
	}
	tool := provider.ToolCall{ProviderKind: "fileChange", Changes: providerFileChanges(notification.Changes)}
	h.mu.Lock()
	session := h.sessionsByLocal[local]
	if session == nil {
		h.mu.Unlock()
		return
	}
	session.items[notification.ItemID] = tool
	h.mu.Unlock()
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventItemUpdated, ThreadID: local, TurnID: turn, ItemID: notification.ItemID, Payload: provider.RuntimeEventPayload{ItemType: provider.ItemKindFileChange, ToolCall: &tool}})
}

func (h *Instance) emitPlan(raw json.RawMessage) {
	var notification struct {
		ThreadID, TurnID string
		Plan             []struct{ Step, Status string } `json:"plan"`
	}
	if json.Unmarshal(raw, &notification) != nil {
		return
	}
	local, turn, ok := h.resolveIDs(notification.ThreadID, notification.TurnID)
	if !ok {
		return
	}
	steps := make([]appPlanStep, 0, len(notification.Plan))
	for _, step := range notification.Plan {
		steps = append(steps, appPlanStep{Step: step.Step, Status: step.Status})
	}
	entries := planEntriesFromApp(steps)
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventTurnPlanUpdated, ThreadID: local, TurnID: turn, Payload: provider.RuntimeEventPayload{PlanEntries: entries}})
}

// emitGoal reports a native thread's goal, or that it has none.
func (h *Instance) emitGoal(nativeThread string, goal *appGoal) {
	local, _, ok := h.resolveIDs(nativeThread, "")
	if !ok {
		return
	}
	if event, ok := goalEvent(local, goal); ok {
		h.emitEvent(event)
	}
}

func (h *Instance) emitTokenUsage(raw json.RawMessage) {
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
	local, turn, ok := h.resolveIDs(notification.ThreadID, notification.TurnID)
	if !ok {
		return
	}
	max := 0
	if notification.TokenUsage.ModelContextWindow != nil {
		max = *notification.TokenUsage.ModelContextWindow
	}
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventThreadTokenUsage, ThreadID: local, TurnID: turn, Payload: provider.RuntimeEventPayload{TokenUsage: &provider.TokenUsage{UsedTokens: notification.TokenUsage.Last.TotalTokens, MaxTokens: max}}})
}

func (h *Instance) handleServerRequest(id json.RawMessage, method string, raw json.RawMessage) {
	switch method {
	case "mcpServer/elicitation/request":
		h.openElicitation(id, raw)
		return
	case "item/permissions/requestApproval":
		h.openPermissionsRequest(id, raw)
		return
	}
	if method != "item/commandExecution/requestApproval" && method != "item/fileChange/requestApproval" {
		_ = h.rpc.respondError(id, -32601, "method not supported by maiD")
		return
	}
	var request struct {
		ThreadID   string `json:"threadId"`
		TurnID     string `json:"turnId"`
		ItemID     string `json:"itemId"`
		ApprovalID string `json:"approvalId"`
		Reason     string `json:"reason"`
		Command    string `json:"command"`
		Cwd        string `json:"cwd"`
		// The rules Codex proposes to approve similar requests from now on.
		ProposedExecpolicyAmendment     []string `json:"proposedExecpolicyAmendment"`
		ProposedNetworkPolicyAmendments []struct {
			Host   string `json:"host"`
			Action string `json:"action"`
		} `json:"proposedNetworkPolicyAmendments"`
	}
	if err := json.Unmarshal(raw, &request); err != nil {
		_ = h.rpc.respondError(id, -32602, "invalid approval request")
		return
	}
	local, turn, ok := h.resolveIDs(request.ThreadID, request.TurnID)
	if !ok {
		_ = h.rpc.respond(id, map[string]any{"decision": "cancel"})
		return
	}
	requestID := request.ApprovalID
	if requestID == "" {
		requestID = h.requestID(id)
	}
	requestType := provider.RuntimeRequestCommandExecution
	if method == "item/fileChange/requestApproval" {
		requestType = provider.RuntimeRequestFileChange
	}
	pending := &pendingApproval{id: append(json.RawMessage(nil), id...), rpcRequestID: normalizeRequestID(id), requestID: requestID, localThread: local, localTurn: turn, requestType: requestType, kind: pendingApprovalRequest, amendments: make(map[string]amendment)}
	options := []provider.ApprovalOption{{ID: "accept", Name: "Allow once", Kind: "allow_once"}, {ID: "acceptForSession", Name: "Allow for session", Kind: "allow_always"}}
	// Like the Codex TUI, offer each proposed rule as its own option.
	if prefix := strings.Join(request.ProposedExecpolicyAmendment, " "); prefix != "" && !strings.ContainsAny(prefix, "\r\n") {
		pending.amendments["acceptWithExecpolicyAmendment"] = amendment{
			reply:    map[string]any{"acceptWithExecpolicyAmendment": map[string]any{"execpolicy_amendment": request.ProposedExecpolicyAmendment}},
			decision: provider.ApprovalDecisionAcceptForSession,
		}
		options = append(options, provider.ApprovalOption{ID: "acceptWithExecpolicyAmendment", Name: fmt.Sprintf("Always allow commands that start with `%s`", prefix), Kind: "allow_always"})
	}
	for index, proposed := range request.ProposedNetworkPolicyAmendments {
		optionID := fmt.Sprintf("networkPolicyAmendment:%d", index)
		option := provider.ApprovalOption{ID: optionID, Name: "Always allow " + proposed.Host, Kind: "allow_always"}
		decision := provider.ApprovalDecisionAcceptForSession
		if proposed.Action == "deny" {
			option = provider.ApprovalOption{ID: optionID, Name: "Always block " + proposed.Host, Kind: "reject_always"}
			decision = provider.ApprovalDecisionDecline
		}
		pending.amendments[optionID] = amendment{
			reply:    map[string]any{"applyNetworkPolicyAmendment": map[string]any{"network_policy_amendment": proposed}},
			decision: decision,
		}
		options = append(options, option)
	}
	options = append(options, provider.ApprovalOption{ID: "decline", Name: "Decline", Kind: "reject_once"})
	h.mu.Lock()
	h.pendingApprovals[requestID] = pending
	h.mu.Unlock()
	detail := strings.TrimSpace(request.Reason)
	if detail == "" {
		detail = strings.TrimSpace(request.Command)
	}
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventRequestOpened, ThreadID: local, TurnID: turn, ItemID: request.ItemID, RequestID: requestID, Payload: provider.RuntimeEventPayload{RequestType: requestType, Detail: detail, Args: append(json.RawMessage(nil), raw...), Options: options}})
}

// openElicitation surfaces an MCP server's elicitation as a user-input request.
// Only the stable form and URL modes are shown; others are cancelled.
func (h *Instance) openElicitation(id json.RawMessage, raw json.RawMessage) {
	var request struct {
		ThreadID        string          `json:"threadId"`
		TurnID          string          `json:"turnId"`
		Mode            string          `json:"mode"`
		Message         string          `json:"message"`
		URL             string          `json:"url"`
		RequestedSchema json.RawMessage `json:"requestedSchema"`
	}
	if err := json.Unmarshal(raw, &request); err != nil {
		_ = h.rpc.respondError(id, -32602, "invalid elicitation request")
		return
	}
	input, form, err := elicitation.Parse(request.Message, request.Mode, request.URL, request.RequestedSchema)
	local, turn, ok := h.resolveIDs(request.ThreadID, request.TurnID)
	if err != nil || !ok {
		// The user never saw it, so it was neither accepted nor declined.
		_ = h.rpc.respond(id, map[string]any{"action": elicitation.ActionCancel, "content": nil})
		return
	}
	pending := &pendingApproval{id: append(json.RawMessage(nil), id...), rpcRequestID: normalizeRequestID(id), requestID: h.requestID(id), localThread: local, localTurn: turn, kind: pendingElicitation, form: form}
	h.mu.Lock()
	h.pendingApprovals[pending.requestID] = pending
	h.mu.Unlock()
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventRequestOpened, ThreadID: local, TurnID: turn, RequestID: pending.requestID, Payload: provider.RuntimeEventPayload{UserInput: &input}})
}

// openPermissionsRequest surfaces a request for more sandbox access as a
// permission request that can be granted for the turn or the session.
func (h *Instance) openPermissionsRequest(id json.RawMessage, raw json.RawMessage) {
	var request permissionsRequest
	var requested requestedPermissions
	if json.Unmarshal(raw, &request) != nil || json.Unmarshal(request.Permissions, &requested) != nil {
		_ = h.rpc.respondError(id, -32602, "invalid permissions request")
		return
	}
	local, turn, ok := h.resolveIDs(request.ThreadID, request.TurnID)
	if !ok {
		_ = h.rpc.respond(id, permissionsReply(request.Permissions, provider.ApprovalDecisionCancel))
		return
	}
	pending := &pendingApproval{
		id: append(json.RawMessage(nil), id...), rpcRequestID: normalizeRequestID(id), requestID: h.requestID(id),
		localThread: local, localTurn: turn, requestType: requested.requestType(),
		kind: pendingPermissions, permissions: append(json.RawMessage(nil), request.Permissions...),
	}
	h.mu.Lock()
	h.pendingApprovals[pending.requestID] = pending
	h.mu.Unlock()
	detail := requested.summary()
	if request.Reason != nil && strings.TrimSpace(*request.Reason) != "" {
		detail = strings.TrimSpace(*request.Reason)
	}
	options := []provider.ApprovalOption{
		{ID: string(provider.ApprovalDecisionAccept), Name: "Allow for this turn", Kind: "allow_once"},
		{ID: string(provider.ApprovalDecisionAcceptForSession), Name: "Allow for this session", Kind: "allow_always"},
		{ID: string(provider.ApprovalDecisionDecline), Name: "Decline", Kind: "reject_once"},
	}
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventRequestOpened, ThreadID: local, TurnID: turn, ItemID: request.ItemID, RequestID: pending.requestID, Payload: provider.RuntimeEventPayload{RequestType: pending.requestType, Detail: detail, Args: append(json.RawMessage(nil), raw...), Options: options}})
}

func (h *Instance) RespondToRequest(_ context.Context, input provider.RespondToRequestInput) error {
	h.mu.Lock()
	pending := h.pendingApprovals[input.RequestID]
	h.mu.Unlock()
	if pending == nil {
		return fmt.Errorf("Codex approval request %q is not pending", input.RequestID)
	}
	// Build the reply before claiming the request: an invalid answer must
	// leave the question answerable.
	reply, decision, err := pending.reply(input)
	if err != nil {
		return err
	}
	h.mu.Lock()
	if h.pendingApprovals[input.RequestID] != pending {
		h.mu.Unlock()
		return fmt.Errorf("Codex approval request %q is not pending", input.RequestID)
	}
	delete(h.pendingApprovals, input.RequestID)
	h.mu.Unlock()
	if err := h.rpc.respond(pending.id, reply); err != nil {
		h.mu.Lock()
		if _, exists := h.pendingApprovals[input.RequestID]; !exists {
			h.pendingApprovals[input.RequestID] = pending
		}
		h.mu.Unlock()
		return err
	}
	answers := input.Answers
	if decision != provider.ApprovalDecisionAccept {
		answers = nil
	}
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventRequestResolved, ThreadID: pending.localThread, TurnID: pending.localTurn, RequestID: pending.requestID, Payload: provider.RuntimeEventPayload{RequestType: pending.requestType, Decision: decision, Answers: answers}})
	return nil
}

func (h *Instance) cancelPendingApprovals() {
	h.mu.Lock()
	pending := h.pendingApprovals
	h.pendingApprovals = make(map[string]*pendingApproval)
	h.mu.Unlock()
	for _, request := range pending {
		_ = h.rpc.respond(request.id, request.cancelReply())
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventRequestResolved, ThreadID: request.localThread, TurnID: request.localTurn, RequestID: request.requestID, Payload: provider.RuntimeEventPayload{RequestType: request.requestType, Decision: provider.ApprovalDecisionCancel, Cancelled: true}})
	}
}

// requestID names a server request for clients. JSON-RPC ids restart with
// every app-server process, so the instance's nonce keeps a new request from
// taking an old one's name.
func (h *Instance) requestID(id json.RawMessage) string {
	return "codex:" + h.requestNonce + ":" + normalizeRequestID(id)
}

func normalizeRequestID(id json.RawMessage) string {
	return strings.Trim(string(id), "\"")
}

func (h *Instance) resolveServerRequest(raw json.RawMessage) {
	var notification struct {
		RequestID json.RawMessage `json:"requestId"`
	}
	if json.Unmarshal(raw, &notification) != nil || len(notification.RequestID) == 0 {
		return
	}
	rpcRequestID := normalizeRequestID(notification.RequestID)
	var resolved *pendingApproval
	h.mu.Lock()
	for requestID, pending := range h.pendingApprovals {
		if pending.rpcRequestID == rpcRequestID {
			resolved = pending
			delete(h.pendingApprovals, requestID)
			break
		}
	}
	h.mu.Unlock()
	if resolved != nil {
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventRequestResolved, ThreadID: resolved.localThread, TurnID: resolved.localTurn, RequestID: resolved.requestID, Payload: provider.RuntimeEventPayload{RequestType: resolved.requestType, Decision: provider.ApprovalDecisionCancel, Cancelled: true}})
	}
}

func (h *Instance) handleNativeThreadClosed(raw json.RawMessage) {
	var notification struct {
		ThreadID string `json:"threadId"`
	}
	if json.Unmarshal(raw, &notification) != nil || notification.ThreadID == "" {
		return
	}
	var resolved []*pendingApproval
	h.mu.Lock()
	local := h.localByNative[notification.ThreadID]
	if local != "" {
		delete(h.localByNative, notification.ThreadID)
		delete(h.sessionsByLocal, local)
		for requestID, pending := range h.pendingApprovals {
			if pending.localThread == local {
				resolved = append(resolved, pending)
				delete(h.pendingApprovals, requestID)
			}
		}
	}
	h.mu.Unlock()
	for _, pending := range resolved {
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventRequestResolved, ThreadID: pending.localThread, TurnID: pending.localTurn, RequestID: pending.requestID, Payload: provider.RuntimeEventPayload{RequestType: pending.requestType, Decision: provider.ApprovalDecisionCancel, Cancelled: true}})
	}
}
