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
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

const (
	engineQueueSize = 256
)

// Engine locking: the worker goroutine is the ONLY writer to the projection,
// the sequence, and receipts (except boot-time RestoreThreads, which seeds
// stubs under mu before any dispatch), so writes need no coordination with each
// other. mu exists for cross-goroutine readers (snapshots, SessionView) racing
// the worker's projection writes. Snapshot creation holds mu while reading the
// projection.
type Engine struct {
	mu             sync.Mutex
	nextSequence   uint64
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
	// panic that fired AFTER live state began mutating, when the sequence and
	// read model may disagree and there is no complete process state to rebuild.
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
	command        Command
	eventInput     *EventInput
	sessionUpdate  *sessionUpdate
	importedThread *RestoredThread
	done           chan dispatchOutcome
}

// EventInput is the parameter of AppendEvent: the caller-supplied fields of an
// event, appended nearly verbatim (the engine mints Sequence). It carries
// provider/server observations, which — unlike commands — are not client
// intents: they cannot be refused or retried (no receipt) and carry no client
// CommandID, so those fields deliberately do not exist here. Appends share the
// engine queue with commands so live events stay totally ordered.
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
			} else if env.importedThread != nil {
				result, err = e.importThreadRecovered(*env.importedThread)
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
// after live state began mutating arrive as InvariantViolationError because
// the sequence and read model may now disagree.
func (e *Engine) dispatchRecovered(command Command) (DispatchResult, error) {
	return recoverEngineOperation(fmt.Sprintf("command %q", command.Type), func() (DispatchResult, error) {
		return e.dispatch(command)
	})
}

func (e *Engine) dispatch(command Command) (DispatchResult, error) {
	switch command.Type {
	case CommandThreadCreate:
		return e.dispatchThreadCreate(command)
	case CommandThreadStart:
		return e.dispatchThreadStart(command)
	case CommandThreadMetaUpdate:
		return e.dispatchThreadMetaUpdate(command)
	case CommandThreadTurnStart:
		return e.dispatchThreadTurnStart(command)
	case CommandThreadTurnRetry:
		return e.dispatchThreadTurnRetry(command)
	case CommandThreadTurnInterrupt:
		return e.dispatchThreadTurnInterrupt(command)
	case CommandThreadItemStop:
		return e.dispatchThreadItemStop(command)
	case CommandThreadPromptSend:
		return e.dispatchThreadPromptSend(command)
	case CommandThreadPromptRemove:
		return e.dispatchThreadPromptRemove(command)
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

// SubscribeThread returns an authoritative snapshot. The RPC layer installs
// the live subscription before calling this, so events at the captured
// boundary can be duplicated but can never be lost.
func (e *Engine) SubscribeThread(input SubscribeThreadInput) (ThreadStreamItem, error) {
	e.mu.Lock()
	defer e.mu.Unlock()

	if e.projection.liveThread(input.ThreadID) == nil {
		return ThreadStreamItem{}, fmt.Errorf("thread %q not found", input.ThreadID)
	}
	snapshot, err := e.projection.ThreadSnapshot(input.ThreadID)
	if err != nil {
		return ThreadStreamItem{}, err
	}
	return ThreadStreamItem{Kind: StreamItemSnapshot, Snapshot: &snapshot}, nil
}

// GetItemDetail returns one complete canonical item without exposing or
// replaying the event history that produced it.
func (e *Engine) GetItemDetail(input GetItemDetailInput) (Item, error) {
	e.mu.Lock()
	defer e.mu.Unlock()

	thread := e.projection.liveThread(input.ThreadID)
	if thread == nil {
		return Item{}, fmt.Errorf("thread %q not found", input.ThreadID)
	}
	item := thread.Timeline.Item(input.ItemID)
	if item == nil {
		return Item{}, fmt.Errorf("item %q not found in thread %q", input.ItemID, input.ThreadID)
	}
	return cloneItem(*item), nil
}

// Attachment returns one message attachment with its data, which thread
// snapshots and events leave out.
func (e *Engine) Attachment(input GetAttachmentInput) (provider.Attachment, error) {
	e.mu.Lock()
	defer e.mu.Unlock()

	thread := e.projection.liveThread(input.ThreadID)
	if thread == nil {
		return provider.Attachment{}, fmt.Errorf("thread %q not found", input.ThreadID)
	}
	matches := func(attachment provider.Attachment) bool { return attachment.ID == input.AttachmentID }
	for _, entry := range thread.Timeline {
		if entry.Message == nil {
			continue
		}
		if index := slices.IndexFunc(entry.Message.Attachments, matches); index >= 0 {
			return cloneAttachments(entry.Message.Attachments[index : index+1])[0], nil
		}
	}
	for _, prompt := range thread.QueuedPrompts {
		if index := slices.IndexFunc(prompt.Attachments, matches); index >= 0 {
			return cloneAttachments(prompt.Attachments[index : index+1])[0], nil
		}
	}
	return provider.Attachment{}, fmt.Errorf("attachment %q not found in thread %q", input.AttachmentID, input.ThreadID)
}

func (e *Engine) ThreadListSnapshot() ThreadListStreamItem {
	e.mu.Lock()
	snapshot := e.projection.ThreadListSnapshot()
	e.mu.Unlock()
	return ThreadListStreamItem{Kind: StreamItemSnapshot, Snapshot: &snapshot}
}

// ProviderTurnRunning reports whether a turn is running on any thread of the
// provider instance.
func (e *Engine) ProviderTurnRunning(instanceID provider.InstanceID) bool {
	snapshot := e.ThreadListSnapshot().Snapshot
	return slices.ContainsFunc(snapshot.Threads, func(entry ThreadListEntry) bool {
		return entry.ProviderInstanceID == instanceID && activeTurnIDOf(entry.Session, entry.LatestTurn) != ""
	})
}

func (e *Engine) ThreadListEntry(threadID ThreadID) (ThreadListEntry, bool) {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.projection.ThreadListEntry(threadID)
}

// ThreadHistoryRestorePending reports whether the thread is still the
// metadata-only stub (or is currently rebuilding that stub from provider
// history). It is intentionally a clone-free query for notification fan-out.
func (e *Engine) ThreadHistoryRestorePending(threadID ThreadID) bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	thread := e.projection.liveThread(threadID)
	return thread != nil && thread.ReplayHistoryPending
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

// ThreadProviderView is the bounded state needed to start or resume provider
// work. It deliberately excludes the timeline except for the addressed prompt,
// avoiding an O(thread size) clone on every session/turn start.
type ThreadProviderView struct {
	ID                    ThreadID
	ReplayHistoryPending  bool
	ProviderInstanceID    provider.InstanceID
	Cwd                   string
	AdditionalDirectories []string
	ModelSelection        *provider.ModelSelection
	ConfigSelections      []provider.ConfigOptionSelection
	Session               *SessionBinding
	LatestTurn            *Turn
	Message               *Message
	// Handoff is the conversation a fork still has to hand the session, in
	// front of Message.
	Handoff *ForkHandoff
}

// ThreadApprovalView is SessionView plus one approval, read under a single lock
// acquisition: composing two reads could answer a request against a session
// that has since been replaced.
type ThreadApprovalView struct {
	Session *SessionBinding
	// Approval is nil when the thread has no such request.
	Approval *Approval
}

func (e *Engine) ApprovalView(threadID ThreadID, requestID ApprovalID) (ThreadApprovalView, bool) {
	e.mu.Lock()
	defer e.mu.Unlock()
	thread := e.projection.liveThread(threadID)
	if thread == nil {
		return ThreadApprovalView{}, false
	}
	view := ThreadApprovalView{Session: cloneSessionPtr(thread.Session)}
	if approval := thread.Timeline.Approval(string(requestID)); approval != nil {
		clone := *approval
		clone.Args = cloneRawMessage(approval.Args)
		view.Approval = &clone
	}
	return view, true
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

// ThreadCwd returns the thread's workspace directory. It is a bounded read
// for per-keystroke consumers (workspace file search): no timeline clone.
func (e *Engine) ThreadCwd(threadID ThreadID) (string, bool) {
	e.mu.Lock()
	defer e.mu.Unlock()
	thread := e.projection.liveThread(threadID)
	if thread == nil {
		return "", false
	}
	return thread.Cwd, true
}

func (e *Engine) ProviderView(threadID ThreadID, messageID MessageID) (ThreadProviderView, bool) {
	e.mu.Lock()
	defer e.mu.Unlock()
	thread := e.projection.liveThread(threadID)
	if thread == nil {
		return ThreadProviderView{}, false
	}
	view := ThreadProviderView{
		ID:                    thread.ID,
		ReplayHistoryPending:  thread.ReplayHistoryPending,
		ProviderInstanceID:    thread.ProviderInstanceID,
		Cwd:                   thread.Cwd,
		AdditionalDirectories: append([]string(nil), thread.AdditionalDirectories...),
		ModelSelection:        cloneModelSelection(thread.ModelSelection),
		ConfigSelections:      append([]provider.ConfigOptionSelection(nil), thread.ConfigSelections...),
		Session:               cloneSessionPtr(thread.Session),
		LatestTurn:            cloneTurnPtr(thread.LatestTurn),
	}
	if messageID == "" {
		return view, true
	}
	if message := thread.Timeline.Message(messageID); message != nil {
		clone := *message
		clone.Attachments = cloneAttachments(message.Attachments)
		clone.Annotations = append([]provider.PromptAnnotation(nil), message.Annotations...)
		view.Message = &clone
		view.Handoff = forkHandoff(*thread)
	}
	return view, true
}

func (e *Engine) existingThreadSequence(threadID ThreadID) (uint64, bool) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.projection.liveThread(threadID) == nil {
		return 0, false
	}
	if sequence := e.projection.createSequences[threadID]; sequence != 0 {
		return sequence, true
	}
	return e.projection.sequence, true
}

// ResolveThreadCwd applies the engine's cwd default and validation policy to
// thread state installed outside the command path, such as imported sessions.
func (e *Engine) ResolveThreadCwd(cwd string) (string, error) {
	return e.resolveThreadCwd("thread import", cwd)
}

// ResolveAdditionalDirectories validates and normalizes the ordered workspace
// roots that accompany a thread's primary cwd. Duplicate roots and the primary
// cwd are removed while preserving the caller's order.
func (e *Engine) ResolveAdditionalDirectories(directories []string, cwd string) ([]string, error) {
	return e.resolveAdditionalDirectories("thread import", directories, cwd)
}

func (e *Engine) resolveAdditionalDirectories(commandType string, directories []string, cwd string) ([]string, error) {
	if directories == nil {
		return nil, nil
	}
	seen := map[string]struct{}{filepath.Clean(cwd): {}}
	resolved := make([]string, 0, len(directories))
	for _, directory := range directories {
		if directory == "" {
			continue
		}
		root, err := e.resolveThreadCwd(commandType+" additional directory", directory)
		if err != nil {
			return nil, err
		}
		root = filepath.Clean(root)
		if _, ok := seen[root]; ok {
			continue
		}
		seen[root] = struct{}{}
		resolved = append(resolved, root)
	}
	return resolved, nil
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
	additionalDirectories, err := e.resolveAdditionalDirectories(command.Type, command.AdditionalDirectories, cwd)
	if err != nil {
		return DispatchResult{}, err
	}
	appended := e.append(Event{Type: EventThreadCreated, OccurredAt: command.CreatedAt, CommandID: command.CommandID, Actor: ActorKindClient, Payload: EventPayload{ThreadID: command.ThreadID, Title: title, ProviderInstanceID: command.ProviderInstanceID, ModelSelection: cloneModelSelection(command.ModelSelection), Cwd: cwd, AdditionalDirectories: additionalDirectories}})
	return DispatchResult{Sequence: appended.Sequence}, nil
}

// dispatchThreadStart creates a real thread and records its first user message
// and turn request in one locked operation. The provider work remains
// asynchronous in ProviderEventReactor, exactly like every later turn.
func (e *Engine) dispatchThreadStart(command Command) (DispatchResult, error) {
	if command.ThreadID == "" {
		return DispatchResult{}, fmt.Errorf("thread.start requires threadId")
	}
	if sequence, exists := e.existingThreadSequence(command.ThreadID); exists {
		return DispatchResult{Sequence: sequence}, nil
	}
	if command.ProviderInstanceID == "" {
		return DispatchResult{}, fmt.Errorf("thread.start requires providerInstanceId")
	}
	if err := validateCommandMessage(command.Type, command.Message); err != nil {
		return DispatchResult{}, err
	}
	cwd, err := e.resolveThreadCwd(command.Type, command.Cwd)
	if err != nil {
		return DispatchResult{}, err
	}
	additionalDirectories, err := e.resolveAdditionalDirectories(command.Type, command.AdditionalDirectories, cwd)
	if err != nil {
		return DispatchResult{}, err
	}
	messageID := MessageID(command.Message.MessageID)
	if messageID == "" {
		messageID = MessageID(newID("msg"))
	}
	title := command.Title
	if title == "" {
		title = strings.Join(strings.Fields(command.Message.Text), " ")
		titleRunes := []rune(title)
		if len(titleRunes) > 80 {
			title = string(titleRunes[:80])
		}
		if title == "" {
			title = "Untitled thread"
		}
	}
	modelSelection := cloneModelSelection(command.ModelSelection)
	for _, selection := range command.ConfigSelections {
		if selection.Category == provider.ConfigOptionCategoryModel {
			if model, ok := selection.Value.(string); ok && model != "" {
				if modelSelection == nil {
					modelSelection = &provider.ModelSelection{}
				}
				modelSelection.Model = model
			}
		}
	}

	var sequence uint64
	err = e.withLockNotify(func(appendEvent func(Event) Event) error {
		appendEvent(Event{Type: EventThreadCreated, OccurredAt: command.CreatedAt, CommandID: command.CommandID, Actor: ActorKindClient, Payload: EventPayload{
			ThreadID: command.ThreadID, Title: title, ProviderInstanceID: command.ProviderInstanceID,
			ModelSelection: modelSelection, Cwd: cwd, AdditionalDirectories: additionalDirectories, ConfigSelections: append([]provider.ConfigOptionSelection(nil), command.ConfigSelections...),
		}})
		if command.ForkContext != "" {
			appendEvent(threadEvent(command, EventThreadItemUpserted, ActorKindClient, EventPayload{Item: forkContextItem(messageID, command.ForkContext)}))
		}
		started := appendPromptTurn(appendEvent, threadEvent(command, "", ActorKindClient, EventPayload{}), commandPrompt(command, messageID), EventPayload{
			ProviderInstanceID: command.ProviderInstanceID, ModelSelection: modelSelection,
			ConfigSelections: append([]provider.ConfigOptionSelection(nil), command.ConfigSelections...),
		})
		sequence = started.Sequence
		return nil
	})
	if err != nil {
		return DispatchResult{}, err
	}
	return DispatchResult{Sequence: sequence}, nil
}

func (e *Engine) dispatchThreadMetaUpdate(command Command) (DispatchResult, error) {
	var additionalDirectories []string
	if command.Cwd != "" {
		if _, err := e.resolveThreadCwd(command.Type, command.Cwd); err != nil {
			return DispatchResult{}, err
		}
	}
	if command.AdditionalDirectories != nil {
		cwd := command.Cwd
		if cwd == "" {
			cwd, _ = e.ThreadCwd(command.ThreadID)
		}
		var err error
		additionalDirectories, err = e.resolveAdditionalDirectories(command.Type, command.AdditionalDirectories, cwd)
		if err != nil {
			return DispatchResult{}, err
		}
	}
	return e.dispatchWithThread(command, func(thread *Thread) (Event, error) {
		changesAdditionalDirectories := command.AdditionalDirectories != nil
		// Changing the primary root can turn one of the existing additional
		// roots into a duplicate. Normalize the retained roots against the new
		// cwd and publish that patch even when the client omitted the optional
		// additionalDirectories field.
		if command.Cwd != "" && command.Cwd != thread.Cwd && !changesAdditionalDirectories {
			var err error
			additionalDirectories, err = e.resolveAdditionalDirectories(command.Type, thread.AdditionalDirectories, command.Cwd)
			if err != nil {
				return Event{}, err
			}
			changesAdditionalDirectories = true
		}
		if err := validateMetaDirectoriesChange(*thread, command.Cwd, additionalDirectories, changesAdditionalDirectories); err != nil {
			return Event{}, err
		}
		selectionChange := resolveProviderSelectionChange(*thread, command.ProviderInstanceID, command.ModelSelection)
		if err := selectionChange.validateMetaUpdate(*thread); err != nil {
			return Event{}, err
		}
		return threadEvent(command, EventThreadMetaUpdated, ActorKindClient, EventPayload{Title: command.Title, ProviderInstanceID: selectionChange.ProviderInstanceID, ModelSelection: selectionChange.ModelSelection, Cwd: command.Cwd, AdditionalDirectories: additionalDirectories, SessionCleared: selectionChange.ClearsSession}), nil
	})
}

// dispatchThreadTurnStart sends the prompt as the next turn, or queues it
// when the thread is busy: a turn is running or stopping, the session is
// preparing, or earlier prompts are still waiting. A steer sends it now
// where it can (see Command.Steer).
func (e *Engine) dispatchThreadTurnStart(command Command) (DispatchResult, error) {
	if command.ThreadID == "" {
		return DispatchResult{}, fmt.Errorf("thread.turn.start requires threadId")
	}
	if err := validateTurnStartBoundary(command); err != nil {
		return DispatchResult{}, err
	}
	if err := validateCommandMessage(command.Type, command.Message); err != nil {
		return DispatchResult{}, err
	}
	messageID := MessageID(command.Message.MessageID)
	if messageID == "" {
		messageID = MessageID(newID("msg"))
	}

	var sequence uint64
	err := e.withLockNotify(func(appendEvent func(Event) Event) error {
		thread := e.projection.liveThread(command.ThreadID)
		if thread == nil {
			return fmt.Errorf("thread %q not found", command.ThreadID)
		}
		if thread.ReplayHistoryPending && !sessionPreparing(*thread) {
			return fmt.Errorf("cannot start a turn on restored thread %q before preparing its provider session", command.ThreadID)
		}
		if thread.Timeline.Message(messageID) != nil || thread.queuedPrompt(messageID) != nil {
			return fmt.Errorf("message %q was already sent to thread %q", messageID, command.ThreadID)
		}
		selectionChange := resolveProviderSelectionChange(*thread, command.ProviderInstanceID, command.ModelSelection)
		prompt := commandPrompt(command, messageID)
		header := threadEvent(command, "", ActorKindClient, EventPayload{})
		if canStartTurn(*thread) && (len(thread.QueuedPrompts) == 0 || command.Steer) {
			sequence = appendPromptTurn(appendEvent, header, prompt, EventPayload{ProviderInstanceID: selectionChange.ProviderInstanceID, ModelSelection: selectionChange.ModelSelection, SessionCleared: selectionChange.ClearsSession}).Sequence
			return nil
		}
		// A queued or steered prompt goes with the thread's selection.
		if selectionChange.specified && selectionChange.changes(*thread) {
			return fmt.Errorf("cannot change provider/model selection while thread %q is busy", command.ThreadID)
		}
		if command.Steer {
			if turnID, err := steerableTurn(*thread); err == nil {
				sequence = appendPromptSteer(appendEvent, header, prompt, turnID).Sequence
				return nil
			}
		}
		header.Type = EventThreadPromptQueued
		header.Payload = EventPayload{ThreadID: command.ThreadID, MessageID: prompt.MessageID, Text: prompt.Text, Attachments: prompt.Attachments, Annotations: prompt.Annotations, CreatedAt: prompt.CreatedAt}
		sequence = appendEvent(header).Sequence
		return nil
	})
	if err != nil {
		return DispatchResult{}, err
	}
	return DispatchResult{Sequence: sequence}, nil
}

// dispatchThreadPromptSend sends a queued prompt now: as the next turn when
// the thread is idle, or steered into the running turn.
func (e *Engine) dispatchThreadPromptSend(command Command) (DispatchResult, error) {
	return e.dispatchMessageCommand(command, func(thread *Thread, appendEvent func(Event) Event) (Event, error) {
		queued := thread.queuedPrompt(command.MessageID)
		if queued == nil {
			return Event{}, fmt.Errorf("prompt %q is not queued on thread %q", command.MessageID, command.ThreadID)
		}
		// A copy: sending removes the prompt from the queue it points into.
		prompt := *queued
		header := threadEvent(command, "", ActorKindClient, EventPayload{})
		if canStartTurn(*thread) {
			return appendPromptTurn(appendEvent, header, prompt, EventPayload{}), nil
		}
		turnID, err := steerableTurn(*thread)
		if err != nil {
			return Event{}, err
		}
		return appendPromptSteer(appendEvent, header, prompt, turnID), nil
	})
}

func (e *Engine) dispatchThreadPromptRemove(command Command) (DispatchResult, error) {
	return e.dispatchWithThread(command, func(thread *Thread) (Event, error) {
		if thread.queuedPrompt(command.MessageID) == nil {
			return Event{}, fmt.Errorf("prompt %q is not queued on thread %q", command.MessageID, command.ThreadID)
		}
		return threadEvent(command, EventThreadPromptRemoved, ActorKindClient, EventPayload{MessageID: command.MessageID}), nil
	})
}

// steerableTurn returns the running turn a message can join.
func steerableTurn(thread Thread) (TurnID, error) {
	turnID := activeTurnID(thread)
	if turnID == "" {
		return "", fmt.Errorf("thread %q has no running turn", thread.ID)
	}
	if (thread.LatestTurn != nil && thread.LatestTurn.InterruptRequested) || (thread.Session != nil && thread.Session.StopRequested) {
		return "", fmt.Errorf("the running turn of thread %q is stopping", thread.ID)
	}
	return turnID, nil
}

// dispatchMessageCommand runs build against the live thread; build appends its
// events and returns the last one, whose sequence is the receipt.
func (e *Engine) dispatchMessageCommand(command Command, build func(thread *Thread, appendEvent func(Event) Event) (Event, error)) (DispatchResult, error) {
	if command.ThreadID == "" || command.MessageID == "" {
		return DispatchResult{}, fmt.Errorf("%s requires threadId and messageId", command.Type)
	}
	var sequence uint64
	err := e.withLockNotify(func(appendEvent func(Event) Event) error {
		thread := e.projection.liveThread(command.ThreadID)
		if thread == nil {
			return fmt.Errorf("thread %q not found", command.ThreadID)
		}
		last, err := build(thread, appendEvent)
		sequence = last.Sequence
		return err
	})
	if err != nil {
		return DispatchResult{}, err
	}
	return DispatchResult{Sequence: sequence}, nil
}

func commandPrompt(command Command, messageID MessageID) QueuedPrompt {
	return QueuedPrompt{MessageID: messageID, Text: command.Message.Text, Attachments: command.Message.Attachments, Annotations: command.Message.Annotations, CreatedAt: command.CreatedAt}
}

// appendPromptTurn records prompt as the user message of a new turn. header
// carries the shared event origin; start is the turn start's payload.
func appendPromptTurn(appendEvent func(Event) Event, header Event, prompt QueuedPrompt, start EventPayload) Event {
	threadID := header.Payload.ThreadID
	turnID := TurnID(newID("turn"))
	message := header
	message.Type = EventThreadMessageSent
	message.Payload = EventPayload{ThreadID: threadID, MessageID: prompt.MessageID, Role: MessageRoleUser, Text: prompt.Text, Attachments: prompt.Attachments, Annotations: prompt.Annotations, TurnID: turnID, CreatedAt: prompt.CreatedAt, UpdatedAt: prompt.CreatedAt}
	appendEvent(message)
	turn := header
	turn.Type = EventThreadTurnStartRequested
	start.ThreadID, start.MessageID, start.TurnID = threadID, prompt.MessageID, turnID
	turn.Payload = start
	return appendEvent(turn)
}

// appendPromptSteer records prompt as a user message of the running turn
// turnID and asks the provider to steer it in.
func appendPromptSteer(appendEvent func(Event) Event, header Event, prompt QueuedPrompt, turnID TurnID) Event {
	message := header
	message.Type = EventThreadMessageSent
	message.Payload = EventPayload{ThreadID: header.Payload.ThreadID, MessageID: prompt.MessageID, Role: MessageRoleUser, Text: prompt.Text, Attachments: prompt.Attachments, Annotations: prompt.Annotations, TurnID: turnID, CreatedAt: prompt.CreatedAt, UpdatedAt: prompt.CreatedAt}
	appendEvent(message)
	steer := header
	steer.Type = EventThreadMessageSteerRequested
	steer.Payload = EventPayload{ThreadID: header.Payload.ThreadID, MessageID: prompt.MessageID, TurnID: turnID}
	return appendEvent(steer)
}

// startNextTurnLocked is the one rule that starts a turn on its own. Every
// write ends here, so a thread that can take a turn never keeps a message
// waiting: a steer that missed its turn goes first, like a message sent just
// now; then the first queued prompt, unless a stop or failure holds the queue.
func (e *Engine) startNextTurnLocked(appended []Event, appendEvent func(Event) Event) {
	var threadIDs []ThreadID
	for _, event := range appended {
		if !slices.Contains(threadIDs, event.ThreadID()) {
			threadIDs = append(threadIDs, event.ThreadID())
		}
	}
	for _, threadID := range threadIDs {
		thread := e.projection.liveThread(threadID)
		if thread == nil || !canStartTurn(*thread) {
			continue
		}
		header := Event{OccurredAt: appended[len(appended)-1].OccurredAt, Actor: ActorKindServer, Payload: EventPayload{ThreadID: threadID}}
		switch {
		case len(thread.MissedSteers) > 0:
			start := header
			start.Type = EventThreadTurnStartRequested
			start.Payload.MessageID, start.Payload.TurnID = thread.MissedSteers[0], TurnID(newID("turn"))
			appendEvent(start)
		case len(thread.QueuedPrompts) > 0 && !thread.QueueHeld:
			appendPromptTurn(appendEvent, header, thread.QueuedPrompts[0], EventPayload{})
		}
	}
}

// dispatchThreadTurnRetry sends a message again: one that was not delivered,
// or the prompt of a failed turn. The same message is sent, never a copy: as
// a new turn when the thread is idle, or steered into the running turn.
func (e *Engine) dispatchThreadTurnRetry(command Command) (DispatchResult, error) {
	return e.dispatchMessageCommand(command, func(thread *Thread, appendEvent func(Event) Event) (Event, error) {
		message := thread.Timeline.Message(command.MessageID)
		if message == nil || message.Role != MessageRoleUser {
			return Event{}, fmt.Errorf("message %q is not a user message of thread %q", command.MessageID, command.ThreadID)
		}
		failedTurn := thread.LatestTurn != nil && thread.LatestTurn.State == TurnStateError && thread.LatestTurn.ID == message.TurnID
		if message.Delivery != MessageNotDelivered && !failedTurn {
			return Event{}, fmt.Errorf("message %q has not failed", command.MessageID)
		}
		if canStartTurn(*thread) {
			return appendEvent(threadEvent(command, EventThreadTurnStartRequested, ActorKindClient, EventPayload{MessageID: message.ID, TurnID: TurnID(newID("turn"))})), nil
		}
		turnID, err := steerableTurn(*thread)
		if err != nil {
			return Event{}, err
		}
		return appendEvent(threadEvent(command, EventThreadMessageSteerRequested, ActorKindClient, EventPayload{MessageID: message.ID, TurnID: turnID})), nil
	})
}

func (e *Engine) dispatchApprovalRespond(command Command) (DispatchResult, error) {
	if command.ThreadID == "" || command.RequestID == "" || command.ActionID == "" {
		return DispatchResult{}, fmt.Errorf("thread.approval.respond requires threadId, requestId and actionId")
	}
	return e.dispatchWithThread(command, func(thread *Thread) (Event, error) {
		action, err := validateApprovalResponse(command.Type, *thread, command.RequestID, command.ActionID, command.Answers)
		if err != nil {
			return Event{}, err
		}
		event := threadEvent(command, EventThreadApprovalResponseRequested, ActorKindClient, EventPayload{RequestID: command.RequestID, ActionID: action.ID, Decision: action.Decision, Answers: command.Answers})
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

// dispatchThreadItemStop accepts a stop only for a running item its provider
// marked Background, the items it can stop.
func (e *Engine) dispatchThreadItemStop(command Command) (DispatchResult, error) {
	return e.dispatchWithThread(command, func(thread *Thread) (Event, error) {
		item := thread.Timeline.Item(command.ItemID)
		if item == nil || item.ToolCall == nil || !item.ToolCall.Background || item.Status != provider.ItemStatusInProgress {
			return Event{}, fmt.Errorf("item %q is not a running background task in thread %q", command.ItemID, command.ThreadID)
		}
		return threadEvent(command, EventThreadItemStopRequested, ActorKindClient, EventPayload{ItemID: command.ItemID}), nil
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
// panic fires after live state began mutating: the sequence and read model may
// disagree, and with no complete process state to rebuild the engine cannot
// continue — it closes itself. The process owner (main) decides how to exit;
// the engine and server never call os.Exit themselves.
type InvariantViolationError struct {
	Cause any
	Stack []byte
}

func (e *InvariantViolationError) Error() string {
	return fmt.Sprintf("orchestration invariant violation: panic after live state began mutating (in-memory state is unrecoverable): %v", e.Cause)
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
//   - AFTER mutation began (stamp/projection.Apply): the mutex is
//     released, every completed event is still published, and a typed
//     invariant violation tells the worker to close the engine.
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
	appendEvent := func(event Event) Event {
		mutated = true
		sequenced := normalizeEvent(e.stamp(event))
		appended = append(appended, sequenced)
		e.projection.Apply(sequenced)
		if hook := testApplyHook; hook != nil {
			hook(sequenced)
		}
		return sequenced
	}
	err := fn(appendEvent)
	if len(appended) > 0 {
		e.startNextTurnLocked(appended, appendEvent)
	}
	return err
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
