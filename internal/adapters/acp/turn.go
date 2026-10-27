// Turns of the ACP adapter: prompts, cancellation, and recording frames.
//
// The daemon runs one turn per session at a time and never steers ACP
// (Capabilities.Steer is false: ACP has no way to add to a running prompt),
// so a session has at most one prompt at the agent.
package acp

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"slices"
	"strings"
	"time"

	"github.com/Aqothy/go-acp/schema"
	"github.com/Aqothy/maiD/internal/provider"
)

// Send sends a prompt as a new turn whose ref is the delivery ID.
func (h *Instance) Send(ctx context.Context, sessionID string, in provider.SendInput) (provider.SendAck, error) {
	if in.Steer {
		return provider.SendAck{}, provider.ErrUnsupported
	}
	if in.Delivery == "" {
		return provider.SendAck{}, fmt.Errorf("ACP prompt requires a delivery ID")
	}
	blocks, err := contentBlocks(in, h.Info().Capabilities.PromptContent)
	if err != nil {
		return provider.SendAck{}, err
	}
	h.mu.Lock()
	session := h.sessions[sessionID]
	switch {
	case session == nil || session.stream == nil || session.stream.closed:
		h.mu.Unlock()
		return provider.SendAck{}, fmt.Errorf("ACP session %q is not open", sessionID)
	case session.prompt != "":
		h.mu.Unlock()
		return provider.SendAck{}, fmt.Errorf("ACP session %q is already running turn %q", sessionID, session.prompt)
	}
	session.prompt = in.Delivery
	stream := session.stream
	h.mu.Unlock()
	attachments := slices.Clone(in.Attachments)
	h.record(session, frame{At: time.Now(), Prompt: &promptFrame{Turn: in.Delivery, Text: in.Text, Attachments: attachments}})
	stream.session.PromptAsync(h.ctx, blocks)
	return provider.SendAck{Turn: in.Delivery}, nil
}

// Interrupt cancels the turn's prompt. Pending requests end unanswered, and
// the agent settles the prompt as cancelled.
func (h *Instance) Interrupt(ctx context.Context, sessionID, turn string) error {
	h.mu.Lock()
	session := h.sessions[sessionID]
	running := session != nil && session.prompt != "" && session.prompt == turn
	h.mu.Unlock()
	if !running {
		// session/cancel is session-scoped: a stale interrupt would cancel
		// whichever prompt runs now.
		return nil
	}
	// Recorded first: the agent may answer the cancel with updates at once,
	// and those after it map as after the cancel.
	h.record(session, frame{At: time.Now(), Cancel: turn})
	if err := h.agentPeer.Cancel(ctx, schema.CancelNotification{SessionID: schema.SessionId(sessionID)}); err != nil {
		return acpRequestError(err)
	}
	h.cancelPendingPermissions(session)
	return nil
}

// settlePrompt ends the session's running prompt with the agent's answer.
func (h *Instance) settlePrompt(session *acpSession, resp schema.PromptResponse, err error) {
	h.noteAuthRequired(err)
	h.mu.Lock()
	turn := session.prompt
	session.prompt = ""
	cancelled := session.mapper != nil && session.mapper.cancelled && session.mapper.turn == turn
	h.mu.Unlock()
	if turn == "" {
		return
	}
	stop := &stopFrame{Turn: turn, State: provider.TurnCompleted}
	switch {
	case cancelled, err == nil && resp.StopReason == schema.StopReasonCancelled:
		stop.State = provider.TurnInterrupted
	case err != nil:
		stop.State, stop.Error = provider.TurnFailed, acpRequestError(err).Error()
	default:
		stop.StopReason = stopReasonFromACP(resp.StopReason)
	}
	h.record(session, frame{At: time.Now(), Stop: stop})
	h.cancelPendingPermissions(session)
}

// handleUpdate takes one session/update from the session's ordered stream.
func (h *Instance) handleUpdate(session *acpSession, notification schema.SessionNotification) {
	u := notification.Update
	switch u.SessionUpdate {
	case schema.SessionUpdateConfigOptionUpdate:
		h.cacheSessionState(session.id, u.ConfigOptions, nil)
		h.emitConfigOptions(session.id)
		return
	case schema.SessionUpdateCurrentModeUpdate:
		if u.CurrentModeID != nil && h.applyCurrentMode(session.id, *u.CurrentModeID) {
			h.emitConfigOptions(session.id)
		}
		return
	}
	raw, err := json.Marshal(u)
	if err != nil {
		slog.Debug("dropping ACP session update", "sessionId", session.id, "error", err)
		return
	}
	h.mu.Lock()
	options := session.options != nil
	capturing := session.capture != nil
	if capturing {
		session.capture = append(session.capture, raw)
	}
	h.mu.Unlock()
	if options || capturing {
		return
	}
	h.record(session, frame{At: time.Now(), Update: raw})
}

// record mirrors a frame and reports what it maps to, in frame order. A
// permission pending for a tool call that ended is cancelled: the agent no
// longer waits for it.
func (h *Instance) record(session *acpSession, f frame) {
	// Frames read back from the mirror carry no monotonic clock reading.
	f.At = f.At.Round(0)
	session.recordMu.Lock()
	if h.host.Mirror != nil {
		h.host.Mirror.Append(session.id, []json.RawMessage{encodeFrame(f)})
	}
	events := session.mapper.apply(f)
	var ended []string
	for _, event := range events {
		switch body := event.Body.(type) {
		case provider.ConfigChanged:
			if body.Commands != nil {
				h.mu.Lock()
				session.commands = body.Commands
				h.mu.Unlock()
			}
		case provider.EntryUpserted:
			if body.Entry.Tool != nil && body.Entry.Status != provider.ItemStatusInProgress {
				ended = append(ended, strings.TrimPrefix(body.Entry.Ref, body.Entry.Turn+"/tool/"))
			}
		}
	}
	if h.host.Emit != nil {
		for _, event := range events {
			event.Session = session.id
			h.host.Emit(event)
		}
	}
	session.recordMu.Unlock()
	if len(ended) > 0 {
		h.cancelPendingPermissions(session, ended...)
	}
}

// runningTurn is the turn the session's prompt runs and the entry of a tool
// call, for a request the agent makes; ended when nobody can answer it any
// more: the turn was cancelled or the tool call already ended.
func (h *Instance) runningTurn(session *acpSession, toolCallID string) (turn, entry string, ended bool) {
	session.recordMu.Lock()
	defer session.recordMu.Unlock()
	turn = session.mapper.turn
	if session.mapper.cancelled {
		return turn, "", true
	}
	if turn == "" || toolCallID == "" {
		return turn, "", false
	}
	if tool := session.mapper.tools[toolCallID]; tool != nil {
		return turn, tool.entry.Ref, tool.entry.Status != provider.ItemStatusInProgress
	}
	return turn, "", false
}
