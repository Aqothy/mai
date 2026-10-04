package codexapp

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

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
		if json.Unmarshal(raw, &notification) == nil && !notification.WillRetry {
			if local, turn, ok := h.resolveIDs(notification.ThreadID, notification.TurnID); ok {
				h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventRuntimeError, ThreadID: local, TurnID: turn, Payload: provider.RuntimeEventPayload{Message: notification.Error.Message}})
			}
		}
	case "warning", "deprecationNotice", "configWarning", "guardianWarning":
		var notification struct {
			ThreadID string `json:"threadId"`
			TurnID   string `json:"turnId"`
			Message  string `json:"message"`
		}
		if json.Unmarshal(raw, &notification) == nil {
			if local, turn, ok := h.resolveIDs(notification.ThreadID, notification.TurnID); ok {
				h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventRuntimeWarning, ThreadID: local, TurnID: turn, Payload: provider.RuntimeEventPayload{Message: notification.Message}})
			}
		}
	case "account/updated", "account/login/completed":
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

func (h *Instance) resolveTurnLocked(session *sessionState, nativeTurn string) string {
	if local := session.nativeToLocalTurn[nativeTurn]; local != "" {
		return local
	}
	local := session.pendingLocalTurn
	if local == "" {
		local = nativeTurn
	}
	session.pendingLocalTurn = ""
	session.nativeToLocalTurn[nativeTurn] = local
	session.localToNativeTurn[local] = nativeTurn
	return local
}

func (h *Instance) emitTurnStarted(nativeThread, nativeTurn string) error {
	h.mu.Lock()
	localThread := h.localByNative[nativeThread]
	if localThread == "" {
		h.mu.Unlock()
		return nil
	}
	session := h.sessionsByLocal[localThread]
	if session == nil {
		h.mu.Unlock()
		return nil
	}
	// A completion (or disconnect) can be delivered before the turn/start
	// caller resumes. An already-observed start must never reactivate it.
	if local := session.nativeToLocalTurn[nativeTurn]; local != "" && session.startedTurns[local] {
		h.mu.Unlock()
		return nil
	}
	if h.transportClosed {
		h.mu.Unlock()
		return fmt.Errorf("Codex app-server connection closed before turn start was acknowledged")
	}
	localTurn := h.resolveTurnLocked(session, nativeTurn)
	session.startedTurns[localTurn] = true
	session.activeNativeTurn = nativeTurn
	h.mu.Unlock()
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventTurnStarted, ThreadID: localThread, TurnID: localTurn})
	return nil
}

func (h *Instance) emitTurnCompleted(nativeThread string, turn appTurn) {
	localThread, localTurn, ok := h.resolveIDs(nativeThread, turn.ID)
	if !ok {
		return
	}
	state, _ := turnState(turn.Status)
	payload := provider.RuntimeEventPayload{TurnState: state, StopReason: turn.Status}
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
	if !known {
		h.mu.Unlock()
		return
	}
	tool.Output += notification.Delta
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
	tool := provider.ToolCall{Action: provider.ToolActionEdit, ProviderKind: "fileChange", Changes: providerFileChanges(notification.Changes)}
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

func (h *Instance) emitTokenUsage(raw json.RawMessage) {
	var notification struct {
		ThreadID, TurnID string
		TokenUsage       struct {
			Total struct {
				TotalTokens int `json:"totalTokens"`
			} `json:"total"`
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
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventThreadTokenUsage, ThreadID: local, TurnID: turn, Payload: provider.RuntimeEventPayload{TokenUsage: &provider.TokenUsage{UsedTokens: notification.TokenUsage.Total.TotalTokens, MaxTokens: max}}})
}

func (h *Instance) handleServerRequest(id json.RawMessage, method string, raw json.RawMessage) {
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
		requestID = "codex:" + normalizeRequestID(id)
	}
	requestType := provider.RuntimeRequestCommandExecution
	if method == "item/fileChange/requestApproval" {
		requestType = provider.RuntimeRequestFileChange
	}
	h.mu.Lock()
	h.pendingApprovals[requestID] = &pendingApproval{id: append(json.RawMessage(nil), id...), rpcRequestID: normalizeRequestID(id), requestID: requestID, localThread: local, localTurn: turn, requestType: requestType}
	h.mu.Unlock()
	detail := strings.TrimSpace(request.Reason)
	if detail == "" {
		detail = strings.TrimSpace(request.Command)
	}
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventRequestOpened, ThreadID: local, TurnID: turn, ItemID: request.ItemID, RequestID: requestID, Payload: provider.RuntimeEventPayload{RequestType: requestType, Detail: detail, Args: append(json.RawMessage(nil), raw...), Options: []provider.ApprovalOption{{ID: "accept", Name: "Allow once", Kind: "allow_once"}, {ID: "acceptForSession", Name: "Allow for session", Kind: "allow_always"}, {ID: "decline", Name: "Decline", Kind: "reject_once"}}}})
}

func (h *Instance) RespondToRequest(_ context.Context, input provider.RespondToRequestInput) error {
	h.mu.Lock()
	pending := h.pendingApprovals[input.RequestID]
	if pending != nil {
		delete(h.pendingApprovals, input.RequestID)
	}
	h.mu.Unlock()
	if pending == nil {
		return fmt.Errorf("Codex approval request %q is not pending", input.RequestID)
	}
	decision := string(input.Decision)
	if input.OptionID != "" {
		decision = input.OptionID
	}
	switch decision {
	case "accept", "acceptForSession", "decline", "cancel":
	default:
		decision = "cancel"
	}
	if err := h.rpc.respond(pending.id, map[string]any{"decision": decision}); err != nil {
		h.mu.Lock()
		if _, exists := h.pendingApprovals[input.RequestID]; !exists {
			h.pendingApprovals[input.RequestID] = pending
		}
		h.mu.Unlock()
		return err
	}
	h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventRequestResolved, ThreadID: pending.localThread, TurnID: pending.localTurn, RequestID: pending.requestID, Payload: provider.RuntimeEventPayload{RequestType: pending.requestType, Decision: provider.ApprovalDecision(decision)}})
	return nil
}

func (h *Instance) cancelPendingApprovals() {
	h.mu.Lock()
	pending := h.pendingApprovals
	h.pendingApprovals = make(map[string]*pendingApproval)
	h.mu.Unlock()
	for _, request := range pending {
		_ = h.rpc.respond(request.id, map[string]any{"decision": "cancel"})
		h.emitEvent(provider.RuntimeEvent{Type: provider.RuntimeEventRequestResolved, ThreadID: request.localThread, TurnID: request.localTurn, RequestID: request.requestID, Payload: provider.RuntimeEventPayload{RequestType: request.requestType, Decision: provider.ApprovalDecisionCancel, Cancelled: true}})
	}
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
