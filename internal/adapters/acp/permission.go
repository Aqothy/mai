// Permission handling for ACP session/request_permission: policy decisions,
// pending client approvals, and provider-neutral request events.
package acp

import (
	"context"
	"fmt"
	"time"

	"github.com/Aqothy/go-acp/schema"
	"github.com/Aqothy/maiD/internal/adapters/elicitation"
	"github.com/Aqothy/maiD/internal/provider"
)

func (h *Instance) RespondToRequest(_ context.Context, input provider.RespondToRequestInput) error {
	if input.ThreadID == "" || input.RequestID == "" {
		return fmt.Errorf("provider approval response requires threadId and requestId")
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
	response := approvalResponse{action: input.Action}
	if pending.elicitation {
		elicited, content, err := elicitation.Answer(pending.form, input.Action, input.Answers)
		if err != nil {
			return err
		}
		response.elicited, response.content = elicited, content
		if input.Action.Submit {
			response.answers = input.Answers
		}
	}
	select {
	case pending.ch <- response:
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
	sessionID := string(req.SessionID)
	// Permission requests are handled on jsonrpc's callback goroutine, while
	// session/update notifications are consumed by the per-session stream.
	// Re-enter that ordered stream before deriving request state or publishing
	// the approval so every update the agent sent first remains first.
	if stream := h.sessionStreamFor(sessionID); stream != nil {
		if err := h.awaitSessionBarrier(ctx, stream, nil); err != nil {
			return cancelledPermissionResponse(), nil
		}
	}
	state := h.permissionRequestState(sessionID)
	requestID := h.permissionRequestID(sessionID, state.threadID, string(req.ToolCall.ToolCallID))
	if state.cancelled || ctx.Err() != nil {
		resp := cancelledPermissionResponse()
		h.recordPermissionRequest(req, state, requestID)
		h.recordPermissionResolved(req, state, requestID, resp)
		return resp, nil
	}

	permissionCtx, cancelPermission, pending := h.beginPermissionRequest(ctx, sessionID, requestID)
	defer cancelPermission()
	defer h.endPermissionRequest(sessionID, requestID, pending)
	h.recordPermissionRequest(req, state, requestID)
	var response approvalResponse
	select {
	case response = <-pending.ch:
		h.mu.Lock()
		settled := pending.settled
		h.mu.Unlock()
		if settled {
			response = approvalResponse{}
		}
	case <-permissionCtx.Done():
	}
	resp := permissionResponseFor(response)
	h.recordPermissionResolved(req, state, requestID, resp)
	return resp, nil
}

// pendingPermission is an in-flight session/request_permission or
// elicitation/create awaiting the client's answer. It keeps its own cancel
// func so cancel registrations stay owned by the request that created them
// (a duplicate request for the same key must not be unregistered by the
// first request's cleanup).
type pendingPermission struct {
	ch chan approvalResponse
	// elicitation is set for elicitation/create, and form for one in form
	// mode, to validate and convert answers.
	elicitation bool
	form        *elicitation.Form
	settled     bool
	cancel      context.CancelFunc
}

// approvalResponse is the client's answer: the action it chose, zero when
// the request ended without one. For an elicitation, elicited is the
// response action, and answers and content the submitted form, as entered
// and converted to the types the form asked for.
type approvalResponse struct {
	action   provider.RequestAction
	elicited elicitation.Action
	answers  map[string][]string
	content  map[string]any
}

type permissionState struct {
	threadID  string
	turnID    string
	cancelled bool
}

func (h *Instance) permissionRequestState(sessionID string) permissionState {
	h.mu.Lock()
	defer h.mu.Unlock()
	collector := h.updateCollectorLocked(sessionID)
	if collector == nil {
		state := permissionState{}
		if session := h.sessionLocked(sessionID); session != nil {
			state.threadID = session.threadID
		}
		return state
	}
	return permissionState{threadID: collector.threadID, turnID: collector.turnID, cancelled: collector.cancelled}
}

func (h *Instance) beginPermissionRequest(ctx context.Context, sessionID string, requestID string) (context.Context, context.CancelFunc, *pendingPermission) {
	permissionCtx, cancel := context.WithCancel(ctx)
	pending := &pendingPermission{ch: make(chan approvalResponse, 1), cancel: cancel}
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessionLocked(sessionID)
	collector := h.updateCollectorLocked(sessionID)
	if session == nil || (collector != nil && collector.cancelled) {
		cancel()
		return permissionCtx, cancel, pending
	}
	// Outside a turn (e.g. an MCP server asking during session setup) the
	// request stays answerable; only the agent or the connection ends it.
	if collector != nil {
		if _, settled := collector.settledPermissionKeys[requestID]; settled {
			cancel()
			return permissionCtx, cancel, pending
		}
		if collector.pendingPermissionCancels == nil {
			collector.pendingPermissionCancels = make(map[string]*pendingPermission)
		}
		collector.pendingPermissionCancels[requestID] = pending
	}
	session.pendingPermissions[requestID] = pending
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
	if collector == nil {
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
	asked := permissionRequestFromACP(toolCallTitle(req.ToolCall), req.Options)
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
			Args:        marshalRaw(req.ToolCall),
			Request:     &asked,
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
			ActionID:    optionID,
			Cancelled:   resp.Outcome.Outcome == schema.RequestPermissionOutcomeOutcomeCancelled,
		},
	}
	h.emitRuntimeEventForSession(string(req.SessionID), update)
}
