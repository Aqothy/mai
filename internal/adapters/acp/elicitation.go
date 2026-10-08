// Elicitation for the ACP adapter: elicitation/create asks the user for
// structured input (a form) or for consent to open a URL. Requests are surfaced
// as provider-neutral user-input requests and answered through
// RespondToRequest, sharing the permission request lifecycle.
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
	input, form, err := elicitation.Parse(req.Message, req.Mode, stringValue(req.URL), raw.RequestedSchema)
	if err != nil {
		return schema.CreateElicitationResponse{}, acp.InvalidParamsError(err)
	}
	if req.SessionID == nil {
		// Request-scoped elicitations (e.g. during authenticate) have no
		// thread to ask on; the agent must handle cancel.
		return schema.CreateElicitationResponse{Action: string(elicitation.ActionCancel)}, nil
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
	requestCtx, cancel, pending := h.beginPermissionRequest(ctx, sessionID, requestID, nil)
	defer cancel()
	defer h.endPermissionRequest(sessionID, requestID, pending)
	pending.form = form
	h.emitRuntimeEventForSession(sessionID, provider.RuntimeEvent{
		EventID:   provider.RuntimeEventID(newID()),
		Provider:  DriverKind,
		ThreadID:  state.threadID,
		TurnID:    state.turnID,
		Type:      provider.RuntimeEventRequestOpened,
		RequestID: requestID,
		CreatedAt: time.Now(),
		Payload:   provider.RuntimeEventPayload{UserInput: &input},
	})

	response := approvalResponse{decision: provider.ApprovalDecisionCancel}
	select {
	case response = <-pending.ch:
	case <-requestCtx.Done():
	}
	action := elicitation.ActionFor(response.decision)
	response.decision = action.Decision()
	if action != elicitation.ActionAccept {
		response.answers = nil
	}
	resp := schema.CreateElicitationResponse{Action: string(action)}
	if action == elicitation.ActionAccept && len(response.content) > 0 {
		resp.Content = make(map[string]schema.ElicitationContentValue, len(response.content))
		for key, value := range response.content {
			resp.Content[key] = value
		}
	}
	h.emitRuntimeEventForSession(sessionID, provider.RuntimeEvent{
		EventID:   provider.RuntimeEventID(newID()),
		Provider:  DriverKind,
		ThreadID:  state.threadID,
		TurnID:    state.turnID,
		Type:      provider.RuntimeEventRequestResolved,
		RequestID: requestID,
		CreatedAt: time.Now(),
		Payload: provider.RuntimeEventPayload{
			Decision:  response.decision,
			Cancelled: action == elicitation.ActionCancel,
			Answers:   response.answers,
		},
	})
	return resp, nil
}
