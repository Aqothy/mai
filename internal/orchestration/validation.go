package orchestration

import (
	"fmt"

	"github.com/Aqothy/maiD/internal/provider"
)

func activeTurnID(thread Thread) TurnID {
	if thread.Session != nil && thread.Session.ActiveTurnID != "" {
		return thread.Session.ActiveTurnID
	}
	if thread.LatestTurn != nil && thread.LatestTurn.State == TurnStateRunning {
		return thread.LatestTurn.ID
	}
	return ""
}

func providerSessionActive(session *SessionBinding) bool {
	return session != nil && session.Status != SessionStatusStopped
}

func sessionPreparing(thread Thread) bool {
	return thread.Session != nil && thread.Session.Status == SessionStatusStarting && thread.Session.ActiveTurnID == ""
}

func validateMetaCwdChange(thread Thread, cwd string) error {
	if cwd == "" || cwd == thread.Cwd {
		return nil
	}
	if !providerSessionActive(thread.Session) {
		return nil
	}
	return fmt.Errorf("cannot change cwd while provider session is active; stop the session first")
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

func validateApprovalResponse(commandType string, thread Thread, requestID ApprovalID, optionID string) error {
	approval := thread.Timeline.Approval(string(requestID))
	if approval == nil {
		return fmt.Errorf("%s request %q is not pending", commandType, requestID)
	}
	if approval.Status != ApprovalStatusPending {
		return fmt.Errorf("%s request %q is already resolved", commandType, requestID)
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

func validateGenericAttachments(commandType string, attachments []provider.Attachment) error {
	for i, attachment := range attachments {
		if len(attachment.Raw) > 0 {
			return fmt.Errorf("%s message.attachments[%d].raw is not supported; use a generic attachment kind", commandType, i)
		}
	}
	return nil
}
