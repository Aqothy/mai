package orchestration

import (
	"context"
	"time"

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

// ProcessBusy reports whether a turn or a message on its way to one needs the
// instance's process of generation.
func (e *Engine) ProcessBusy(ctx context.Context, instance provider.InstanceID, generation uint64) bool {
	// Busy when the engine can't answer, so nothing ends on a guess.
	busy, err := call(ctx, e, func(s *step) (bool, error) {
		return e.needed(func(participant *participantState) bool {
			return participant.Instance == instance && participant.live != nil && participant.live.generation == generation
		}), nil
	})
	return busy || err != nil
}

// InstanceBusy reports whether a turn or a message on its way to one needs the
// instance.
func (e *Engine) InstanceBusy(ctx context.Context, instance provider.InstanceID) bool {
	// Busy when the engine can't answer, so nothing ends on a guess.
	busy, err := call(ctx, e, func(s *step) (bool, error) { return e.instanceNeeded(instance), nil })
	return busy || err != nil
}

func (e *Engine) instanceNeeded(instance provider.InstanceID) bool {
	return e.needed(func(participant *participantState) bool { return participant.Instance == instance })
}

// needed reports whether a turn or a message on its way to one needs a
// participant that matches. A message nothing has answered within
// providerCallTimeout no longer counts: a provider that took it and hung can't
// keep off the restart that would recover it.
func (e *Engine) needed(matches func(*participantState) bool) bool {
	needs := func(id ParticipantID) bool {
		participant := e.participants[id]
		return participant != nil && matches(participant)
	}
	for _, thread := range e.threads {
		if running := thread.runningTurn(); running != nil && needs(running.Participant) {
			return true
		}
		for _, delivery := range thread.queue {
			if delivery.State == DeliverySending && time.Since(delivery.Sent) < providerCallTimeout && needs(delivery.To) {
				return true
			}
		}
	}
	return false
}
