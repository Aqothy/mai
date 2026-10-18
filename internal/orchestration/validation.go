package orchestration

import (
	"fmt"
	"slices"

	"github.com/Aqothy/maiD/internal/provider"
)

func activeTurnID(thread Thread) TurnID {
	return activeTurnIDOf(thread.Session, thread.LatestTurn)
}

// activeTurnIDOf is the session/turn-only form, for callers holding a
// ThreadSessionView rather than a cloned thread.
func activeTurnIDOf(session *SessionBinding, latestTurn *Turn) TurnID {
	if session != nil && session.ActiveTurnID != "" {
		return session.ActiveTurnID
	}
	if latestTurn != nil && latestTurn.State == TurnStateRunning {
		return latestTurn.ID
	}
	return ""
}

func providerSessionActive(session *SessionBinding) bool {
	return session != nil && session.Status != SessionStatusStopped
}

func sessionPreparing(thread Thread) bool {
	return thread.Session != nil && thread.Session.Status == SessionStatusStarting && thread.Session.ActiveTurnID == ""
}

// canStartTurn reports whether the thread can take a new turn now. A running
// turn (stopping included) or a preparing or stopping session keeps new
// prompts queued until it settles.
func canStartTurn(thread Thread) bool {
	return !thread.ReplayHistoryPending && !sessionPreparing(thread) && activeTurnID(thread) == "" &&
		(thread.Session == nil || !thread.Session.StopRequested)
}

func validateMetaDirectoriesChange(thread Thread, cwd string, additionalDirectories []string, changesAdditionalDirectories bool) error {
	if !providerSessionActive(thread.Session) {
		return nil
	}
	if cwd != "" && cwd != thread.Cwd {
		return fmt.Errorf("cannot change cwd while provider session is active; stop the session first")
	}
	if !changesAdditionalDirectories || slices.Equal(thread.AdditionalDirectories, additionalDirectories) {
		return nil
	}
	return fmt.Errorf("cannot change additional directories while provider session is active; stop the session first")
}

func validateTurnStartBoundary(command Command) error {
	if command.TurnID != "" {
		return fmt.Errorf("thread.turn.start does not accept turnId; turnId is server-minted")
	}
	return nil
}

// validateApprovalResponse finds the action a response chose among the
// pending request's own. Only an action that submits takes answers.
func validateApprovalResponse(commandType string, thread Thread, requestID ApprovalID, actionID string, answers map[string][]string) (provider.RequestAction, error) {
	approval := thread.Timeline.Approval(string(requestID))
	if approval == nil || approval.Request == nil {
		return provider.RequestAction{}, fmt.Errorf("%s request %q is not pending", commandType, requestID)
	}
	if approval.Status != ApprovalStatusPending {
		return provider.RequestAction{}, fmt.Errorf("%s request %q is already resolved", commandType, requestID)
	}
	// The first answer wins until the provider resolves or reopens the
	// request: a second one, from another client or a repeated tap, would
	// reach a provider that has already moved on.
	if approval.ActionID != "" {
		return provider.RequestAction{}, fmt.Errorf("%s request %q is already answered", commandType, requestID)
	}
	action, ok := approval.Request.Action(actionID)
	if !ok {
		return provider.RequestAction{}, fmt.Errorf("%s actionId %q was not offered for request %q", commandType, actionID, requestID)
	}
	if len(answers) > 0 && !action.Submit {
		return provider.RequestAction{}, fmt.Errorf("%s action %q of request %q takes no answers", commandType, actionID, requestID)
	}
	return action, nil
}

// validateCommandMessage checks a client prompt: it must say something, and
// its attachments must be kinds every layer understands.
func validateCommandMessage(commandType string, message *CommandMessage) error {
	if message == nil || (message.Text == "" && len(message.Attachments) == 0 && len(message.Annotations) == 0) {
		return fmt.Errorf("%s requires message text, attachments or annotations", commandType)
	}
	for _, attachment := range message.Attachments {
		switch attachment.Kind {
		case provider.AttachmentImage, provider.AttachmentAudio, provider.AttachmentResource, provider.AttachmentResourceLink:
		default:
			return fmt.Errorf("%s attachment kind %q is not supported", commandType, attachment.Kind)
		}
	}
	return nil
}
