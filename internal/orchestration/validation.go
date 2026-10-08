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

func validateApprovalDecision(commandType string, decision provider.ApprovalDecision) error {
	switch decision {
	case provider.ApprovalDecisionAccept, provider.ApprovalDecisionAcceptForSession, provider.ApprovalDecisionDecline, provider.ApprovalDecisionCancel:
		return nil
	default:
		return fmt.Errorf("%s decision %q is not supported", commandType, decision)
	}
}

func validateApprovalResponse(commandType string, thread Thread, requestID ApprovalID, decision provider.ApprovalDecision, optionID string, answers map[string][]string) error {
	approval := thread.Timeline.Approval(string(requestID))
	if approval == nil {
		return fmt.Errorf("%s request %q is not pending", commandType, requestID)
	}
	if approval.Status != ApprovalStatusPending {
		return fmt.Errorf("%s request %q is already resolved", commandType, requestID)
	}
	if approval.UserInput != nil {
		if decision == provider.ApprovalDecisionAcceptForSession || optionID != "" {
			return fmt.Errorf("%s request %q is a question; answer it with accept, decline or cancel", commandType, requestID)
		}
		return nil
	}
	if len(answers) > 0 {
		return fmt.Errorf("%s request %q is not a question and takes no answers", commandType, requestID)
	}
	if optionID == "" {
		return nil
	}
	for _, option := range approval.Options {
		if option.ID == optionID {
			return nil
		}
	}
	return fmt.Errorf("%s optionId %q was not offered for request %q", commandType, optionID, requestID)
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
