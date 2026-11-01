// Requests for the ACP adapter: session/request_permission and
// elicitation/create are surfaced as provider-neutral requests and answered
// through Respond.
package acp

import (
	"context"
	"fmt"
	"slices"
	"time"

	"github.com/Aqothy/go-acp/schema"
	"github.com/Aqothy/maiD/internal/adapters/elicitation"
	"github.com/Aqothy/maiD/internal/provider"
)

// pendingPermission is an in-flight session/request_permission or
// elicitation/create awaiting the user's answer.
type pendingPermission struct {
	turn string
	// toolCallID is the tool call a permission is for: the agent stops
	// waiting for the answer once that call ends.
	toolCallID string
	ch         chan approvalResponse
	// elicitation is set for elicitation/create, and form for one in form
	// mode, to validate and convert answers.
	elicitation bool
	form        *elicitation.Form
	cancel      context.CancelFunc
}

// approvalResponse is the user's answer: the action chosen, zero when the
// request ended without one. For an elicitation, elicited is the response
// action, and answers and content the submitted form, as entered and
// converted to the types the form asked for.
type approvalResponse struct {
	action   provider.RequestAction
	elicited elicitation.Action
	answers  map[string][]string
	content  map[string]any
}

func (h *Instance) Respond(_ context.Context, sessionID, requestID string, answer provider.RequestAnswer) error {
	h.mu.Lock()
	var pending *pendingPermission
	if session := h.sessions[sessionID]; session != nil {
		pending = session.pendingPermissions[requestID]
	}
	h.mu.Unlock()
	if pending == nil {
		return fmt.Errorf("ACP request %q is not pending", requestID)
	}
	response := approvalResponse{action: answer.Action}
	if pending.elicitation {
		elicited, content, err := elicitation.Answer(pending.form, answer.Action, answer.Answers)
		if err != nil {
			return err
		}
		response.elicited, response.content = elicited, content
		if answer.Action.Submit {
			response.answers = answer.Answers
		}
	}
	select {
	case pending.ch <- response:
		return nil
	default:
		return fmt.Errorf("ACP request %q is already answered", requestID)
	}
}

// ask opens a request on the session and waits for the user's answer, the
// turn's end or the agent cancelling it ($/cancel_request cancels ctx). It
// re-enters the session's ordered stream first, so every update the agent
// sent before asking is reported before the request.
func (h *Instance) ask(ctx context.Context, sessionID, toolCallID string, asked provider.Request, form *elicitation.Form, isElicitation bool) (approvalResponse, bool) {
	stream := h.sessionStreamFor(sessionID)
	if stream == nil || h.awaitSessionBarrier(ctx, stream, nil) != nil {
		return approvalResponse{}, false
	}
	h.mu.Lock()
	session := h.sessions[sessionID]
	h.mu.Unlock()
	if session == nil || session.options != nil {
		return approvalResponse{}, false
	}
	turn, entry, ended := h.runningTurn(session, toolCallID)
	if ended {
		return approvalResponse{}, false
	}
	requestCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	requestID := newID()
	pending := &pendingPermission{turn: turn, toolCallID: toolCallID, ch: make(chan approvalResponse, 1), elicitation: isElicitation, form: form, cancel: cancel}
	h.mu.Lock()
	session.pendingPermissions[requestID] = pending
	h.mu.Unlock()
	h.emitRequest(sessionID, provider.RequestOpened{Request: requestID, Turn: turn, Entry: entry, Ask: asked})
	var response approvalResponse
	select {
	case response = <-pending.ch:
	case <-requestCtx.Done():
	}
	h.mu.Lock()
	delete(session.pendingPermissions, requestID)
	h.mu.Unlock()
	resolved := provider.RequestResolved{Request: requestID, Action: response.action.ID, Answers: response.answers}
	h.emitRequest(sessionID, resolved)
	return response, response.action.ID != ""
}

// emitRequest reports a request event of a session, unless the session is
// gone.
func (h *Instance) emitRequest(sessionID string, body provider.EventBody) {
	if h.host.Emit != nil {
		h.host.Emit(provider.Event{Session: sessionID, At: time.Now(), Body: body})
	}
}

// cancelPendingPermissions ends the session's pending requests unanswered:
// its turn ended or was cancelled, or, with toolCallIDs, those tool calls
// ended.
func (h *Instance) cancelPendingPermissions(session *acpSession, toolCallIDs ...string) {
	h.mu.Lock()
	cancels := make([]context.CancelFunc, 0, len(session.pendingPermissions))
	for _, pending := range session.pendingPermissions {
		if len(toolCallIDs) == 0 || pending.toolCallID != "" && slices.Contains(toolCallIDs, pending.toolCallID) {
			cancels = append(cancels, pending.cancel)
		}
	}
	h.mu.Unlock()
	for _, cancel := range cancels {
		cancel()
	}
}

// requestPermission answers the agent's session/request_permission with the
// option the user chose, or as cancelled.
func (h *Instance) requestPermission(ctx context.Context, req schema.RequestPermissionRequest) (schema.RequestPermissionResponse, error) {
	asked := permissionRequestFromACP(toolCallTitle(req.ToolCall), req.Options)
	asked.Details = marshalRaw(req.ToolCall)
	response, answered := h.ask(ctx, string(req.SessionID), string(req.ToolCall.ToolCallID), asked, nil, false)
	if !answered {
		return cancelledPermissionResponse(), nil
	}
	return permissionResponseFor(response), nil
}
