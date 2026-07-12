// Permission handling for ACP session/request_permission: policy decisions,
// pending client approvals, and provider-neutral request events.
package acp

import (
	"context"
	"fmt"
	"time"

	"github.com/Aqothy/go-acp/schema"
	"github.com/Aqothy/maiD/internal/provider"
)

func (h *Instance) RespondToRequest(_ context.Context, input provider.RespondToRequestInput) error {
	if input.ThreadID == "" || input.RequestID == "" {
		return fmt.Errorf("provider approval response requires threadId and requestId")
	}
	if input.Decision == "" {
		input.Decision = provider.ApprovalDecisionCancel
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	var pending *pendingPermission
	if session := h.sessionForThreadLocked(input.ThreadID); session != nil {
		pending = session.pendingPermissions[input.RequestID]
	}
	if pending == nil {
		return fmt.Errorf("unknown pending approval request %s", input.RequestID)
	}
	if input.OptionID != "" && !hasPermissionOption(pending.options, input.OptionID) {
		return fmt.Errorf("approval option %q was not offered for request %s", input.OptionID, input.RequestID)
	}
	select {
	case pending.ch <- approvalResponse{decision: input.Decision, optionID: input.OptionID}:
		return nil
	default:
		return fmt.Errorf("approval request %q is already resolved", input.RequestID)
	}
}

func (h *Instance) permissionRequestID(sessionID string, threadID string, toolCallID string) string {
	h.mu.Lock()
	scopedToolCallID := h.scopedProviderItemIDLocked(sessionID, toolCallID)
	h.mu.Unlock()
	return permissionRequestID(threadID, scopedToolCallID)
}

// requestPermission answers the agent's session/request_permission. The
// handler ctx is cancelled when the agent cancels its own request via
// $/cancel_request (go-acp relays it into the running handler), which resolves
// the wait with the cancelled outcome — same as an interrupt-driven cancel.
func (h *Instance) requestPermission(ctx context.Context, req schema.RequestPermissionRequest) (schema.RequestPermissionResponse, error) {
	state := h.permissionRequestState(string(req.SessionID))
	requestID := h.permissionRequestID(string(req.SessionID), state.threadID, string(req.ToolCall.ToolCallID))
	if state.cancelled || ctx.Err() != nil {
		resp := cancelledPermissionResponse()
		h.recordPermissionRequest(req, state, requestID)
		h.recordPermissionResolved(req, state, requestID, resp)
		return resp, nil
	}

	if resp, ok := automaticPermissionResponse(req, state.policy); ok {
		h.recordPermissionRequest(req, state, requestID)
		h.recordPermissionResolved(req, state, requestID, resp)
		return resp, nil
	}

	permissionCtx, cancelPermission, pending := h.beginPermissionRequest(ctx, string(req.SessionID), requestID, req.Options)
	defer cancelPermission()
	defer h.endPermissionRequest(string(req.SessionID), requestID, pending)
	h.recordPermissionRequest(req, state, requestID)
	var response approvalResponse
	select {
	case response = <-pending.ch:
		h.mu.Lock()
		settled := pending.settled
		h.mu.Unlock()
		if settled {
			response = approvalResponse{decision: provider.ApprovalDecisionCancel}
		}
	case <-permissionCtx.Done():
		response.decision = provider.ApprovalDecisionCancel
	}
	resp := permissionResponseForApproval(req.Options, response)
	h.recordPermissionResolved(req, state, requestID, resp)
	return resp, nil
}

// pendingPermission is an in-flight session/request_permission awaiting the
// client's answer. It keeps the agent's offered options so RespondToRequest
// can validate an explicit optionId before it is relayed, and its own cancel
// func so cancel registrations stay owned by the request that created them
// (a duplicate request for the same key must not be unregistered by the
// first request's cleanup).
type pendingPermission struct {
	ch      chan approvalResponse
	options []schema.PermissionOption
	settled bool
	cancel  context.CancelFunc
}

// approvalResponse is the client's answer to a permission request: an exact
// option selection when the client picked one, otherwise just the coarse
// decision to be mapped onto the agent's options by kind.
type approvalResponse struct {
	decision provider.ApprovalDecision
	optionID string
}

type permissionState struct {
	policy    provider.ApprovalPolicy
	threadID  string
	turnID    string
	cancelled bool
}

func (h *Instance) permissionRequestState(sessionID string) permissionState {
	h.mu.Lock()
	defer h.mu.Unlock()
	collector := h.updateCollectorLocked(sessionID)
	if collector == nil {
		state := permissionState{policy: provider.ApprovalPolicyDeny}
		if session := h.sessionLocked(sessionID); session != nil {
			state.threadID = session.threadID
		}
		return state
	}
	return permissionState{policy: collector.approvalPolicy, threadID: collector.threadID, turnID: collector.turnID, cancelled: collector.cancelled}
}

func (h *Instance) beginPermissionRequest(ctx context.Context, sessionID string, requestID string, options []schema.PermissionOption) (context.Context, context.CancelFunc, *pendingPermission) {
	permissionCtx, cancel := context.WithCancel(ctx)
	pending := &pendingPermission{ch: make(chan approvalResponse, 1), options: options, cancel: cancel}
	h.mu.Lock()
	session := h.sessionLocked(sessionID)
	collector := h.updateCollectorLocked(sessionID)
	if session == nil || collector == nil || collector.cancelled {
		h.mu.Unlock()
		cancel()
		return permissionCtx, cancel, pending
	}
	if _, settled := collector.settledPermissionKeys[requestID]; settled {
		h.mu.Unlock()
		cancel()
		return permissionCtx, cancel, pending
	}
	session.pendingPermissions[requestID] = pending
	if collector.pendingPermissionCancels == nil {
		collector.pendingPermissionCancels = make(map[string]*pendingPermission)
	}
	collector.pendingPermissionCancels[requestID] = pending
	h.mu.Unlock()
	return permissionCtx, cancel, pending
}

func (h *Instance) markPermissionToolSettled(sessionID string, threadID string, toolCallID string) context.CancelFunc {
	requestID := permissionRequestID(threadID, toolCallID)
	h.mu.Lock()
	defer h.mu.Unlock()
	collector := h.updateCollectorLocked(sessionID)
	if collector == nil {
		return nil
	}
	if collector.settledPermissionKeys == nil {
		collector.settledPermissionKeys = make(map[string]struct{})
	}
	collector.settledPermissionKeys[requestID] = struct{}{}
	if session := h.sessionLocked(sessionID); session != nil {
		if pending := session.pendingPermissions[requestID]; pending != nil {
			pending.settled = true
			delete(session.pendingPermissions, requestID)
		}
	}
	if registered := collector.pendingPermissionCancels[requestID]; registered != nil {
		return registered.cancel
	}
	return nil
}

// clearSettledPermissionKeyLocked re-arms permission requests for a tool-call
// id: a fresh tool_call reusing a settled id (retry-after-decline flows)
// starts a new approval cycle, so the settled marker that auto-cancels
// requests for that id must be dropped. h.mu must be held.
func (h *Instance) clearSettledPermissionKeyLocked(sessionID string, threadID string, toolCallID string) {
	collector := h.updateCollectorLocked(sessionID)
	if collector == nil || collector.settledPermissionKeys == nil {
		return
	}
	delete(collector.settledPermissionKeys, permissionRequestID(threadID, toolCallID))
}

func (h *Instance) endPermissionRequest(sessionID string, requestID string, pending *pendingPermission) {
	h.mu.Lock()
	if session := h.sessionLocked(sessionID); session != nil && session.pendingPermissions[requestID] == pending {
		delete(session.pendingPermissions, requestID)
	}
	collector := h.updateCollectorLocked(sessionID)
	// Like the pendingPermissions delete above, the cancel registration is
	// only removed by the request that owns it: a duplicate concurrent request
	// for the same id overwrites the registration, and the first request's
	// cleanup must not unregister the second's cancel.
	if collector != nil && collector.pendingPermissionCancels[requestID] == pending {
		delete(collector.pendingPermissionCancels, requestID)
	}
	h.mu.Unlock()
}

func (h *Instance) recordPermissionRequest(req schema.RequestPermissionRequest, state permissionState, requestID string) {
	update := provider.RuntimeEvent{
		EventID:   provider.RuntimeEventID(newID()),
		Provider:  DriverKind,
		ThreadID:  state.threadID,
		TurnID:    state.turnID,
		Type:      provider.RuntimeEventRequestOpened,
		RequestID: requestID,
		CreatedAt: time.Now(),
		Payload: provider.RuntimeEventPayload{
			RequestType: permissionRequestType(req.ToolCall),
			Detail:      toolCallTitle(req.ToolCall),
			Args:        marshalRaw(req.ToolCall),
			Options:     permissionOptionsFromACP(req.Options),
		},
	}
	h.emitRuntimeEventForSession(string(req.SessionID), update)
}

func (h *Instance) recordPermissionResolved(req schema.RequestPermissionRequest, state permissionState, requestID string, resp schema.RequestPermissionResponse) {
	decision, optionID := permissionDecisionFromResponse(req.Options, resp)
	update := provider.RuntimeEvent{
		EventID:   provider.RuntimeEventID(newID()),
		Provider:  DriverKind,
		ThreadID:  state.threadID,
		TurnID:    state.turnID,
		Type:      provider.RuntimeEventRequestResolved,
		RequestID: requestID,
		CreatedAt: time.Now(),
		Payload: provider.RuntimeEventPayload{
			RequestType: permissionRequestType(req.ToolCall),
			Decision:    decision,
			Resolution:  marshalRaw(map[string]string{"optionId": optionID}),
			Cancelled:   resp.Outcome.Outcome == schema.RequestPermissionOutcomeOutcomeCancelled,
		},
	}
	h.emitRuntimeEventForSession(string(req.SessionID), update)
}
