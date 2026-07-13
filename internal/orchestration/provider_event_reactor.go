package orchestration

import (
	"context"
	"fmt"
	"log"
	"runtime/debug"
	"sync"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

type ProviderRuntime interface {
	StartSession(ctx context.Context, threadID string, input provider.StartSessionInput) (provider.Session, error)
	SendTurn(ctx context.Context, input provider.SendTurnInput) error
	InterruptTurn(ctx context.Context, input provider.InterruptTurnInput) error
	SetConfigOption(ctx context.Context, input provider.SetConfigOptionInput) error
	StopSession(ctx context.Context, input provider.StopSessionInput) error
	ReleaseSession(ctx context.Context, input provider.StopSessionInput) error
	RespondToRequest(ctx context.Context, input provider.RespondToRequestInput) error
}

const defaultProviderRPCTimeout = 60 * time.Second

type ProviderEventReactor struct {
	engine   *Engine
	provider ProviderRuntime

	// baseCtx scopes every provider RPC to the owning server's lifecycle:
	// when the server closes, in-flight RPC chains are cancelled immediately
	// instead of lingering until their per-RPC timeout.
	baseCtx            context.Context
	providerRPCTimeout time.Duration

	// mu guards threadTails, the per-thread handler chain. Chaining on the
	// previous tail is the reactor's ONLY serialization: handlers for one thread
	// never overlap, so handler bodies need no additional locking.
	mu          sync.Mutex
	threadTails map[ThreadID]chan struct{}
}

// NewProviderEventReactor wires the reactor to the engine's event stream. ctx
// is the reactor's base context (typically the daemon server's lifecycle
// context); cancelling it cancels all in-flight provider RPCs.
func NewProviderEventReactor(ctx context.Context, engine *Engine, providerRuntime ProviderRuntime) *ProviderEventReactor {
	if ctx == nil {
		ctx = context.Background()
	}
	r := &ProviderEventReactor{engine: engine, provider: providerRuntime, baseCtx: ctx, providerRPCTimeout: defaultProviderRPCTimeout, threadTails: make(map[ThreadID]chan struct{})}
	engine.OnEvent(r.handle)
	return r
}

func (r *ProviderEventReactor) providerRPCContext() (context.Context, context.CancelFunc) {
	timeout := r.providerRPCTimeout
	if timeout <= 0 {
		timeout = defaultProviderRPCTimeout
	}
	base := r.baseCtx
	if base == nil {
		base = context.Background()
	}
	return context.WithTimeout(base, timeout)
}

func (r *ProviderEventReactor) handle(event Event) {
	switch event.Type {
	case EventThreadMetaUpdated:
		if event.Payload.SessionCleared {
			r.enqueueThread(event, func() { r.handleSessionRelease(event) })
		}
	case EventThreadSessionPrepareRequested:
		r.enqueueThread(event, func() { r.handleSessionPrepare(event) })
	case EventThreadTurnStartRequested:
		r.enqueueThread(event, func() { r.handleTurnStart(event) })
	case EventThreadTurnInterruptRequested:
		r.enqueueThread(event, func() { r.handleInterrupt(event) })
	case EventThreadSessionStopRequested:
		r.enqueueThread(event, func() { r.handleStop(event) })
	case EventThreadConfigOptionSetRequested:
		r.enqueueThread(event, func() { r.handleConfigOption(event) })
	case EventThreadApprovalResponseRequested:
		r.enqueueThread(event, func() { r.handleApprovalResponse(event) })
	}
}

func (r *ProviderEventReactor) handleSessionRelease(event Event) {
	ctx, cancel := r.providerRPCContext()
	defer cancel()
	if err := r.provider.ReleaseSession(ctx, provider.StopSessionInput{ThreadID: string(event.ThreadID())}); err != nil {
		log.Printf("orchestration: release previous provider session for thread %q: %v", event.ThreadID(), err)
	}
}

func (r *ProviderEventReactor) enqueueThread(event Event, fn func()) {
	threadID := event.ThreadID()
	if threadID == "" {
		go fn()
		return
	}
	r.mu.Lock()
	if r.threadTails == nil {
		r.threadTails = make(map[ThreadID]chan struct{})
	}
	prev := r.threadTails[threadID]
	done := make(chan struct{})
	r.threadTails[threadID] = done
	r.mu.Unlock()

	go func() {
		if prev != nil {
			<-prev
		}
		defer close(done)
		defer func() {
			r.mu.Lock()
			if r.threadTails[threadID] == done {
				delete(r.threadTails, threadID)
			}
			r.mu.Unlock()
		}()
		// A panicking handler must not kill the process or leave the thread's
		// tail chain broken.
		defer func() {
			if rec := recover(); rec != nil {
				log.Printf("orchestration: provider command reactor panicked on %s (thread %s): %v\n%s", event.Type, threadID, rec, debug.Stack())
			}
		}()
		fn()
	}()
}

func startSessionInputFromThread(thread Thread) provider.StartSessionInput {
	return provider.StartSessionInput{
		ThreadID:           string(thread.ID),
		ProviderInstanceID: thread.ProviderInstanceID,
		Cwd:                thread.Cwd,
		ModelSelection:     cloneModelSelection(thread.ModelSelection),
		ConfigSelections:   configSelectionsFromThread(thread),
	}
}

func configSelectionsFromThread(thread Thread) []provider.ConfigOptionSelection {
	if thread.Session == nil {
		return nil
	}
	var selections []provider.ConfigOptionSelection
	for _, option := range thread.Session.ConfigOptions {
		if option.ID == "" || option.Category == provider.ConfigOptionCategoryModel {
			continue
		}
		switch option.CurrentValue.(type) {
		case string, bool:
			selections = append(selections, provider.ConfigOptionSelection{
				OptionID: option.ID,
				Value:    option.CurrentValue,
				Category: option.Category,
			})
		}
	}
	return selections
}

func (r *ProviderEventReactor) handleSessionPrepare(event Event) {
	thread, ok := r.engine.Thread(event.ThreadID())
	if !ok {
		return
	}
	ctx, cancel := r.providerRPCContext()
	defer cancel()
	session, err := r.provider.StartSession(ctx, string(thread.ID), startSessionInputFromThread(thread))
	if err != nil {
		r.recordSessionUpdate(thread.ID, sessionUpdate{Kind: sessionUpdateError, Error: err.Error()})
		return
	}
	binding := bindingFromProviderSession(thread.ProviderInstanceID, session)
	if r.recordSessionUpdate(thread.ID, sessionUpdate{Kind: sessionUpdateBound, Binding: &binding}) {
		r.dispatchProviderSessionMetadata(thread.ID, session, time.Now())
	}
}

func (r *ProviderEventReactor) handleTurnStart(event Event) {
	threadID := event.ThreadID()
	turnID := event.Payload.TurnID
	thread, ok := r.engine.Thread(threadID)
	if !ok {
		return
	}
	if !turnStillRunning(thread, turnID) {
		if r.requeueSettledTurnStart(event, thread) {
			return
		}
		r.confirmInterruptBeforeTurnDispatch(threadID, turnID, nil)
		return
	}
	message := findMessage(thread, event.Payload.MessageID)
	if message.ID == "" {
		r.failThread(threadID, turnID, "turn start message not found")
		return
	}
	providerInstanceID := thread.ProviderInstanceID
	if providerInstanceID == "" {
		r.failThread(threadID, turnID, "thread has no provider instance")
		return
	}
	// Prebind: the engine derives a "starting" binding for the turn from the
	// live thread — or drops the update if the turn was interrupted first.
	if !r.recordSessionUpdate(threadID, sessionUpdate{Kind: sessionUpdateBound, TurnID: turnID}) {
		if current, ok := r.engine.Thread(threadID); ok && r.requeueSettledTurnStart(event, current) {
			return
		}
		r.confirmInterruptBeforeTurnDispatch(threadID, turnID, nil)
		return
	}
	ctx, cancel := r.providerRPCContext()
	defer cancel()

	providerSession, err := r.provider.StartSession(ctx, string(thread.ID), startSessionInputFromThread(thread))
	if err != nil {
		r.failThread(threadID, turnID, err.Error())
		return
	}
	// The engine accepts the running binding only while this turn is STILL
	// the thread's running turn; an interrupt that landed during StartSession
	// drops the update, and the interrupt is confirmed instead of dispatching.
	binding := bindingFromProviderSession(providerInstanceID, providerSession)
	if !r.recordSessionUpdate(threadID, sessionUpdate{Kind: sessionUpdateBound, Binding: &binding, TurnID: turnID}) {
		if current, ok := r.engine.Thread(threadID); ok && r.requeueSettledTurnStart(event, current) {
			return
		}
		r.confirmInterruptBeforeTurnDispatch(threadID, turnID, &binding)
		return
	}
	r.dispatchProviderSessionMetadata(threadID, providerSession, time.Now())

	// SendTurn is asynchronous: the adapter emits turn.started/turn.completed
	// (and all content) through runtime events, which ProviderRuntimeIngestion
	// records back as orchestration events. Only a synchronous dispatch
	// failure is handled here.
	sendCtx, sendCancel := r.providerRPCContext()
	defer sendCancel()
	if err := r.provider.SendTurn(sendCtx, provider.SendTurnInput{ThreadID: string(thread.ID), TurnID: string(turnID), Input: message.Text, Attachments: message.Attachments, ModelSelection: cloneModelSelection(thread.ModelSelection)}); err != nil {
		r.failThread(threadID, turnID, err.Error())
	}
}

// requeueSettledTurnStart closes the narrow steering race where the command was
// accepted while a turn was running, but that turn settled before its provider
// handler reached dispatch. The message is already in the projection, so a
// single replacement start event moves it onto a fresh turn; the per-thread
// reactor chain then handles that event normally. Interrupts are not requeued.
func (r *ProviderEventReactor) requeueSettledTurnStart(event Event, thread Thread) bool {
	turn := thread.LatestTurn
	if !event.Payload.Steering || turn == nil || turn.ID != event.Payload.TurnID || turn.CompletedAt == nil || turn.InterruptRequested {
		return false
	}
	if findMessage(thread, event.Payload.MessageID).ID == "" {
		return false
	}
	now := time.Now()
	result, err := r.engine.AppendEvent(context.Background(), EventInput{
		Type:       EventThreadTurnStartRequested,
		ThreadID:   thread.ID,
		Actor:      ActorKindServer,
		OccurredAt: now,
		Payload: EventPayload{
			MessageID: event.Payload.MessageID,
			TurnID:    TurnID(newID("turn")),
		},
	})
	if err != nil {
		log.Printf("orchestration: requeue settled turn start for thread %q: %v", thread.ID, err)
		return false
	}
	return result.Sequence != 0
}

// bindingFromProviderSession extracts the identity fields of a provider
// session for a bound update; status and turn fields are derived by
// the engine against the live thread.
func bindingFromProviderSession(providerInstanceID provider.InstanceID, session provider.Session) SessionBinding {
	if providerInstanceID == "" {
		providerInstanceID = session.ProviderInstanceID
	}
	return SessionBinding{ProviderInstanceID: providerInstanceID, ProviderGeneration: session.Generation, ProviderName: session.ProviderName, Provider: session.Provider, Cwd: session.Cwd, ConfigOptions: cloneConfigOptions(session.ConfigOptions)}
}

func (r *ProviderEventReactor) dispatchProviderSessionMetadata(threadID ThreadID, session provider.Session, createdAt time.Time) {
	if session.ConfigOptions != nil {
		r.record(EventInput{Type: EventThreadConfigOptionsUpdated, ThreadID: threadID, OccurredAt: createdAt, Payload: EventPayload{ConfigOptions: session.ConfigOptions}})
	}
}

// confirmInterruptBeforeTurnDispatch settles a turn whose interrupt won the
// race with session start/dispatch: it records the interrupt confirmation and
// returns the session to ready via a bound update (carrying the provider
// session identity when StartSession already returned one).
func (r *ProviderEventReactor) confirmInterruptBeforeTurnDispatch(threadID ThreadID, turnID TurnID, binding *SessionBinding) {
	view, ok := r.engine.SessionView(threadID)
	if !ok || view.LatestTurn == nil || view.LatestTurn.ID != turnID || !view.LatestTurn.InterruptRequested {
		return
	}
	r.record(EventInput{Type: EventThreadTurnInterruptConfirmed, ThreadID: threadID, Actor: ActorKindServer, OccurredAt: time.Now(), Payload: EventPayload{TurnID: turnID}})
	if binding != nil || view.Session != nil {
		r.recordSessionUpdate(threadID, sessionUpdate{Kind: sessionUpdateBound, Binding: binding})
	}
}

func (r *ProviderEventReactor) handleInterrupt(event Event) {
	thread, ok := r.engine.Thread(event.ThreadID())
	if !ok || thread.Session == nil || !interruptEventTargetsCancellableTurn(thread, event.Payload.TurnID) {
		return
	}
	// Do not settle session lifecycle from this async reactor. The interrupt
	// request already records the user's intent, and provider turn lifecycle
	// events remain authoritative if completion wins the race.
	ctx, cancel := r.providerRPCContext()
	defer cancel()
	if err := r.provider.InterruptTurn(ctx, provider.InterruptTurnInput{ThreadID: string(thread.ID), TurnID: string(event.Payload.TurnID)}); err != nil {
		r.record(EventInput{Type: EventThreadTurnInterruptFailed, ThreadID: thread.ID, Actor: ActorKindServer, Payload: EventPayload{TurnID: event.Payload.TurnID}})
		r.appendErrorItem(thread.ID, event.Payload.TurnID, err.Error())
	}
}

func (r *ProviderEventReactor) handleStop(event Event) {
	thread, ok := r.engine.Thread(event.ThreadID())
	if !ok || thread.Session == nil {
		return
	}
	stopReason := ""
	if activeTurnID(thread) != "" {
		stopReason = "cancelled"
	}
	ctx, cancel := r.providerRPCContext()
	defer cancel()
	if err := r.provider.StopSession(ctx, provider.StopSessionInput{ThreadID: string(thread.ID)}); err != nil {
		r.record(EventInput{Type: EventThreadSessionStopFailed, ThreadID: thread.ID, Actor: ActorKindServer})
		r.appendErrorItem(thread.ID, event.Payload.TurnID, err.Error())
		return
	}
	r.recordSessionUpdate(thread.ID, sessionUpdate{Kind: sessionUpdateStopped, StopReason: stopReason})
}

func (r *ProviderEventReactor) handleConfigOption(event Event) {
	thread, ok := r.engine.Thread(event.ThreadID())
	if !ok || thread.Session == nil {
		return
	}
	category := configOptionCategory(thread, event.Payload.OptionID)
	ctx, cancel := r.providerRPCContext()
	defer cancel()
	if err := r.provider.SetConfigOption(ctx, provider.SetConfigOptionInput{ThreadID: string(thread.ID), OptionID: event.Payload.OptionID, Value: event.Payload.Value, Category: category}); err != nil {
		r.appendErrorItem(thread.ID, "", err.Error())
	}
}

func configOptionCategory(thread Thread, optionID string) provider.ConfigOptionCategory {
	if thread.Session == nil {
		return ""
	}
	for _, option := range thread.Session.ConfigOptions {
		if option.ID == optionID {
			return option.Category
		}
	}
	return ""
}

func (r *ProviderEventReactor) handleApprovalResponse(event Event) {
	thread, ok := r.engine.Thread(event.ThreadID())
	if !ok || thread.Session == nil {
		return
	}
	approval, ok := findApproval(thread, event.Payload.RequestID)
	if !ok {
		r.appendErrorItem(thread.ID, event.Payload.TurnID, fmt.Sprintf("unknown approval request %s", event.Payload.RequestID))
		return
	}
	ctx, cancel := r.providerRPCContext()
	defer cancel()
	// The decision was validated (and defaulted) by the engine's decider before
	// the event was appended, so it passes through as-is.
	if err := r.provider.RespondToRequest(ctx, provider.RespondToRequestInput{ThreadID: string(thread.ID), RequestID: approval.RequestID, Decision: event.Payload.Decision, OptionID: event.Payload.OptionID}); err != nil {
		r.appendErrorItem(thread.ID, approval.TurnID, err.Error())
		return
	}
}

// failThread records both failure contracts: session state settles the turn,
// while the timeline item gives clients a human-readable error. The engine
// drops the session update when the named turn already settled.
func (r *ProviderEventReactor) failThread(threadID ThreadID, turnID TurnID, message string) {
	r.recordSessionUpdate(threadID, sessionUpdate{Kind: sessionUpdateError, TurnID: turnID, Error: message})
	r.appendErrorItem(threadID, turnID, message)
}

func (r *ProviderEventReactor) appendErrorItem(threadID ThreadID, turnID TurnID, message string) {
	now := time.Now()
	item := &Item{ID: newID("error"), Kind: provider.ItemKindError, Title: message, Status: provider.ItemStatusFailed, Payload: marshalEventPayload(map[string]any{"detail": message}), TurnID: turnID, CreatedAt: now, UpdatedAt: now}
	r.record(EventInput{Type: EventThreadItemUpserted, ThreadID: threadID, OccurredAt: now, Payload: EventPayload{Item: item}})
}

func (r *ProviderEventReactor) record(input EventInput) {
	_, _ = r.engine.AppendEvent(context.Background(), input)
}

// recordSessionUpdate reports whether the engine appended the derived update.
func (r *ProviderEventReactor) recordSessionUpdate(threadID ThreadID, update sessionUpdate) bool {
	update.threadID = threadID
	result, err := r.engine.updateSession(context.Background(), update)
	return err == nil && result.Sequence != 0
}

func interruptEventTargetsCancellableTurn(thread Thread, turnID TurnID) bool {
	if turnID == "" || thread.LatestTurn == nil || thread.LatestTurn.ID != turnID {
		return false
	}
	if thread.LatestTurn.CompletedAt != nil || thread.LatestTurn.State == TurnStateCompleted || thread.LatestTurn.State == TurnStateError {
		return false
	}
	if thread.Session != nil {
		switch thread.Session.Status {
		case SessionStatusReady, SessionStatusStopped, SessionStatusError:
			return false
		}
		if thread.Session.ActiveTurnID != "" && thread.Session.ActiveTurnID != turnID {
			return false
		}
	}
	return true
}

func findMessage(thread Thread, id MessageID) Message {
	if message := thread.Timeline.Message(id); message != nil {
		return *message
	}
	return Message{}
}

func findApproval(thread Thread, id ApprovalID) (Approval, bool) {
	if approval := thread.Timeline.Approval(string(id)); approval != nil {
		return *approval, true
	}
	return Approval{}, false
}
