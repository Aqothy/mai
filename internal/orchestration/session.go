package orchestration

import (
	"fmt"
	"log"
	"runtime/debug"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// Session lifecycle updates run on the engine worker. Producers report only
// what changed; the engine derives a complete SessionBinding from current
// thread state under its write lock and appends the ordinary client-facing
// session-status event. Stale updates append nothing.

type sessionUpdateKind string

const (
	sessionUpdateBound       sessionUpdateKind = "bound"
	sessionUpdateTurnStarted sessionUpdateKind = "turn-started"
	sessionUpdateTurnSettled sessionUpdateKind = "turn-settled"
	sessionUpdateStopped     sessionUpdateKind = "stopped"
	sessionUpdateError       sessionUpdateKind = "error"
)

type sessionUpdate struct {
	threadID   ThreadID
	occurredAt time.Time
	Kind       sessionUpdateKind
	Binding    *SessionBinding
	TurnID     TurnID
	TurnState  provider.RuntimeTurnState
	StopReason string
	Error      string
}

func (e *Engine) sessionUpdateRecovered(update sessionUpdate) (result DispatchResult, err error) {
	defer func() {
		if rec := recover(); rec != nil {
			if violation, ok := rec.(*InvariantViolationError); ok {
				err = violation
				return
			}
			log.Printf("orchestration: session update %q panicked: %v\n%s", update.Kind, rec, debug.Stack())
			err = fmt.Errorf("session update %q panicked: %v", update.Kind, rec)
		}
	}()
	return e.applySessionUpdate(update)
}

func (e *Engine) applySessionUpdate(update sessionUpdate) (DispatchResult, error) {
	if update.threadID == "" {
		return DispatchResult{}, fmt.Errorf("session update %q requires threadId", update.Kind)
	}
	switch update.Kind {
	case sessionUpdateBound, sessionUpdateTurnStarted, sessionUpdateTurnSettled, sessionUpdateStopped, sessionUpdateError:
	default:
		return DispatchResult{}, fmt.Errorf("unsupported session update %q", update.Kind)
	}
	var sequence uint64
	err := e.withLockNotify(func(appendEvent func(Event) Event) error {
		thread := e.projection.liveThread(update.threadID)
		if thread == nil {
			return fmt.Errorf("thread %q not found", update.threadID)
		}
		session, ok := deriveSessionStatus(thread, update, update.occurredAt)
		if !ok {
			return nil
		}
		stopReason := ""
		if update.Kind != sessionUpdateStopped || activeTurnID(*thread) != "" {
			stopReason = update.StopReason
		}
		appended := appendEvent(Event{Type: EventThreadSessionStatusSet, OccurredAt: update.occurredAt, Actor: ActorKindServer, Payload: EventPayload{ThreadID: update.threadID, Session: session, StopReason: stopReason}})
		sequence = appended.Sequence
		return nil
	})
	return DispatchResult{Sequence: sequence}, err
}

// deriveSessionStatus derives the complete SessionBinding for a session update
// from the live projection thread. It must run inside the engine's locked
// write region. ok=false means the update is stale against current state and
// is dropped — no event is appended:
//   - a turn-settled/turn-scoped-error update for a turn that is not the
//     thread's current/latest turn (out-of-order/late terminal event);
//   - a turn-started/turn-settled/error update arriving after the session was
//     stopped (a late settle never resurrects a Stopped session — bound updates
//     are explicit rebind intents and do apply);
//   - a bound update for a turn that is no longer running (an interrupt won the
//     race with session start);
//   - a turn-started update for the already-running turn (duplicate of the
//     optimistic projection state).
func deriveSessionStatus(thread *Thread, update sessionUpdate, occurredAt time.Time) (*SessionBinding, bool) {
	switch update.Kind {
	case sessionUpdateBound:
		return deriveSessionBound(thread, update, occurredAt)
	case sessionUpdateTurnStarted:
		return deriveSessionTurnStarted(thread, update, occurredAt)
	case sessionUpdateTurnSettled:
		return deriveSessionTurnSettled(thread, update, occurredAt)
	case sessionUpdateStopped:
		return deriveSessionStopped(thread, occurredAt)
	case sessionUpdateError:
		return deriveSessionError(thread, update, occurredAt)
	}
	return nil, false
}

func deriveSessionBound(thread *Thread, update sessionUpdate, occurredAt time.Time) (*SessionBinding, bool) {
	if update.TurnID != "" && !turnStillRunning(*thread, update.TurnID) {
		return nil, false
	}
	if update.Binding == nil && update.TurnID == "" && thread.Session == nil {
		return nil, false // nothing to bind and nothing to settle back to ready
	}
	providerInstanceID := thread.ProviderInstanceID
	if update.Binding != nil && update.Binding.ProviderInstanceID != "" {
		providerInstanceID = update.Binding.ProviderInstanceID
	}
	// Rebinding on the SAME provider instance keeps the session's accumulated
	// metadata (config options, slash commands, usage); a different instance
	// starts from a fresh binding.
	session := sessionScaffold(thread, providerInstanceID, occurredAt)
	if thread.Session != nil && (thread.Session.ProviderInstanceID == "" || providerInstanceID == "" || thread.Session.ProviderInstanceID == providerInstanceID) {
		session = cloneSessionPtr(thread.Session)
	}
	if update.Binding != nil {
		overlaySessionIdentity(session, update.Binding)
	}
	session.ThreadID = thread.ID
	session.ProviderInstanceID = providerInstanceID
	session.RuntimeMode = thread.RuntimeMode
	if session.Cwd == "" {
		session.Cwd = thread.Cwd
	}
	switch {
	case update.TurnID == "":
		session.Status = SessionStatusReady
		session.ActiveTurnID = ""
	case update.Binding == nil:
		session.Status = SessionStatusStarting
		session.ActiveTurnID = update.TurnID
	default:
		session.Status = SessionStatusRunning
		session.ActiveTurnID = update.TurnID
	}
	session.LastError = ""
	session.UpdatedAt = occurredAt
	return session, true
}

func deriveSessionTurnStarted(thread *Thread, update sessionUpdate, occurredAt time.Time) (*SessionBinding, bool) {
	if thread.Session == nil || thread.Session.Status == SessionStatusStopped {
		return nil, false
	}
	if sessionTurnConflicts(thread, update.TurnID) {
		return nil, false
	}
	if thread.Session.Status == SessionStatusRunning && thread.Session.ActiveTurnID == update.TurnID {
		return nil, false // already running this turn (optimistic projection state)
	}
	session := cloneSessionPtr(thread.Session)
	session.Status = SessionStatusRunning
	if update.TurnID != "" {
		session.ActiveTurnID = update.TurnID
	}
	session.LastError = ""
	session.UpdatedAt = occurredAt
	return session, true
}

func deriveSessionTurnSettled(thread *Thread, update sessionUpdate, occurredAt time.Time) (*SessionBinding, bool) {
	if thread.Session == nil || thread.Session.Status == SessionStatusStopped {
		return nil, false // preserve Stopped: a late settle never resurrects the session
	}
	if sessionTurnConflicts(thread, update.TurnID) {
		return nil, false
	}
	session := cloneSessionPtr(thread.Session)
	session.ActiveTurnID = ""
	session.LastError = ""
	switch update.TurnState {
	case provider.RuntimeTurnFailed:
		session.Status = SessionStatusError
		session.LastError = firstNonEmpty(update.Error, update.StopReason, "Turn failed")
	case provider.RuntimeTurnInterrupted, provider.RuntimeTurnCancelled:
		session.Status = SessionStatusInterrupted
	default:
		session.Status = SessionStatusReady
	}
	session.UpdatedAt = occurredAt
	return session, true
}

func deriveSessionStopped(thread *Thread, occurredAt time.Time) (*SessionBinding, bool) {
	if thread.Session == nil {
		return nil, false
	}
	session := cloneSessionPtr(thread.Session)
	session.Status = SessionStatusStopped
	session.ActiveTurnID = ""
	session.LastError = ""
	session.UpdatedAt = occurredAt
	return session, true
}

func deriveSessionError(thread *Thread, update sessionUpdate, occurredAt time.Time) (*SessionBinding, bool) {
	if thread.Session != nil && thread.Session.Status == SessionStatusStopped {
		return nil, false
	}
	if update.TurnID != "" && sessionTurnConflicts(thread, update.TurnID) {
		return nil, false // stale turn-scoped error must not fail the current turn
	}
	session := sessionScaffold(thread, thread.ProviderInstanceID, occurredAt)
	if thread.Session != nil {
		session = cloneSessionPtr(thread.Session)
	}
	session.Status = SessionStatusError
	session.ActiveTurnID = ""
	session.LastError = firstNonEmpty(update.Error, "Runtime error")
	session.UpdatedAt = occurredAt
	return session, true
}

func sessionScaffold(thread *Thread, providerInstanceID provider.InstanceID, occurredAt time.Time) *SessionBinding {
	return &SessionBinding{ThreadID: thread.ID, ProviderInstanceID: providerInstanceID, RuntimeMode: thread.RuntimeMode, Cwd: thread.Cwd, UpdatedAt: occurredAt}
}

// overlaySessionIdentity applies the provider-session identity fields of a
// bound update over the base binding; empty fields keep the base value.
func overlaySessionIdentity(session *SessionBinding, binding *SessionBinding) {
	if binding.ProviderGeneration != 0 {
		session.ProviderGeneration = binding.ProviderGeneration
	}
	if binding.ProviderName != "" {
		session.ProviderName = binding.ProviderName
	}
	if binding.Provider != "" {
		session.Provider = binding.Provider
	}
	if binding.Cwd != "" {
		session.Cwd = binding.Cwd
	}
	if binding.ConfigOptions != nil {
		session.ConfigOptions = cloneConfigOptions(binding.ConfigOptions)
	}
	if binding.SlashCommands != nil {
		session.SlashCommands = cloneSlashCommands(binding.SlashCommands)
	}
	if binding.TokenUsage != nil {
		usage := *binding.TokenUsage
		session.TokenUsage = &usage
	}
}

// sessionTurnConflicts reports whether a turn-scoped session update targets a
// turn other than the thread's current/latest turn (an out-of-order/stale
// terminal event).
func sessionTurnConflicts(thread *Thread, turnID TurnID) bool {
	if turnID == "" {
		return false
	}
	if thread.Session != nil && thread.Session.ActiveTurnID != "" {
		return thread.Session.ActiveTurnID != turnID
	}
	if thread.LatestTurn != nil && thread.LatestTurn.ID != "" {
		return thread.LatestTurn.ID != turnID
	}
	return false
}

func turnStillRunning(thread Thread, turnID TurnID) bool {
	if turnID == "" {
		return true
	}
	if thread.LatestTurn != nil && thread.LatestTurn.ID == turnID {
		return thread.LatestTurn.State == TurnStateRunning && !thread.LatestTurn.InterruptRequested
	}
	return thread.Session != nil && thread.Session.ActiveTurnID == turnID && thread.Session.Status == SessionStatusRunning
}
