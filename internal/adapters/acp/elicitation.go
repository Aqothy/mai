// Elicitation for the ACP adapter: elicitation/create asks the user for
// structured input (a form), a yes or no (a form with no fields), or consent
// to open a URL. Requests are surfaced as provider-neutral user-input or
// permission requests and answered through RespondToRequest, sharing the
// permission request lifecycle.
package acp

import (
	"context"
	"encoding/json"
	"time"

	acp "github.com/Aqothy/go-acp"
	"github.com/Aqothy/go-acp/schema"
	"github.com/Aqothy/maiD/internal/adapters/elicitation"
	"github.com/Aqothy/maiD/internal/provider"
)

// createElicitation answers elicitation/create. Params arrive raw so the form's
// questions keep the order the agent wrote them in.
func (h *Instance) createElicitation(ctx context.Context, params json.RawMessage) (schema.CreateElicitationResponse, error) {
	var req schema.CreateElicitationRequest
	var raw struct {
		RequestedSchema json.RawMessage `json:"requestedSchema"`
	}
	if err := json.Unmarshal(params, &req); err != nil {
		return schema.CreateElicitationResponse{}, acp.InvalidParamsError(err)
	}
	_ = json.Unmarshal(params, &raw)
	asked, form, err := elicitation.Parse(req.Message, req.Mode, stringValue(req.URL), raw.RequestedSchema)
	if err != nil {
		return schema.CreateElicitationResponse{}, acp.InvalidParamsError(err)
	}
	if req.SessionID == nil {
		return h.askDuringSignIn(ctx, asked, form), nil
	}
	sessionID := string(*req.SessionID)
	// Like permission requests, re-enter the session's ordered stream first so
	// every update the agent sent before asking is published before the question.
	if stream := h.sessionStreamFor(sessionID); stream != nil {
		if err := h.awaitSessionBarrier(ctx, stream, nil); err != nil {
			return schema.CreateElicitationResponse{Action: string(elicitation.ActionCancel)}, nil
		}
	}
	state := h.permissionRequestState(sessionID)
	requestID := "elicitation:" + state.threadID + ":" + newID()
	requestCtx, cancel, pending := h.beginPermissionRequest(ctx, sessionID, requestID)
	defer cancel()
	defer h.endPermissionRequest(sessionID, requestID, pending)
	pending.elicitation, pending.form = true, form
	payload := provider.RuntimeEventPayload{Request: &asked}
	if form.Confirms() {
		payload.Args = append(json.RawMessage(nil), params...)
	}
	h.emitRuntimeEventForSession(sessionID, provider.RuntimeEvent{
		EventID:   provider.RuntimeEventID(newID()),
		Provider:  DriverKind,
		ThreadID:  state.threadID,
		TurnID:    state.turnID,
		Type:      provider.RuntimeEventRequestOpened,
		RequestID: requestID,
		CreatedAt: time.Now(),
		Payload:   payload,
	})

	var response approvalResponse
	select {
	case response = <-pending.ch:
	case <-requestCtx.Done():
	}
	if response.action.ID == "" {
		response = approvalResponse{action: provider.RequestAction{Decision: provider.ApprovalDecisionCancel}, elicited: elicitation.ActionCancel}
	}
	resp := elicitationResponse(response.elicited, response.content)
	h.emitRuntimeEventForSession(sessionID, provider.RuntimeEvent{
		EventID:   provider.RuntimeEventID(newID()),
		Provider:  DriverKind,
		ThreadID:  state.threadID,
		TurnID:    state.turnID,
		Type:      provider.RuntimeEventRequestResolved,
		RequestID: requestID,
		CreatedAt: time.Now(),
		Payload: provider.RuntimeEventPayload{
			Decision:  response.action.Decision,
			ActionID:  response.action.ID,
			Cancelled: response.elicited == elicitation.ActionCancel,
			Answers:   response.answers,
		},
	})
	return resp, nil
}

// askDuringSignIn shows a request-scoped elicitation (one with no session,
// e.g. while authenticate runs) through the sign-in in progress. With no
// sign-in to ask on, nobody can answer it, so it is cancelled.
func (h *Instance) askDuringSignIn(ctx context.Context, asked provider.Request, form *elicitation.Form) schema.CreateElicitationResponse {
	h.mu.Lock()
	ask := h.signInAsk
	h.mu.Unlock()
	cancelled := schema.CreateElicitationResponse{Action: string(elicitation.ActionCancel)}
	if ask == nil {
		return cancelled
	}
	answer, err := ask(ctx, asked)
	if err != nil {
		return cancelled
	}
	elicited, content, err := elicitation.Answer(form, answer.Action, answer.Answers)
	if err != nil {
		return cancelled
	}
	return elicitationResponse(elicited, content)
}

func elicitationResponse(action elicitation.Action, content map[string]any) schema.CreateElicitationResponse {
	resp := schema.CreateElicitationResponse{Action: string(action)}
	if action == elicitation.ActionAccept && len(content) > 0 {
		resp.Content = make(map[string]schema.ElicitationContentValue, len(content))
		for key, value := range content {
			resp.Content[key] = value
		}
	}
	return resp
}
