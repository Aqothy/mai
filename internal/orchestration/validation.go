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

func defaultRuntimeMode(mode RuntimeMode) RuntimeMode {
	if mode == "" {
		return RuntimeModeFullAccess
	}
	return mode
}

func defaultInteractionMode(mode ProviderInteractionMode) ProviderInteractionMode {
	if mode == "" {
		return ProviderInteractionModeDefault
	}
	return mode
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

func validateMetaInteractionModeChange(thread Thread, mode ProviderInteractionMode) error {
	if mode == "" || mode == thread.InteractionMode {
		return nil
	}
	if !providerSessionActive(thread.Session) {
		return nil
	}
	return fmt.Errorf("cannot change interactionMode while provider session is active; use thread.interaction-mode.set")
}

func validateActiveRuntimeModeChange(thread Thread, mode RuntimeMode) error {
	if mode == "" || mode == thread.RuntimeMode {
		return nil
	}
	if activeTurnID(thread) == "" {
		return nil
	}
	return fmt.Errorf("cannot change runtimeMode while a turn is active; wait for the turn to finish or interrupt it first")
}

func validateTurnStartBoundary(command Command) error {
	if command.TurnID != "" {
		return fmt.Errorf("thread.turn.start does not accept turnId; turnId is server-minted")
	}
	if command.RuntimeMode != "" {
		return fmt.Errorf("thread.turn.start does not accept runtimeMode; use thread.runtime-mode.set")
	}
	if command.InteractionMode != "" {
		return fmt.Errorf("thread.turn.start does not accept interactionMode; use thread.interaction-mode.set")
	}
	return nil
}

func validateRuntimeMode(commandType string, mode RuntimeMode, required bool) error {
	if mode == "" {
		if required {
			return fmt.Errorf("%s requires runtimeMode", commandType)
		}
		return nil
	}
	switch mode {
	case RuntimeModeApprovalRequired, RuntimeModeAutoAcceptEdits, RuntimeModeFullAccess:
		return nil
	default:
		return fmt.Errorf("%s runtimeMode %q is not supported", commandType, mode)
	}
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
