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
	StartSession(ctx context.Context, threadID string, input provider.StartSessionInput) (provider.StartSessionResult, error)
	SendTurn(ctx context.Context, input provider.SendTurnInput) error
	InterruptTurn(ctx context.Context, input provider.InterruptTurnInput) error
	SetConfigOption(ctx context.Context, input provider.SetConfigOptionInput) error
	StopSession(ctx context.Context, input provider.StopSessionInput) error
	ReleaseSession(ctx context.Context, input provider.StopSessionInput) error
	RespondToRequest(ctx context.Context, input provider.RespondToRequestInput) error
}

const defaultProviderRPCTimeout = 60 * time.Second

type ProviderEventReactor struct {
	engine    *Engine
	provider  ProviderRuntime
	ingestion *ProviderRuntimeIngestion

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
func NewProviderEventReactor(ctx context.Context, engine *Engine, providerRuntime ProviderRuntime, ingestion *ProviderRuntimeIngestion) *ProviderEventReactor {
	if ctx == nil {
		ctx = context.Background()
	}
	r := &ProviderEventReactor{engine: engine, provider: providerRuntime, ingestion: ingestion, baseCtx: ctx, providerRPCTimeout: defaultProviderRPCTimeout, threadTails: make(map[ThreadID]chan struct{})}
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

func startSessionInputFromProviderView(view ThreadProviderView) provider.StartSessionInput {
	return provider.StartSessionInput{
		ThreadID:           string(view.ID),
		ProviderInstanceID: view.ProviderInstanceID,
		Cwd:                view.Cwd,
		ModelSelection:     cloneModelSelection(view.ModelSelection),
		ConfigSelections:   configSelectionsFromProviderView(view),
	}
}

func configSelectionsFromProviderView(view ThreadProviderView) []provider.ConfigOptionSelection {
	// ProviderView already detached this slice from the mutable projection, so
	// it is safe to consume and amend directly for this provider request.
	selections := view.ConfigSelections
	indices := make(map[string]int, len(selections))
	for index, selection := range selections {
		if selection.OptionID != "" {
			indices[selection.OptionID] = index
		}
	}
	if view.Session == nil {
		return selections
	}
	for _, option := range view.Session.ConfigOptions {
		if option.ID == "" || option.Category == provider.ConfigOptionCategoryModel {
			continue
		}
		switch option.CurrentValue.(type) {
		case string, bool:
			selection := provider.ConfigOptionSelection{
				OptionID: option.ID,
				Value:    option.CurrentValue,
				Category: option.Category,
			}
			if index, ok := indices[option.ID]; ok {
				selections[index] = selection
			} else {
				indices[option.ID] = len(selections)
				selections = append(selections, selection)
			}
		}
	}
	return selections
}

func (r *ProviderEventReactor) handleSessionPrepare(event Event) {
	view, ok := r.engine.ProviderView(event.ThreadID(), "")
	if !ok {
		return
	}
	ctx, cancel := r.providerRPCContext()
	defer cancel()
	input := startSessionInputFromProviderView(view)
	input.ReplayHistory = view.ReplayHistoryPending
	start := func() (provider.StartSessionResult, error) {
		return r.provider.StartSession(ctx, string(view.ID), input)
	}
	ready := func(session provider.Session) {
		binding := bindingFromProviderSession(view.ProviderInstanceID, session)
		if r.recordSessionUpdate(view.ID, sessionUpdate{Kind: sessionUpdateBound, Binding: &binding}) {
			r.dispatchProviderSessionMetadata(view.ID, session, time.Now())
		}
	}
	var err error
	if input.ReplayHistory {
		err = r.ingestion.RestoreHistory(string(view.ID), start, ready)
	} else {
		var result provider.StartSessionResult
		result, err = start()
		if err == nil {
			ready(result.Session)
		}
	}
	if err != nil {
		r.recordSessionUpdate(view.ID, sessionUpdate{
			Kind:                sessionUpdateError,
			Error:               err.Error(),
			historyReplayFailed: input.ReplayHistory,
		})
	}
}

func (r *ProviderEventReactor) handleTurnStart(event Event) {
	threadID := event.ThreadID()
	turnID := event.Payload.TurnID
	view, ok := r.engine.ProviderView(threadID, event.Payload.MessageID)
	if !ok {
		return
	}
	if !providerTurnStillRunning(view, turnID) {
		if r.requeueSettledTurnStart(event, view) {
			return
		}
		r.confirmInterruptBeforeTurnDispatch(threadID, turnID, nil)
		return
	}
	if view.Message == nil {
		r.failThread(threadID, turnID, "turn start message not found")
		return
	}
	providerInstanceID := view.ProviderInstanceID
	if providerInstanceID == "" {
		r.failThread(threadID, turnID, "thread has no provider instance")
		return
	}
	// Prebind: the engine derives a "starting" binding for the turn from the
	// live thread — or drops the update if the turn was interrupted first.
	if !r.recordSessionUpdate(threadID, sessionUpdate{Kind: sessionUpdateBound, TurnID: turnID}) {
		if current, ok := r.engine.ProviderView(threadID, event.Payload.MessageID); ok && r.requeueSettledTurnStart(event, current) {
			return
		}
		r.confirmInterruptBeforeTurnDispatch(threadID, turnID, nil)
		return
	}
	ctx, cancel := r.providerRPCContext()
	defer cancel()

	result, err := r.provider.StartSession(ctx, string(view.ID), startSessionInputFromProviderView(view))
	if err != nil {
		r.failThread(threadID, turnID, err.Error())
		return
	}
	providerSession := result.Session
	// The engine accepts the running binding only while this turn is STILL
	// the thread's running turn; an interrupt that landed during StartSession
	// drops the update, and the interrupt is confirmed instead of dispatching.
	binding := bindingFromProviderSession(providerInstanceID, providerSession)
	if !r.recordSessionUpdate(threadID, sessionUpdate{Kind: sessionUpdateBound, Binding: &binding, TurnID: turnID}) {
		if current, ok := r.engine.ProviderView(threadID, event.Payload.MessageID); ok && r.requeueSettledTurnStart(event, current) {
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
	if err := r.provider.SendTurn(sendCtx, provider.SendTurnInput{ThreadID: string(view.ID), TurnID: string(turnID), Input: view.Message.Text, Attachments: view.Message.Attachments, ModelSelection: cloneModelSelection(view.ModelSelection)}); err != nil {
		r.failThread(threadID, turnID, err.Error())
	}
}

// requeueSettledTurnStart closes the narrow steering race where the command was
// accepted while a turn was running, but that turn settled before its provider
// handler reached dispatch. The message is already in the projection, so a
// single replacement start event moves it onto a fresh turn; the per-thread
// reactor chain then handles that event normally. Interrupts are not requeued.
func (r *ProviderEventReactor) requeueSettledTurnStart(event Event, view ThreadProviderView) bool {
	turn := view.LatestTurn
	if !event.Payload.Steering || turn == nil || turn.ID != event.Payload.TurnID || turn.CompletedAt == nil || turn.InterruptRequested {
		return false
	}
	if view.Message == nil {
		return false
	}
	now := time.Now()
	result, err := r.engine.AppendEvent(context.Background(), EventInput{
		Type:       EventThreadTurnStartRequested,
		ThreadID:   view.ID,
		Actor:      ActorKindServer,
		OccurredAt: now,
		Payload: EventPayload{
			MessageID: event.Payload.MessageID,
			TurnID:    TurnID(newID("turn")),
		},
	})
	if err != nil {
		log.Printf("orchestration: requeue settled turn start for thread %q: %v", view.ID, err)
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
	return SessionBinding{ProviderInstanceID: providerInstanceID, ProviderGeneration: session.Generation, ProviderName: session.ProviderName, Driver: session.Provider, Cwd: session.Cwd, ConfigOptions: cloneConfigOptions(session.ConfigOptions)}
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

// The handlers below read through SessionView/ApprovalView rather than
// Engine.Thread, which deep-clones the whole timeline per provider RPC.
func (r *ProviderEventReactor) handleInterrupt(event Event) {
	threadID := event.ThreadID()
	view, ok := r.engine.SessionView(threadID)
	if !ok || view.Session == nil || !interruptEventTargetsCancellableTurn(view, event.Payload.TurnID) {
		return
	}
	// Do not settle session lifecycle from this async reactor. The interrupt
	// request already records the user's intent, and provider turn lifecycle
	// events remain authoritative if completion wins the race.
	ctx, cancel := r.providerRPCContext()
	defer cancel()
	if err := r.provider.InterruptTurn(ctx, provider.InterruptTurnInput{ThreadID: string(threadID), TurnID: string(event.Payload.TurnID)}); err != nil {
		r.record(EventInput{Type: EventThreadTurnInterruptFailed, ThreadID: threadID, Actor: ActorKindServer, Payload: EventPayload{TurnID: event.Payload.TurnID}})
		r.appendErrorItem(threadID, event.Payload.TurnID, err.Error())
	}
}

func (r *ProviderEventReactor) handleStop(event Event) {
	threadID := event.ThreadID()
	view, ok := r.engine.SessionView(threadID)
	if !ok {
		return
	}
	ctx, cancel := r.providerRPCContext()
	defer cancel()
	input := provider.StopSessionInput{ThreadID: string(threadID)}
	if view.Session == nil {
		if err := r.provider.ReleaseSession(ctx, input); err != nil {
			log.Printf("orchestration: release stopped idle thread %q: %v", threadID, err)
		}
		return
	}
	stopReason := ""
	if activeTurnIDOf(view.Session, view.LatestTurn) != "" {
		stopReason = "cancelled"
	}
	if err := r.provider.StopSession(ctx, input); err != nil {
		r.record(EventInput{Type: EventThreadSessionStopFailed, ThreadID: threadID, Actor: ActorKindServer})
		r.appendErrorItem(threadID, event.Payload.TurnID, err.Error())
		return
	}
	r.recordSessionUpdate(threadID, sessionUpdate{Kind: sessionUpdateStopped, StopReason: stopReason})
}

func (r *ProviderEventReactor) handleConfigOption(event Event) {
	threadID := event.ThreadID()
	view, ok := r.engine.SessionView(threadID)
	if !ok || view.Session == nil {
		return
	}
	category := configOptionCategory(view.Session, event.Payload.OptionID)
	ctx, cancel := r.providerRPCContext()
	defer cancel()
	if err := r.provider.SetConfigOption(ctx, provider.SetConfigOptionInput{ThreadID: string(threadID), OptionID: event.Payload.OptionID, Value: event.Payload.Value, Category: category}); err != nil {
		r.appendErrorItem(threadID, "", err.Error())
	}
}

func configOptionCategory(session *SessionBinding, optionID string) provider.ConfigOptionCategory {
	if session == nil {
		return ""
	}
	for _, option := range session.ConfigOptions {
		if option.ID == optionID {
			return option.Category
		}
	}
	return ""
}

func (r *ProviderEventReactor) handleApprovalResponse(event Event) {
	threadID := event.ThreadID()
	view, ok := r.engine.ApprovalView(threadID, event.Payload.RequestID)
	if !ok || view.Session == nil {
		return
	}
	if view.Approval == nil {
		r.appendErrorItem(threadID, event.Payload.TurnID, fmt.Sprintf("unknown approval request %s", event.Payload.RequestID))
		return
	}
	ctx, cancel := r.providerRPCContext()
	defer cancel()
	// The decision was validated (and defaulted) by the engine's decider before
	// the event was appended, so it passes through as-is.
	if err := r.provider.RespondToRequest(ctx, provider.RespondToRequestInput{ThreadID: string(threadID), RequestID: view.Approval.RequestID, Decision: event.Payload.Decision, OptionID: event.Payload.OptionID}); err != nil {
		r.appendErrorItem(threadID, view.Approval.TurnID, err.Error())
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

func interruptEventTargetsCancellableTurn(view ThreadSessionView, turnID TurnID) bool {
	if turnID == "" || view.LatestTurn == nil || view.LatestTurn.ID != turnID {
		return false
	}
	if view.LatestTurn.CompletedAt != nil || view.LatestTurn.State == TurnStateCompleted || view.LatestTurn.State == TurnStateError {
		return false
	}
	if view.Session != nil {
		switch view.Session.Status {
		case SessionStatusReady, SessionStatusStopped, SessionStatusError:
			return false
		}
		if view.Session.ActiveTurnID != "" && view.Session.ActiveTurnID != turnID {
			return false
		}
	}
	return true
}

func providerTurnStillRunning(view ThreadProviderView, turnID TurnID) bool {
	if turnID == "" {
		return true
	}
	if view.LatestTurn != nil && view.LatestTurn.ID == turnID {
		return view.LatestTurn.State == TurnStateRunning && !view.LatestTurn.InterruptRequested
	}
	return view.Session != nil && view.Session.ActiveTurnID == turnID && view.Session.Status == SessionStatusRunning
}
