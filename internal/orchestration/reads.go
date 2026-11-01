package orchestration

import (
	"context"

	"github.com/Aqothy/maiD/internal/provider"
)

// Workspace is where a thread works.
func (e *Engine) Workspace(ctx context.Context, id ThreadID) (provider.Workspace, error) {
	return call(ctx, e, func(s *step) (provider.Workspace, error) {
		thread, err := e.existing(id)
		if err != nil {
			return provider.Workspace{}, err
		}
		return thread.Workspace, nil
	})
}

// ParticipantSession names a thread's participant (its address when empty)
// for a provider call on its behalf: its instance and its live session, if
// any.
type ParticipantSession struct {
	Instance  provider.InstanceID
	Session   string
	Workspace provider.Workspace
}

func (e *Engine) ParticipantSession(ctx context.Context, id ThreadID, participant ParticipantID) (ParticipantSession, error) {
	return call(ctx, e, func(s *step) (ParticipantSession, error) {
		thread, err := e.existing(id)
		if err != nil {
			return ParticipantSession{}, err
		}
		if participant == "" {
			participant = thread.Address
		}
		state := e.participants[participant]
		if state == nil || state.Thread != id {
			return ParticipantSession{}, refused(CodeNotFound, "agent %q isn't in this chat", participant)
		}
		out := ParticipantSession{Instance: state.Instance, Workspace: thread.Workspace}
		if state.live != nil {
			out.Session = state.Session
		}
		return out, nil
	})
}

// InstanceBusy reports whether a turn runs on the instance.
func (e *Engine) InstanceBusy(ctx context.Context, instance provider.InstanceID) bool {
	busy, _ := call(ctx, e, func(s *step) (bool, error) {
		for _, thread := range e.threads {
			if running := thread.runningTurn(); running != nil {
				if participant := e.participants[running.Participant]; participant != nil && participant.Instance == instance {
					return true, nil
				}
			}
		}
		return false, nil
	})
	return busy
}
