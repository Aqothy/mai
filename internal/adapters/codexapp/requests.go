package codexapp

import (
	"context"
	"encoding/json"
	"fmt"
	"slices"
	"strings"

	"github.com/Aqothy/maiD/internal/adapters/elicitation"
	"github.com/Aqothy/maiD/internal/provider"
)

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
	requestID := request.ApprovalID
	if requestID == "" {
		requestID = h.requestID(id)
	}
	pending := &pendingApproval{id: append(json.RawMessage(nil), id...), rpcRequestID: normalizeRequestID(id), requestID: requestID, thread: request.ThreadID, kind: pendingApprovalRequest, amendments: make(map[string]map[string]any)}
	detail := strings.TrimSpace(request.Reason)
	if detail == "" {
		detail = strings.TrimSpace(request.Command)
	}
	asked := provider.Request{Message: detail, Actions: []provider.RequestAction{
		{ID: "accept", Label: "Allow once", Decision: provider.ApprovalDecisionAccept},
		{ID: "acceptForSession", Label: "Allow for session", Decision: provider.ApprovalDecisionAcceptForSession},
	}}
	// Like the Codex TUI, offer each proposed rule as its own action.
	if prefix := strings.Join(request.ProposedExecpolicyAmendment, " "); prefix != "" && !strings.ContainsAny(prefix, "\r\n") {
		pending.amendments["acceptWithExecpolicyAmendment"] = map[string]any{"decision": map[string]any{"acceptWithExecpolicyAmendment": map[string]any{"execpolicy_amendment": request.ProposedExecpolicyAmendment}}}
		asked.Actions = append(asked.Actions, provider.RequestAction{ID: "acceptWithExecpolicyAmendment", Label: fmt.Sprintf("Always allow commands that start with `%s`", prefix), Decision: provider.ApprovalDecisionAcceptForSession})
	}
	for index, proposed := range request.ProposedNetworkPolicyAmendments {
		action := provider.RequestAction{ID: fmt.Sprintf("networkPolicyAmendment:%d", index), Label: "Always allow " + proposed.Host, Decision: provider.ApprovalDecisionAcceptForSession}
		if proposed.Action == "deny" {
			action.Label, action.Decision = "Always block "+proposed.Host, provider.ApprovalDecisionDecline
		}
		pending.amendments[action.ID] = map[string]any{"decision": map[string]any{"applyNetworkPolicyAmendment": map[string]any{"network_policy_amendment": proposed}}}
		asked.Actions = append(asked.Actions, action)
	}
	asked.Actions = append(asked.Actions, provider.RequestAction{ID: "decline", Label: "Decline", Decision: provider.ApprovalDecisionDecline})
	asked.Details = append(json.RawMessage(nil), raw...)
	h.mu.Lock()
	h.pendingApprovals[requestID] = pending
	h.mu.Unlock()
	h.emit(request.ThreadID, provider.RequestOpened{Request: requestID, Turn: request.TurnID, Entry: request.ItemID, Ask: asked})
}

// openElicitation surfaces an MCP server's elicitation as questions, or as a
// permission request when it only asks yes or no. Only the MCP form and URL
// modes are shown; Codex's own modes are cancelled.
func (h *Instance) openElicitation(id json.RawMessage, raw json.RawMessage) {
	var request struct {
		ThreadID        string          `json:"threadId"`
		TurnID          string          `json:"turnId"`
		Mode            string          `json:"mode"`
		Message         string          `json:"message"`
		URL             string          `json:"url"`
		RequestedSchema json.RawMessage `json:"requestedSchema"`
		Meta            struct {
			Persist json.RawMessage `json:"persist"`
		} `json:"_meta"`
	}
	if err := json.Unmarshal(raw, &request); err != nil {
		_ = h.rpc.respondError(id, -32602, "invalid elicitation request")
		return
	}
	asked, form, err := elicitation.Parse(request.Message, request.Mode, request.URL, request.RequestedSchema, rememberActions(request.Meta.Persist)...)
	if err != nil {
		// The user never saw it, so it was neither accepted nor declined.
		_ = h.rpc.respond(id, map[string]any{"action": elicitation.ActionCancel, "content": nil})
		return
	}
	pending := &pendingApproval{id: append(json.RawMessage(nil), id...), rpcRequestID: normalizeRequestID(id), requestID: h.requestID(id), thread: request.ThreadID, kind: pendingElicitation, form: form}
	h.mu.Lock()
	h.pendingApprovals[pending.requestID] = pending
	h.mu.Unlock()
	if form.Confirms() {
		// What it confirms, an MCP tool call's server, tool and arguments
		// above all, is only in the raw request.
		asked.Details = append(json.RawMessage(nil), raw...)
	}
	h.emit(request.ThreadID, provider.RequestOpened{Request: pending.requestID, Turn: request.TurnID, Ask: asked})
}

// rememberActionPrefix starts the ID of an action that keeps allowing what
// an elicitation confirms; the rest is Codex's persist mode.
const rememberActionPrefix = "persist:"

// rememberActions are the ways Codex offers to keep allowing what an
// elicitation confirms, MCP tool calls above all: _meta.persist names
// "session", "always" or both, and the chosen one goes back as the
// response's _meta.persist (codex-rs/protocol/src/mcp_approval_meta.rs,
// read by parse_mcp_tool_approval_elicitation_response). They apply only to
// a form that asks for nothing.
func rememberActions(persist json.RawMessage) []provider.RequestAction {
	var modes []string
	var mode string
	if json.Unmarshal(persist, &mode) == nil {
		modes = []string{mode}
	} else {
		_ = json.Unmarshal(persist, &modes)
	}
	var actions []provider.RequestAction
	for _, offer := range []struct{ mode, label string }{{"session", "Allow for this session"}, {"always", "Always allow"}} {
		if slices.Contains(modes, offer.mode) {
			actions = append(actions, provider.RequestAction{ID: rememberActionPrefix + offer.mode, Label: offer.label, Decision: provider.ApprovalDecisionAcceptForSession})
		}
	}
	return actions
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
	pending := &pendingApproval{
		id: append(json.RawMessage(nil), id...), rpcRequestID: normalizeRequestID(id), requestID: h.requestID(id),
		thread: request.ThreadID, kind: pendingPermissions, permissions: append(json.RawMessage(nil), request.Permissions...),
	}
	h.mu.Lock()
	h.pendingApprovals[pending.requestID] = pending
	h.mu.Unlock()
	detail := requested.summary()
	if request.Reason != nil && strings.TrimSpace(*request.Reason) != "" {
		detail = strings.TrimSpace(*request.Reason)
	}
	asked := provider.Request{Message: detail, Actions: []provider.RequestAction{
		{ID: "turn", Label: "Allow for this turn", Decision: provider.ApprovalDecisionAccept},
		{ID: "session", Label: "Allow for this session", Decision: provider.ApprovalDecisionAcceptForSession},
		{ID: "decline", Label: "Decline", Decision: provider.ApprovalDecisionDecline},
	}, Details: append(json.RawMessage(nil), raw...)}
	h.emit(request.ThreadID, provider.RequestOpened{Request: pending.requestID, Turn: request.TurnID, Entry: request.ItemID, Ask: asked})
}

func (h *Instance) Respond(_ context.Context, thread, requestID string, answer provider.RequestAnswer) error {
	h.mu.Lock()
	pending := h.pendingApprovals[requestID]
	h.mu.Unlock()
	if pending == nil || pending.thread != thread {
		return fmt.Errorf("Codex request %q is not pending", requestID)
	}
	// Build the reply before claiming the request: an invalid answer must
	// leave the question answerable.
	reply, err := pending.reply(answer)
	if err != nil {
		return err
	}
	h.mu.Lock()
	if h.pendingApprovals[requestID] != pending {
		h.mu.Unlock()
		return fmt.Errorf("Codex request %q is not pending", requestID)
	}
	delete(h.pendingApprovals, requestID)
	h.mu.Unlock()
	if err := h.rpc.respond(pending.id, reply); err != nil {
		h.mu.Lock()
		if _, exists := h.pendingApprovals[requestID]; !exists {
			h.pendingApprovals[requestID] = pending
		}
		h.mu.Unlock()
		return err
	}
	var answers map[string][]string
	if answer.Action.Submit {
		answers = answer.Answers
	}
	h.emit(thread, provider.RequestResolved{Request: requestID, Action: answer.Action.ID, Answers: answers})
	return nil
}

// cancelPendingApprovals ends requests unanswered: a thread's, or with no
// thread every one.
func (h *Instance) cancelPendingApprovals(thread string) {
	h.mu.Lock()
	var cancelled []*pendingApproval
	for id, pending := range h.pendingApprovals {
		if thread == "" || pending.thread == thread {
			cancelled = append(cancelled, pending)
			delete(h.pendingApprovals, id)
		}
	}
	h.mu.Unlock()
	for _, request := range cancelled {
		_ = h.rpc.respond(request.id, request.cancelReply())
		h.emit(request.thread, provider.RequestResolved{Request: request.requestID})
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
		h.emit(resolved.thread, provider.RequestResolved{Request: resolved.requestID})
	}
}

// threadClosed: app-server closed or deleted a thread; its session ends.
func (h *Instance) threadClosed(raw json.RawMessage) {
	var notification struct {
		ThreadID string `json:"threadId"`
	}
	if json.Unmarshal(raw, &notification) != nil || notification.ThreadID == "" {
		return
	}
	h.mu.Lock()
	session := h.sessions[notification.ThreadID]
	loaded := session != nil && session.loaded
	if session != nil {
		session.loaded = false
	}
	h.mu.Unlock()
	h.cancelPendingApprovals(notification.ThreadID)
	if loaded {
		h.emit(notification.ThreadID, provider.SessionClosed{})
	}
}
