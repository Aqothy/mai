package orchestration

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"runtime/debug"
	"sync"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

const engineQueueSize = 256

// Engine locking: the worker goroutine is the ONLY writer to the projection and
// receipts (except boot-time RestoreThreads, which seeds stubs under mu before
// any dispatch), so writes need no coordination with each other. mu exists for
// cross-goroutine readers (snapshots, SessionView) racing the worker's
// projection writes; the EventStore carries its own lock so Replay can serve
// reads without holding mu.
type Engine struct {
	mu             sync.Mutex
	store          *EventStore
	projection     *Projection
	listeners      map[uint64]func(Event)
	nextListenerID uint64
	receipts       map[CommandID]commandReceipt

	requestQueue chan engineRequest
	closed       chan struct{}
	closeOnce    sync.Once
	stopped      chan struct{}

	// defaultCwd is the daemon's working directory, captured at construction.
	// It is the fallback when thread.create carries no cwd.
	defaultCwd string

	// onInvariant, when set, is notified of an InvariantViolationError — a
	// panic that fired AFTER the event log began mutating, when store and
	// read model may disagree and there is no persistence to rebuild from.
	// The engine logs the violation and closes itself BEFORE notifying, so
	// the handler observes a terminal engine; the daemon's handler shuts the
	// whole server down and surfaces the error from RunWebSocket, leaving
	// process exit to main. Set it before the first dispatch.
	onInvariant func(*InvariantViolationError)
}

type commandReceipt struct {
	sequence uint64
	err      string
}

type engineRequest struct {
	command       Command
	eventInput    *EventInput
	sessionUpdate *sessionUpdate
	done          chan dispatchOutcome
}

// EventInput is the parameter of AppendEvent: the caller-supplied fields of an
// event, appended nearly verbatim (the store mints Sequence). It carries
// provider/server observations, which — unlike commands — are not client
// intents: they cannot be refused or retried (no receipt) and carry no client
// CommandID, so those fields deliberately do not exist here. Appends share the
// engine queue with commands so the event log stays totally ordered.
type EventInput struct {
	Type     EventType
	ThreadID ThreadID
	// Actor defaults to ActorKindProvider; server-derived events (session
	// status, assistant messages, confirmed interaction modes) set ActorKindServer.
	Actor      ActorKind
	OccurredAt time.Time
	Metadata   EventMetadata
	Payload    EventPayload
}

type dispatchOutcome struct {
	result DispatchResult
	err    error
}

func NewEngine() *Engine {
	defaultCwd, _ := os.Getwd()
	e := &Engine{
		store:        NewEventStore(),
		projection:   NewProjection(),
		listeners:    make(map[uint64]func(Event)),
		receipts:     make(map[CommandID]commandReceipt),
		requestQueue: make(chan engineRequest, engineQueueSize),
		closed:       make(chan struct{}),
		stopped:      make(chan struct{}),
		defaultCwd:   defaultCwd,
	}
	go e.worker()
	return e
}

// Close stops the command worker. Queued/in-flight dispatches unblock with an error.
func (e *Engine) Close() {
	e.closeOnce.Do(func() { close(e.closed) })
}

// Stopped closes after the worker exits.
func (e *Engine) Stopped() <-chan struct{} {
	return e.stopped
}

// worker is the single serial command processor. Event listeners also run on
// this goroutine and must hand off any engine work rather than awaiting it here.
func (e *Engine) worker() {
	var violation *InvariantViolationError
	defer func() {
		close(e.stopped)
		if violation == nil {
			return
		}
		e.mu.Lock()
		handler := e.onInvariant
		e.mu.Unlock()
		if handler != nil {
			handler(violation)
		}
	}()

	for {
		select {
		case <-e.closed:
			return
		case env := <-e.requestQueue:
			// Close is the worker's stop boundary. If shutdown raced with a queued
			// request, reject it rather than mutating state after Close returned to
			// another goroutine.
			select {
			case <-e.closed:
				env.done <- dispatchOutcome{err: fmt.Errorf("orchestration engine is closed")}
				return
			default:
			}
			var result DispatchResult
			var err error
			if env.sessionUpdate != nil {
				result, err = e.sessionUpdateRecovered(*env.sessionUpdate)
			} else if env.eventInput != nil {
				result, err = e.appendRecovered(*env.eventInput)
			} else {
				result, err = e.process(env.command)
			}
			env.done <- dispatchOutcome{result: result, err: err}
			// Escalate an invariant violation AFTER replying, so the in-flight
			// caller deterministically receives the typed error before the
			// engine closes and the handler (the daemon's shutdown) runs.
			if fatal, ok := errors.AsType[*InvariantViolationError](err); ok {
				e.Close()
				violation = fatal
				return
			}
		}
	}
}

func (e *Engine) OnEvent(listener func(Event)) func() {
	e.mu.Lock()
	e.nextListenerID++
	id := e.nextListenerID
	e.listeners[id] = listener
	e.mu.Unlock()
	return func() {
		e.mu.Lock()
		delete(e.listeners, id)
		e.mu.Unlock()
	}
}

// Dispatch enqueues a command for the serial worker and waits for its result.
// Concurrent callers are safe; an event listener on the worker must not call it
// synchronously because the queued request cannot run until the listener returns.
func (e *Engine) Dispatch(ctx context.Context, command Command) (DispatchResult, error) {
	if command.CommandID == "" {
		command.CommandID = CommandID(newID("cmd"))
	}
	if command.CreatedAt.IsZero() {
		command.CreatedAt = time.Now()
	}
	return e.await(ctx, engineRequest{command: command, done: make(chan dispatchOutcome, 1)})
}

// AppendEvent appends a provider/server-observed event through the worker
// queue. The event's thread must exist; beyond that the input is recorded,
// not decided — nothing retries it, so there is no receipt.
func (e *Engine) AppendEvent(ctx context.Context, input EventInput) (DispatchResult, error) {
	if input.OccurredAt.IsZero() {
		input.OccurredAt = time.Now()
	}
	return e.await(ctx, engineRequest{eventInput: &input, done: make(chan dispatchOutcome, 1)})
}

// updateSession serializes one internal session lifecycle update with commands
// and provider events. The worker derives the complete client-facing session
// binding from current thread state before appending the ordinary domain event.
func (e *Engine) updateSession(ctx context.Context, update sessionUpdate) (DispatchResult, error) {
	if update.occurredAt.IsZero() {
		update.occurredAt = time.Now()
	}
	return e.await(ctx, engineRequest{sessionUpdate: &update, done: make(chan dispatchOutcome, 1)})
}

func (e *Engine) await(ctx context.Context, env engineRequest) (DispatchResult, error) {
	select {
	case e.requestQueue <- env:
	case <-e.closed:
		return DispatchResult{}, fmt.Errorf("orchestration engine is closed")
	case <-ctx.Done():
		return DispatchResult{}, ctx.Err()
	}
	select {
	case outcome := <-env.done:
		return outcome.result, outcome.err
	case <-e.closed:
		// The worker publishes an invariant-violation outcome before closing
		// the engine. If both channels are ready, preserve that specific error
		// instead of nondeterministically returning the generic closed error.
		select {
		case outcome := <-env.done:
			return outcome.result, outcome.err
		default:
			return DispatchResult{}, fmt.Errorf("orchestration engine is closed")
		}
	case <-ctx.Done():
		return DispatchResult{}, ctx.Err()
	}
}

// process runs only on the worker goroutine, so the receipts map needs no extra
// locking. Receipts exist for client retry idempotency: every command is a
// client intent (provider/server events go through AppendEvent, receipt-free,
// so per-delta streaming traffic cannot grow this map).
// TODO: bound receipts (grows one entry per client command).
func (e *Engine) process(command Command) (DispatchResult, error) {
	if receipt, ok := e.receipts[command.CommandID]; ok {
		if receipt.err != "" {
			return DispatchResult{}, fmt.Errorf("command %q was previously rejected: %s", command.CommandID, receipt.err)
		}
		return DispatchResult{Sequence: receipt.sequence}, nil
	}
	result, err := e.dispatchRecovered(command)
	if err != nil {
		e.receipts[command.CommandID] = commandReceipt{err: err.Error()}
		return DispatchResult{}, err
	}
	e.receipts[command.CommandID] = commandReceipt{sequence: result.Sequence}
	return result, nil
}

// dispatchRecovered converts a pre-mutation (decider/validation) panic into a
// command error so one bad command cannot wedge the worker. Panics that fire
// after the event log began mutating arrive as InvariantViolationError because
// store and read model may now disagree.
func (e *Engine) dispatchRecovered(command Command) (DispatchResult, error) {
	return recoverEngineOperation(fmt.Sprintf("command %q", command.Type), func() (DispatchResult, error) {
		return e.dispatch(command)
	})
}

func (e *Engine) dispatch(command Command) (DispatchResult, error) {
	switch command.Type {
	case CommandThreadCreate:
		return e.dispatchThreadCreate(command)
	case CommandThreadMetaUpdate:
		return e.dispatchThreadMetaUpdate(command)
	case CommandThreadTurnStart:
		return e.dispatchThreadTurnStart(command)
	case CommandThreadTurnInterrupt:
		return e.dispatchThreadTurnInterrupt(command)
	case CommandThreadApprovalRespond:
		return e.dispatchApprovalRespond(command)
	case CommandThreadSessionPrepare:
		return e.dispatchSessionPrepare(command)
	case CommandThreadSessionStop:
		return e.dispatchSessionStop(command)
	case CommandThreadConfigOptionSet:
		return e.dispatchConfigOptionSet(command)
	default:
		return DispatchResult{}, fmt.Errorf("unsupported orchestration command %q", command.Type)
	}
}

// appendRecovered converts a pre-mutation (validation/derivation) panic into
// an error so one bad event cannot wedge the worker, mirroring
// dispatchRecovered. Post-mutation panics surface as InvariantViolationError
// and the worker escalates them instead.
func (e *Engine) appendRecovered(input EventInput) (DispatchResult, error) {
	return recoverEngineOperation(fmt.Sprintf("appending event %q", input.Type), func() (DispatchResult, error) {
		return e.appendInput(input)
	})
}

// recoverEngineOperation is the common panic boundary for work executed by the
// engine worker. withLockNotify has already classified post-mutation panics as
// invariant violations; all other panics are safe to report as operation
// errors because no event was appended.
func recoverEngineOperation(operation string, run func() (DispatchResult, error)) (result DispatchResult, err error) {
	defer func() {
		if rec := recover(); rec != nil {
			if violation, ok := rec.(*InvariantViolationError); ok {
				err = violation
				return
			}
			log.Printf("orchestration: %s panicked: %v\n%s", operation, rec, debug.Stack())
			err = fmt.Errorf("%s panicked: %v", operation, rec)
		}
	}()
	return run()
}

// appendInput appends a provider/server event against an existing thread. The
// only per-type logic is payload normalization/derivation that needs the live
// thread (config-option model selection); everything else is recorded verbatim.
func (e *Engine) appendInput(input EventInput) (DispatchResult, error) {
	if input.ThreadID == "" {
		return DispatchResult{}, fmt.Errorf("event %q requires threadId", input.Type)
	}
	if err := validateEventInput(input); err != nil {
		return DispatchResult{}, err
	}
	var sequence uint64
	err := e.withLockNotify(func(appendEvent func(Event) Event) error {
		thread := e.projection.liveThread(input.ThreadID)
		if thread == nil {
			return fmt.Errorf("thread %q not found", input.ThreadID)
		}
		payload := input.Payload
		payload.ThreadID = input.ThreadID
		switch input.Type {
		case EventThreadConfigOptionsUpdated:
			// An explicit empty update (non-nil []) must reach clients so they clear
			// state; a model config option also refreshes the thread's model selection.
			if payload.ConfigOptions == nil {
				payload.ConfigOptions = []provider.ConfigOption{}
			}
			payload.ModelSelection = modelSelectionFromConfigOptions(*thread, payload.ConfigOptions)
		case EventThreadSlashCommandsUpdated:
			if payload.SlashCommands == nil {
				payload.SlashCommands = []provider.SlashCommand{}
			}
		}
		actor := input.Actor
		if actor == "" {
			actor = ActorKindProvider
		}
		appended := appendEvent(Event{Type: input.Type, OccurredAt: input.OccurredAt, Actor: actor, Metadata: input.Metadata, Payload: payload})
		sequence = appended.Sequence
		return nil
	})
	if err != nil {
		return DispatchResult{}, err
	}
	return DispatchResult{Sequence: sequence}, nil
}

// validateEventInput guards provider-supplied payload sections that may arrive
// empty; payloads constructed entirely by internal callers are not rechecked.
func validateEventInput(input EventInput) error {
	switch input.Type {
	case EventThreadSessionStatusSet:
		if input.Payload.Session == nil || input.Payload.Session.Status == "" {
			return fmt.Errorf("%s requires session.status", input.Type)
		}
	case EventThreadItemUpserted:
		if input.Payload.Item == nil || input.Payload.Item.ID == "" {
			return fmt.Errorf("%s requires item with id", input.Type)
		}
	case EventThreadApprovalOpened, EventThreadApprovalResolved:
		if input.Payload.Approval == nil || input.Payload.Approval.RequestID == "" {
			return fmt.Errorf("%s requires approval with requestId", input.Type)
		}
	}
	return nil
}

func (e *Engine) ReplayEvents(input ReplayEventsInput) []Event {
	return e.store.Replay(input)
}

func (e *Engine) ThreadSnapshot(threadID ThreadID) (ThreadStreamItem, error) {
	e.mu.Lock()
	snapshot, err := e.projection.ThreadSnapshot(threadID)
	e.mu.Unlock()
	if err != nil {
		return ThreadStreamItem{}, err
	}
	return ThreadStreamItem{Kind: "snapshot", Snapshot: &snapshot}, nil
}

func (e *Engine) ThreadListSnapshot() ThreadListStreamItem {
	e.mu.Lock()
	snapshot := e.projection.ThreadListSnapshot()
	e.mu.Unlock()
	return ThreadListStreamItem{Kind: "snapshot", Snapshot: &snapshot}
}

func (e *Engine) ThreadListEntry(threadID ThreadID) (ThreadListEntry, bool) {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.projection.ThreadListEntry(threadID)
}

func (e *Engine) Thread(threadID ThreadID) (Thread, bool) {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.projection.Thread(threadID)
}

// ThreadSessionView is the cheap read for per-runtime-event consumers
// (ingestion): session binding, latest turn, and resolved provider routing —
// WITHOUT cloning the thread's messages/items/approvals. Thread() clones all of
// those, which is O(thread size) per call and must stay off the per-delta path.
type ThreadSessionView struct {
	// ProviderInstanceID is the thread's resolved routing identity
	// (model-selection instance wins over the thread-level field).
	ProviderInstanceID provider.InstanceID
	Session            *SessionBinding
	LatestTurn         *Turn
}

func (e *Engine) SessionView(threadID ThreadID) (ThreadSessionView, bool) {
	e.mu.Lock()
	defer e.mu.Unlock()
	thread := e.projection.liveThread(threadID)
	if thread == nil {
		return ThreadSessionView{}, false
	}
	return ThreadSessionView{
		ProviderInstanceID: thread.ProviderInstanceID,
		Session:            cloneSessionPtr(thread.Session),
		LatestTurn:         cloneTurnPtr(thread.LatestTurn),
	}, true
}

func (e *Engine) existingThreadSequence(threadID ThreadID) (uint64, bool) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.projection.liveThread(threadID) == nil {
		return 0, false
	}
	if sequence := e.projection.createSequence(threadID); sequence != 0 {
		return sequence, true
	}
	return e.projection.appliedSequence(), true
}

// resolveThreadCwd enforces the daemon-wide cwd rule in one place: a thread's
// cwd is client-supplied, defaults to the daemon's working directory when
// empty, and must name an existing directory as an absolute path. Validating
// here makes a bad cwd fail at thread.create/thread.update with an actionable
// error instead of surfacing deep inside a provider adapter on the first turn.
func (e *Engine) resolveThreadCwd(commandType string, cwd string) (string, error) {
	if cwd == "" {
		cwd = e.defaultCwd
		if cwd == "" {
			return "", fmt.Errorf("%s requires cwd (the daemon has no working directory to default to)", commandType)
		}
	}
	if !filepath.IsAbs(cwd) {
		return "", fmt.Errorf("%s cwd %q must be an absolute path", commandType, cwd)
	}
	info, err := os.Stat(cwd)
	if err != nil {
		return "", fmt.Errorf("%s cwd %q is not usable: %v", commandType, cwd, err)
	}
	if !info.IsDir() {
		return "", fmt.Errorf("%s cwd %q is not a directory", commandType, cwd)
	}
	return cwd, nil
}

func (e *Engine) dispatchThreadCreate(command Command) (DispatchResult, error) {
	if command.ThreadID == "" {
		return DispatchResult{}, fmt.Errorf("thread.create requires threadId")
	}
	if sequence, exists := e.existingThreadSequence(command.ThreadID); exists {
		return DispatchResult{Sequence: sequence}, nil
	}
	title := command.Title
	if title == "" {
		title = "Untitled thread"
	}
	cwd, err := e.resolveThreadCwd(command.Type, command.Cwd)
	if err != nil {
		return DispatchResult{}, err
	}
	appended := e.append(Event{Type: EventThreadCreated, OccurredAt: command.CreatedAt, CommandID: command.CommandID, Actor: ActorKindClient, Payload: EventPayload{ThreadID: command.ThreadID, Title: title, ProviderInstanceID: command.ProviderInstanceID, ModelSelection: cloneModelSelection(command.ModelSelection), Cwd: cwd}})
	return DispatchResult{Sequence: appended.Sequence}, nil
}

func (e *Engine) dispatchThreadMetaUpdate(command Command) (DispatchResult, error) {
	if command.Cwd != "" {
		if _, err := e.resolveThreadCwd(command.Type, command.Cwd); err != nil {
			return DispatchResult{}, err
		}
	}
	return e.dispatchWithThread(command, func(thread *Thread) (Event, error) {
		if err := validateMetaCwdChange(*thread, command.Cwd); err != nil {
			return Event{}, err
		}
		selectionChange := resolveProviderSelectionChange(*thread, command.ProviderInstanceID, command.ModelSelection)
		if err := selectionChange.validateMetaUpdate(*thread); err != nil {
			return Event{}, err
		}
		return threadEvent(command, EventThreadMetaUpdated, ActorKindClient, EventPayload{Title: command.Title, ProviderInstanceID: selectionChange.ProviderInstanceID, ModelSelection: selectionChange.ModelSelection, Cwd: command.Cwd, SessionCleared: selectionChange.ClearsSession}), nil
	})
}

func (e *Engine) dispatchThreadTurnStart(command Command) (DispatchResult, error) {
	if command.ThreadID == "" {
		return DispatchResult{}, fmt.Errorf("thread.turn.start requires threadId")
	}
	if err := validateTurnStartBoundary(command); err != nil {
		return DispatchResult{}, err
	}
	if command.Message == nil || (command.Message.Text == "" && len(command.Message.Attachments) == 0) {
		return DispatchResult{}, fmt.Errorf("thread.turn.start requires message.text or message.attachments")
	}
	if err := validateGenericAttachments(command.Type, command.Message.Attachments); err != nil {
		return DispatchResult{}, err
	}
	messageID := MessageID(command.Message.MessageID)
	if messageID == "" {
		messageID = MessageID(newID("msg"))
	}

	var sequence uint64
	err := e.withLockNotify(func(appendEvent func(Event) Event) error {
		thread, ok := e.projection.Thread(command.ThreadID)
		if !ok {
			return fmt.Errorf("thread %q not found", command.ThreadID)
		}
		if sessionPreparing(thread) {
			return fmt.Errorf("cannot start a turn while thread %q is preparing its provider session", command.ThreadID)
		}
		active := activeTurnID(thread)
		steering := active != ""
		turnID := active
		if turnID == "" {
			turnID = TurnID(newID("turn"))
		}
		selectionChange := resolveProviderSelectionChange(thread, command.ProviderInstanceID, command.ModelSelection)
		if steering {
			if err := selectionChange.validateSteering(thread); err != nil {
				return err
			}
			selectionChange = providerSelectionChange{}
		}
		appendEvent(Event{Type: EventThreadMessageSent, OccurredAt: command.CreatedAt, CommandID: command.CommandID, Actor: ActorKindClient, Payload: EventPayload{ThreadID: command.ThreadID, MessageID: messageID, Role: MessageRoleUser, Text: command.Message.Text, Attachments: command.Message.Attachments, TurnID: turnID, CreatedAt: command.CreatedAt, UpdatedAt: command.CreatedAt}})
		turnEvent := appendEvent(Event{Type: EventThreadTurnStartRequested, OccurredAt: command.CreatedAt, CommandID: command.CommandID, Actor: ActorKindClient, Payload: EventPayload{ThreadID: command.ThreadID, MessageID: messageID, TurnID: turnID, Steering: steering, ProviderInstanceID: selectionChange.ProviderInstanceID, ModelSelection: selectionChange.ModelSelection, SessionCleared: selectionChange.ClearsSession}})
		sequence = turnEvent.Sequence
		return nil
	})
	if err != nil {
		return DispatchResult{}, err
	}
	return DispatchResult{Sequence: sequence}, nil
}

func (e *Engine) dispatchApprovalRespond(command Command) (DispatchResult, error) {
	if command.ThreadID == "" || command.RequestID == "" {
		return DispatchResult{}, fmt.Errorf("thread.approval.respond requires threadId and requestId")
	}
	decision := command.Decision
	if decision == "" {
		decision = provider.ApprovalDecisionCancel
	}
	if err := validateApprovalDecision(command.Type, decision); err != nil {
		return DispatchResult{}, err
	}
	return e.dispatchWithThread(command, func(thread *Thread) (Event, error) {
		if err := validateApprovalResponse(command.Type, *thread, command.RequestID, command.OptionID); err != nil {
			return Event{}, err
		}
		event := threadEvent(command, EventThreadApprovalResponseRequested, ActorKindClient, EventPayload{RequestID: command.RequestID, Decision: decision, OptionID: command.OptionID})
		event.Metadata = EventMetadata{RequestID: string(command.RequestID)}
		return event, nil
	})
}

func (e *Engine) dispatchThreadTurnInterrupt(command Command) (DispatchResult, error) {
	return e.dispatchWithThread(command, func(thread *Thread) (Event, error) {
		turnID := command.TurnID
		active := activeTurnID(*thread)
		if active == "" {
			return Event{}, fmt.Errorf("thread %q has no active turn to interrupt", command.ThreadID)
		}
		if turnID != "" && turnID != active {
			return Event{}, fmt.Errorf("turn %q is not the active turn for thread %q", turnID, command.ThreadID)
		}
		if turnID == "" {
			turnID = active
		}
		return threadEvent(command, EventThreadTurnInterruptRequested, ActorKindClient, EventPayload{TurnID: turnID}), nil
	})
}

func (e *Engine) dispatchSessionPrepare(command Command) (DispatchResult, error) {
	return e.dispatchWithThread(command, func(thread *Thread) (Event, error) {
		if thread.ProviderInstanceID == "" {
			return Event{}, fmt.Errorf("thread %q has no provider instance", command.ThreadID)
		}
		if activeTurnID(*thread) != "" {
			return Event{}, fmt.Errorf("cannot prepare session while thread %q has an active turn", command.ThreadID)
		}
		if sessionPreparing(*thread) {
			return Event{}, fmt.Errorf("thread %q is already preparing its provider session", command.ThreadID)
		}
		return threadEvent(command, EventThreadSessionPrepareRequested, ActorKindClient, EventPayload{}), nil
	})
}

func (e *Engine) dispatchSessionStop(command Command) (DispatchResult, error) {
	return e.dispatchWithThread(command, func(thread *Thread) (Event, error) {
		if sessionPreparing(*thread) {
			return Event{}, fmt.Errorf("cannot stop thread %q while its provider session is preparing", command.ThreadID)
		}
		return threadEvent(command, EventThreadSessionStopRequested, ActorKindClient, EventPayload{TurnID: command.TurnID}), nil
	})
}

// dispatchWithThread is the shared decider shape for commands that validate
// against (or derive event payload from) the current state of an existing
// thread: build runs under the projection lock against the live thread and
// returns the single event to append; the appended event is published to
// listeners before returning. build must only read the thread.
func (e *Engine) dispatchWithThread(command Command, build func(thread *Thread) (Event, error)) (DispatchResult, error) {
	if command.ThreadID == "" {
		return DispatchResult{}, fmt.Errorf("%s requires threadId", command.Type)
	}
	var sequence uint64
	err := e.withLockNotify(func(appendEvent func(Event) Event) error {
		thread := e.projection.liveThread(command.ThreadID)
		if thread == nil {
			return fmt.Errorf("thread %q not found", command.ThreadID)
		}
		event, err := build(thread)
		if err != nil {
			return err
		}
		sequence = appendEvent(event).Sequence
		return nil
	})
	if err != nil {
		return DispatchResult{}, err
	}
	return DispatchResult{Sequence: sequence}, nil
}

func threadEvent(command Command, eventType EventType, actor ActorKind, payload EventPayload) Event {
	payload.ThreadID = command.ThreadID
	return Event{Type: eventType, OccurredAt: command.CreatedAt, CommandID: command.CommandID, Actor: actor, Payload: payload}
}

func (e *Engine) dispatchConfigOptionSet(command Command) (DispatchResult, error) {
	if command.OptionID == "" {
		return DispatchResult{}, fmt.Errorf("thread.config-option.set requires optionId")
	}
	return e.dispatchWithThread(command, func(thread *Thread) (Event, error) {
		if !providerSessionActive(thread.Session) {
			return Event{}, fmt.Errorf("thread.config-option.set requires an active provider session")
		}
		return threadEvent(command, EventThreadConfigOptionSetRequested, ActorKindClient, EventPayload{OptionID: command.OptionID, Value: command.Value}), nil
	})
}

func (e *Engine) append(event Event) Event {
	var appended Event
	_ = e.withLockNotify(func(appendEvent func(Event) Event) error {
		appended = appendEvent(event)
		return nil
	})
	return appended
}

// testApplyHook, when non-nil (tests only), runs inside the locked apply path
// after an event is stored and applied. It exists so tests can inject a panic
// into a region that holds e.mu; it is nil in production.
var testApplyHook func(Event)

// InvariantViolationError is the terminal error the engine reports when a
// panic fires after the event log began mutating: store and read model may
// disagree, and with no persistence to rebuild from the engine cannot
// continue — it closes itself. The process owner (main) decides how to exit;
// the engine and server never call os.Exit themselves.
type InvariantViolationError struct {
	Cause any
	Stack []byte
}

func (e *InvariantViolationError) Error() string {
	return fmt.Sprintf("orchestration invariant violation: panic after the event log began mutating (in-memory state is unrecoverable): %v", e.Cause)
}

// OnInvariantViolation installs the handler notified after the engine has
// logged an invariant violation and closed itself (see Engine.onInvariant).
func (e *Engine) OnInvariantViolation(fn func(*InvariantViolationError)) {
	e.mu.Lock()
	e.onInvariant = fn
	e.mu.Unlock()
}

// withLockNotify runs fn while holding e.mu and hands it the only way to
// append: appendEvent stores the event, applies it to the projection, and
// records it for notification. The deferred handlers split panics into two
// classes:
//   - BEFORE the first append (decider/validation code): the mutex is
//     released, nothing was written, and the panic propagates to
//     dispatchRecovered/appendRecovered, which convert it into a command
//     error — one bad command cannot wedge the daemon.
//   - AFTER mutation began (store.Append/projection.Apply): the mutex is
//     released, everything committed to the store is still published, and a
//     typed invariant violation tells the worker to close the engine.
//
// Listeners run outside the lock but synchronously on the worker. A listener
// that needs engine work must hand it to another goroutine; awaiting a queued
// request here would deadlock the worker.
func (e *Engine) withLockNotify(fn func(appendEvent func(Event) Event) error) error {
	var appended []Event
	mutated := false
	defer func() {
		rec := recover()
		if rec == nil {
			return
		}
		if mutated {
			// Re-panic as the TYPED violation: dispatchRecovered/appendRecovered
			// return it as the in-flight command's error, and the worker — after
			// replying to that caller — closes the engine and notifies the
			// invariant handler (deterministic ordering; see worker()).
			violation := &InvariantViolationError{Cause: rec, Stack: debug.Stack()}
			log.Printf("%v\n%s", violation, violation.Stack)
			panic(violation)
		}
		panic(rec) // pre-mutation: nothing was written; upstream converts this into a command error
	}()
	defer func() {
		if len(appended) == 0 {
			return
		}
		e.mu.Lock()
		listeners := e.listenersLocked()
		e.mu.Unlock()
		for _, event := range appended {
			e.notify(listeners, event)
		}
	}()
	e.mu.Lock()
	defer e.mu.Unlock()
	return fn(func(event Event) Event {
		mutated = true
		stored := e.store.Append(event)
		appended = append(appended, stored)
		e.projection.Apply(stored)
		if hook := testApplyHook; hook != nil {
			hook(stored)
		}
		return stored
	})
}

func (e *Engine) listenersLocked() []func(Event) {
	listeners := make([]func(Event), 0, len(e.listeners))
	for _, listener := range e.listeners {
		listeners = append(listeners, listener)
	}
	return listeners
}

// notify runs listeners on the worker goroutine; a panicking listener must not
// take the worker (and all future dispatches) down with it.
func (e *Engine) notify(listeners []func(Event), event Event) {
	for _, listener := range listeners {
		e.notifyOne(listener, event)
	}
}

func (e *Engine) notifyOne(listener func(Event), event Event) {
	defer func() {
		if rec := recover(); rec != nil {
			log.Printf("orchestration: event listener panicked on %q: %v\n%s", event.Type, rec, debug.Stack())
		}
	}()
	listener(event)
}

func newID(prefix string) string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	buf := make([]byte, len(prefix)+1+36)
	copy(buf, prefix)
	buf[len(prefix)] = '_'
	offset := len(prefix) + 1
	hex.Encode(buf[offset:offset+8], b[0:4])
	buf[offset+8] = '-'
	hex.Encode(buf[offset+9:offset+13], b[4:6])
	buf[offset+13] = '-'
	hex.Encode(buf[offset+14:offset+18], b[6:8])
	buf[offset+18] = '-'
	hex.Encode(buf[offset+19:offset+23], b[8:10])
	buf[offset+23] = '-'
	hex.Encode(buf[offset+24:offset+36], b[10:16])
	return string(buf)
}
