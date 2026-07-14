package orchestration

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

type fakeProviderRuntime struct {
	mu               sync.Mutex
	configSetCalls   int
	configSetInputs  []provider.SetConfigOptionInput
	configSetSignal  chan struct{}
	startInputs      []provider.StartSessionInput
	startSession     provider.Session
	startErr         error
	sendInputs       []provider.SendTurnInput
	interruptCalls   int
	interruptSignal  chan struct{}
	interruptErr     error
	stopCalls        int
	releaseCalls     int
	stopSignal       chan struct{}
	stopErr          error
	startEntered     chan struct{}
	startRelease     chan struct{}
	configSetEntered chan struct{}
	configSetRelease chan struct{}
	sendSignal       chan struct{}
}

func newFakeProviderRuntime() *fakeProviderRuntime {
	return &fakeProviderRuntime{configSetSignal: make(chan struct{}, 4), interruptSignal: make(chan struct{}, 4), stopSignal: make(chan struct{}, 4), sendSignal: make(chan struct{}, 4)}
}

func (f *fakeProviderRuntime) StartSession(ctx context.Context, _ string, input provider.StartSessionInput) (provider.Session, error) {
	f.mu.Lock()
	f.startInputs = append(f.startInputs, input)
	session := f.startSession
	startErr := f.startErr
	entered := f.startEntered
	release := f.startRelease
	f.mu.Unlock()
	if startErr != nil {
		return provider.Session{}, startErr
	}
	if entered != nil {
		select {
		case entered <- struct{}{}:
		default:
		}
	}
	if release != nil {
		select {
		case <-release:
		case <-ctx.Done():
			return provider.Session{}, ctx.Err()
		}
	}
	if session.ProviderInstanceID == "" {
		session.ProviderInstanceID = "codex"
	}
	return session, nil
}
func (f *fakeProviderRuntime) SendTurn(_ context.Context, input provider.SendTurnInput) error {
	f.mu.Lock()
	f.sendInputs = append(f.sendInputs, input)
	f.mu.Unlock()
	select {
	case f.sendSignal <- struct{}{}:
	default:
	}
	return nil
}
func (f *fakeProviderRuntime) InterruptTurn(context.Context, provider.InterruptTurnInput) error {
	f.mu.Lock()
	f.interruptCalls++
	err := f.interruptErr
	f.mu.Unlock()
	select {
	case f.interruptSignal <- struct{}{}:
	default:
	}
	return err
}
func (f *fakeProviderRuntime) SetConfigOption(ctx context.Context, input provider.SetConfigOptionInput) error {
	if _, ok := ctx.Deadline(); !ok {
		return context.Canceled
	}
	f.mu.Lock()
	f.configSetCalls++
	f.configSetInputs = append(f.configSetInputs, input)
	entered := f.configSetEntered
	release := f.configSetRelease
	f.mu.Unlock()
	if entered != nil {
		select {
		case entered <- struct{}{}:
		default:
		}
	}
	if release != nil {
		select {
		case <-release:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	select {
	case f.configSetSignal <- struct{}{}:
	default:
	}
	return nil
}
func (f *fakeProviderRuntime) StopSession(context.Context, provider.StopSessionInput) error {
	f.mu.Lock()
	f.stopCalls++
	err := f.stopErr
	f.mu.Unlock()
	select {
	case f.stopSignal <- struct{}{}:
	default:
	}
	return err
}
func (f *fakeProviderRuntime) ReleaseSession(context.Context, provider.StopSessionInput) error {
	f.mu.Lock()
	f.releaseCalls++
	err := f.stopErr
	f.mu.Unlock()
	select {
	case f.stopSignal <- struct{}{}:
	default:
	}
	return err
}
func (f *fakeProviderRuntime) RespondToRequest(context.Context, provider.RespondToRequestInput) error {
	return nil
}

func (f *fakeProviderRuntime) interruptCallCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.interruptCalls
}

func (f *fakeProviderRuntime) releaseCallCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.releaseCalls
}

func (f *fakeProviderRuntime) lastStartInput() provider.StartSessionInput {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.startInputs) == 0 {
		return provider.StartSessionInput{}
	}
	return f.startInputs[len(f.startInputs)-1]
}

func (f *fakeProviderRuntime) startCalls() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.startInputs)
}

func (f *fakeProviderRuntime) lastSendInput() provider.SendTurnInput {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.sendInputs) == 0 {
		return provider.SendTurnInput{}
	}
	return f.sendInputs[len(f.sendInputs)-1]
}

func (f *fakeProviderRuntime) sendCalls() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.sendInputs)
}

func setupConfigOptionThread(t *testing.T, engine *Engine) ThreadID {
	t.Helper()
	threadID := ThreadID("thread-model")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "create-model", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	binding := &SessionBinding{ThreadID: threadID, ProviderInstanceID: "codex", Status: SessionStatusReady}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: binding}}); err != nil {
		t.Fatalf("thread.session.status.set: %v", err)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadConfigOptionsUpdated, ThreadID: threadID, Payload: EventPayload{ConfigOptions: []provider.ConfigOption{{ID: "model", Category: provider.ConfigOptionCategoryModel, CurrentValue: "fast"}, {ID: "temperature", Category: provider.ConfigOptionCategoryOther, CurrentValue: "0"}}}}); err != nil {
		t.Fatalf("thread.config-options.update: %v", err)
	}
	return threadID
}

func TestReactorPreparesSessionBeforeFirstTurn(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	fake := newFakeProviderRuntime()
	fake.startSession = provider.Session{ProviderInstanceID: "codex", ConfigOptions: []provider.ConfigOption{{ID: "model", Category: provider.ConfigOptionCategoryModel, CurrentValue: "fast"}}}
	reactor := &ProviderEventReactor{engine: engine, provider: fake, providerRPCTimeout: time.Second}
	threadID := ThreadID("thread-prepare")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "create-prepare", ThreadID: threadID, ProviderInstanceID: "codex", ModelSelection: &provider.ModelSelection{Model: "fast"}}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	result, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadSessionPrepare, CommandID: "prepare", ThreadID: threadID})
	if err != nil {
		t.Fatalf("thread.session.prepare: %v", err)
	}
	reactor.handleSessionPrepare(Event{Type: EventThreadSessionPrepareRequested, Sequence: result.Sequence, Payload: EventPayload{ThreadID: threadID}})

	thread, _ := engine.Thread(threadID)
	if fake.startCalls() != 1 {
		t.Fatalf("start calls = %d, want 1", fake.startCalls())
	}
	if input := fake.lastStartInput(); input.ThreadID != string(threadID) || input.ModelSelection == nil || input.ModelSelection.Model != "fast" {
		t.Fatalf("start input = %#v", input)
	}
	if thread.Session == nil || thread.Session.Status != SessionStatusReady || len(thread.Session.ConfigOptions) != 1 {
		t.Fatalf("prepared session = %#v", thread.Session)
	}
	if thread.LatestTurn != nil || len(thread.Timeline) != 0 {
		t.Fatalf("preparation created conversation content: turn=%#v timeline=%#v", thread.LatestTurn, thread.Timeline)
	}
}

func TestReactorRejectsProviderSwitchDuringPreparation(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	fake := newFakeProviderRuntime()
	fake.startSession = provider.Session{ProviderInstanceID: "provider-a"}
	fake.startEntered = make(chan struct{}, 1)
	fake.startRelease = make(chan struct{})
	NewProviderEventReactor(context.Background(), engine, fake)

	threadID := ThreadID("thread-stale-prepare")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "create-stale-prepare", ThreadID: threadID, ProviderInstanceID: "provider-a", ModelSelection: &provider.ModelSelection{Model: "model-a"}}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadSessionPrepare, CommandID: "prepare-a", ThreadID: threadID}); err != nil {
		t.Fatalf("thread.session.prepare: %v", err)
	}
	select {
	case <-fake.startEntered:
	case <-time.After(2 * time.Second):
		t.Fatal("preparation did not start")
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "rename-during-prepare", ThreadID: threadID, Title: "Renamed"}); err != nil {
		t.Fatalf("title-only thread.meta.update: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "switch-provider", ThreadID: threadID, ProviderInstanceID: "provider-b"}); err == nil {
		t.Fatal("thread.meta.update succeeded during preparation")
	}
	close(fake.startRelease)
}

func TestReactorRejectsModelChangeDuringPreparation(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	fake := newFakeProviderRuntime()
	fake.startSession = provider.Session{ProviderInstanceID: "provider-a"}
	fake.startEntered = make(chan struct{}, 2)
	fake.startRelease = make(chan struct{})
	NewProviderEventReactor(context.Background(), engine, fake)

	threadID := ThreadID("thread-reprepare")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "create-reprepare", ThreadID: threadID, ProviderInstanceID: "provider-a", ModelSelection: &provider.ModelSelection{Model: "model-a"}}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadSessionPrepare, CommandID: "prepare-model-a", ThreadID: threadID}); err != nil {
		t.Fatalf("thread.session.prepare: %v", err)
	}
	select {
	case <-fake.startEntered:
	case <-time.After(2 * time.Second):
		t.Fatal("first preparation did not start")
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "select-model-b", ThreadID: threadID, ModelSelection: &provider.ModelSelection{Model: "model-b"}}); err == nil {
		t.Fatal("model change succeeded during preparation")
	}
	close(fake.startRelease)
}

func TestReactorRejectsTurnStartDuringPreparation(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	fake := newFakeProviderRuntime()
	fake.startSession = provider.Session{ProviderInstanceID: "codex", ConfigOptions: []provider.ConfigOption{{ID: "model", Category: provider.ConfigOptionCategoryModel, CurrentValue: "fast"}}}
	fake.startEntered = make(chan struct{}, 2)
	fake.startRelease = make(chan struct{})
	NewProviderEventReactor(context.Background(), engine, fake)

	threadID := ThreadID("thread-prepare-turn-race")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "create-prepare-race", ThreadID: threadID, ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadSessionPrepare, CommandID: "prepare-race", ThreadID: threadID}); err != nil {
		t.Fatalf("thread.session.prepare: %v", err)
	}
	select {
	case <-fake.startEntered:
	case <-time.After(2 * time.Second):
		t.Fatal("preparation did not start")
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-during-prepare", ThreadID: threadID, Message: &CommandMessage{Text: "hello"}}); err == nil {
		t.Fatal("thread.turn.start succeeded during preparation")
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadSessionStop, CommandID: "stop-during-prepare", ThreadID: threadID}); err == nil {
		t.Fatal("thread.session.stop succeeded during preparation")
	}
	close(fake.startRelease)
}

func TestReactorRecordsPreparationFailureAndRetriesAfterFix(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	fake := newFakeProviderRuntime()
	fake.startErr = errors.New("agent unreachable")
	fake.startSession = provider.Session{ProviderInstanceID: "codex"}
	NewProviderEventReactor(context.Background(), engine, fake)

	threadID := ThreadID("thread-prepare-retry")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "create-prepare-retry", ThreadID: threadID, ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadSessionPrepare, CommandID: "prepare-fails", ThreadID: threadID}); err != nil {
		t.Fatalf("thread.session.prepare: %v", err)
	}
	waitForSessionStatus(t, engine, threadID, SessionStatusError)
	thread, _ := engine.Thread(threadID)
	if thread.Session == nil || !strings.Contains(thread.Session.LastError, "agent unreachable") {
		t.Fatalf("session = %#v, want lastError to carry the provider failure", thread.Session)
	}

	fake.mu.Lock()
	fake.startErr = nil
	fake.mu.Unlock()
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadSessionPrepare, CommandID: "prepare-retry", ThreadID: threadID}); err != nil {
		t.Fatalf("thread.session.prepare retry: %v", err)
	}
	waitForSessionStatus(t, engine, threadID, SessionStatusReady)
	thread, _ = engine.Thread(threadID)
	if thread.Session.LastError != "" {
		t.Fatalf("session after retry = %#v, want cleared lastError", thread.Session)
	}
}

func waitForSessionStatus(t *testing.T, engine *Engine, threadID ThreadID, status SessionStatus) {
	t.Helper()
	deadline := time.After(2 * time.Second)
	for {
		thread, ok := engine.Thread(threadID)
		if ok && thread.Session != nil && thread.Session.Status == status {
			return
		}
		select {
		case <-deadline:
			t.Fatalf("session never reached %q: %#v", status, thread.Session)
		case <-time.After(10 * time.Millisecond):
		}
	}
}

func TestReactorClearsPendingIntentWhenProviderRejectsInterruptOrStop(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	fake := newFakeProviderRuntime()
	fake.interruptErr = errors.New("interrupt rejected")
	fake.stopErr = errors.New("stop rejected")
	reactor := &ProviderEventReactor{engine: engine, provider: fake, providerRPCTimeout: time.Second}
	threadID := ThreadID("thread-rejected-lifecycle-intent")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "create-rejected-lifecycle", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: &SessionBinding{ThreadID: threadID, ProviderInstanceID: "codex", Status: SessionStatusReady, UpdatedAt: time.Now()}}}); err != nil {
		t.Fatalf("thread.session.status.set: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-rejected-lifecycle", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-rejected-lifecycle", Text: "hello"}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	thread, _ := engine.Thread(threadID)
	turnID := thread.LatestTurn.ID
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnInterrupt, CommandID: "interrupt-rejected-lifecycle", ThreadID: threadID, TurnID: turnID}); err != nil {
		t.Fatalf("thread.turn.interrupt: %v", err)
	}
	reactor.handleInterrupt(Event{Type: EventThreadTurnInterruptRequested, Payload: EventPayload{ThreadID: threadID, TurnID: turnID}})
	thread, _ = engine.Thread(threadID)
	if thread.LatestTurn == nil || thread.LatestTurn.InterruptRequested || thread.LatestTurn.State != TurnStateRunning {
		t.Fatalf("latest turn after rejected interrupt = %#v, want running with pending flag cleared", thread.LatestTurn)
	}

	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadSessionStop, CommandID: "stop-rejected-lifecycle", ThreadID: threadID}); err != nil {
		t.Fatalf("thread.session.stop: %v", err)
	}
	reactor.handleStop(Event{Type: EventThreadSessionStopRequested, Payload: EventPayload{ThreadID: threadID, TurnID: turnID}})
	thread, _ = engine.Thread(threadID)
	if thread.Session == nil || thread.Session.StopRequested || thread.Session.Status != SessionStatusRunning {
		t.Fatalf("session after rejected stop = %#v, want running with pending flag cleared", thread.Session)
	}
	if len(thread.Timeline.Items()) != 2 || thread.Timeline.Items()[0].Kind != provider.ItemKindError || thread.Timeline.Items()[1].Kind != provider.ItemKindError {
		t.Fatalf("items = %#v, want one error for each rejected operation", thread.Timeline.Items())
	}
}

func TestReactorStopReleasesRestoredIdleRoute(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	fake := newFakeProviderRuntime()
	NewProviderEventReactor(context.Background(), engine, fake)
	threadID := ThreadID("thread-restored-stop")
	now := time.Now()
	engine.RestoreThreads([]RestoredThread{{
		ThreadID:           threadID,
		ProviderInstanceID: "codex",
		CreatedAt:          now,
		UpdatedAt:          now,
	}})

	if _, err := engine.Dispatch(context.Background(), Command{
		Type:      CommandThreadSessionStop,
		CommandID: "stop-restored-idle",
		ThreadID:  threadID,
	}); err != nil {
		t.Fatalf("thread.session.stop: %v", err)
	}
	select {
	case <-fake.stopSignal:
	case <-time.After(2 * time.Second):
		t.Fatal("stop did not release the restored provider route")
	}
	if fake.releaseCallCount() != 1 {
		t.Fatalf("ReleaseSession calls = %d, want 1", fake.releaseCallCount())
	}
}

func TestReactorSuccessfulStopRecordsCancelledReasonForActiveTurn(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	fake := newFakeProviderRuntime()
	reactor := &ProviderEventReactor{engine: engine, provider: fake, providerRPCTimeout: time.Second}
	threadID := ThreadID("thread-successful-stop-reason")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "create-successful-stop-reason", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: &SessionBinding{ThreadID: threadID, ProviderInstanceID: "codex", Status: SessionStatusReady, UpdatedAt: time.Now()}}}); err != nil {
		t.Fatalf("thread.session.status.set: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-successful-stop-reason", ThreadID: threadID, Message: &CommandMessage{Text: "hello"}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	thread, _ := engine.Thread(threadID)
	turnID := thread.LatestTurn.ID
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadSessionStop, CommandID: "stop-successful-stop-reason", ThreadID: threadID}); err != nil {
		t.Fatalf("thread.session.stop: %v", err)
	}

	reactor.handleStop(Event{Type: EventThreadSessionStopRequested, Payload: EventPayload{ThreadID: threadID, TurnID: turnID}})

	thread, _ = engine.Thread(threadID)
	if thread.Session == nil || thread.Session.Status != SessionStatusStopped {
		t.Fatalf("session after successful stop = %#v, want stopped", thread.Session)
	}
	if thread.LatestTurn == nil || thread.LatestTurn.State != TurnStateInterrupted || thread.LatestTurn.StopReason != "cancelled" {
		t.Fatalf("latest turn after successful stop = %#v, want interrupted with cancelled stop reason", thread.LatestTurn)
	}
}

func TestReactorRestoresConfirmedConfigOptionsAfterSessionStop(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	fake := newFakeProviderRuntime()
	reactor := &ProviderEventReactor{engine: engine, provider: fake, providerRPCTimeout: time.Second}
	threadID := ThreadID("thread-config-after-stop")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "create-config-after-stop", ThreadID: threadID, ProviderInstanceID: "codex", ModelSelection: &provider.ModelSelection{Model: "fast"}}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: &SessionBinding{ThreadID: threadID, ProviderInstanceID: "codex", Status: SessionStatusReady}}}); err != nil {
		t.Fatalf("thread.session.status.set: %v", err)
	}
	options := []provider.ConfigOption{
		{ID: "model", Category: provider.ConfigOptionCategoryModel, CurrentValue: "fast"},
		{ID: "mode", Category: provider.ConfigOptionCategoryMode, CurrentValue: "plan"},
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadConfigOptionsUpdated, ThreadID: threadID, Payload: EventPayload{ConfigOptions: options}}); err != nil {
		t.Fatalf("thread.config-options.update: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadSessionStop, CommandID: "stop-config-after-stop", ThreadID: threadID}); err != nil {
		t.Fatalf("thread.session.stop: %v", err)
	}
	reactor.handleStop(Event{Type: EventThreadSessionStopRequested, Payload: EventPayload{ThreadID: threadID}})

	result, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadSessionPrepare, CommandID: "prepare-config-after-stop", ThreadID: threadID})
	if err != nil {
		t.Fatalf("thread.session.prepare: %v", err)
	}
	reactor.handleSessionPrepare(Event{Type: EventThreadSessionPrepareRequested, Sequence: result.Sequence, Payload: EventPayload{ThreadID: threadID}})

	input := fake.lastStartInput()
	if len(input.ConfigSelections) != 1 || input.ConfigSelections[0].OptionID != "mode" || input.ConfigSelections[0].Value != "plan" {
		t.Fatalf("restored config selections = %#v, want mode=plan", input.ConfigSelections)
	}
}

func TestReactorRequeuesSteerWhenTurnSettlesBeforeDispatch(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	fake := newFakeProviderRuntime()
	reactor := NewProviderEventReactor(context.Background(), engine, fake)
	threadID := ThreadID("thread-steer-settle-race")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "create-steer-settle-race", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: &SessionBinding{ThreadID: threadID, ProviderInstanceID: "codex", Status: SessionStatusReady}}}); err != nil {
		t.Fatalf("thread.session.status.set: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "first-turn-before-steer-race", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-first-turn-before-steer-race", Text: "first"}}); err != nil {
		t.Fatalf("first thread.turn.start: %v", err)
	}
	select {
	case <-fake.sendSignal:
	case <-time.After(2 * time.Second):
		t.Fatal("first turn was not dispatched")
	}

	blockDispatch := make(chan struct{})
	reactor.mu.Lock()
	reactor.threadTails[threadID] = blockDispatch
	reactor.mu.Unlock()
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "steer-settle-race", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-steer-settle-race", Text: "do not lose this"}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	thread, _ := engine.Thread(threadID)
	oldTurnID := thread.LatestTurn.ID
	if _, err := engine.updateSession(context.Background(), sessionUpdate{threadID: threadID, Kind: sessionUpdateTurnSettled, TurnID: oldTurnID, TurnState: provider.RuntimeTurnCompleted}); err != nil {
		t.Fatalf("settle old turn: %v", err)
	}
	close(blockDispatch)

	select {
	case <-fake.sendSignal:
	case <-time.After(2 * time.Second):
		t.Fatal("accepted steer was not delivered after the old turn settled")
	}
	sent := fake.lastSendInput()
	if sent.Input != "do not lose this" || sent.TurnID == "" || sent.TurnID == string(oldTurnID) {
		t.Fatalf("requeued send = %#v, want the accepted message on a fresh turn", sent)
	}
	thread, _ = engine.Thread(threadID)
	if thread.LatestTurn == nil || string(thread.LatestTurn.ID) != sent.TurnID || thread.Timeline.Messages()[len(thread.Timeline.Messages())-1].TurnID != thread.LatestTurn.ID {
		t.Fatalf("thread after requeue = %#v, want message and latest turn on %q", thread, sent.TurnID)
	}
}

func TestReactorReleasesProviderSessionWhenMetadataSwitchesProvider(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	fake := newFakeProviderRuntime()
	NewProviderEventReactor(context.Background(), engine, fake)
	threadID := ThreadID("thread-release-on-provider-switch")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "create-release-on-switch", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "provider-a"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: &SessionBinding{ThreadID: threadID, ProviderInstanceID: "provider-a", Status: SessionStatusReady}}}); err != nil {
		t.Fatalf("thread.session.status.set: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "switch-and-release", ThreadID: threadID, ProviderInstanceID: "provider-b"}); err != nil {
		t.Fatalf("thread.meta.update: %v", err)
	}
	select {
	case <-fake.stopSignal:
	case <-time.After(2 * time.Second):
		t.Fatal("provider switch did not release the old provider session")
	}
}

func TestReactorInitialSessionBindingDoesNotCompleteTurn(t *testing.T) {
	engine := NewEngine()
	fake := newFakeProviderRuntime()
	NewProviderEventReactor(context.Background(), engine, fake)
	threadID := ThreadID("thread-initial-binding-running")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "create-initial-binding-running", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-initial-binding-running", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-initial", Text: "hello"}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	select {
	case <-fake.sendSignal:
	case <-time.After(2 * time.Second):
		t.Fatal("expected SendTurn to be called")
	}
	thread, ok := engine.Thread(threadID)
	if !ok || thread.LatestTurn == nil || thread.Session == nil {
		t.Fatalf("thread/session missing: %#v", thread)
	}
	if thread.LatestTurn.CompletedAt != nil || thread.LatestTurn.State != TurnStateRunning {
		t.Fatalf("latest turn = %#v, want still running without completedAt", thread.LatestTurn)
	}
	if thread.Session.ActiveTurnID != thread.LatestTurn.ID || thread.Session.Status != SessionStatusRunning {
		t.Fatalf("session = %#v, want active running turn", thread.Session)
	}
}

func TestReactorProjectsProviderSessionReturnedFromStartSession(t *testing.T) {
	engine := NewEngine()
	fake := newFakeProviderRuntime()
	fake.startSession = provider.Session{
		ProviderInstanceID: "codex",
		ProviderName:       "Codex Test",
		ConfigOptions:      []provider.ConfigOption{{ID: "model", Category: provider.ConfigOptionCategoryModel, CurrentValue: "fast"}},
	}
	NewProviderEventReactor(context.Background(), engine, fake)
	threadID := ThreadID("thread-returned-session")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "create-returned-session", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-returned-session", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-returned-session", Text: "hello"}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	select {
	case <-fake.sendSignal:
	case <-time.After(2 * time.Second):
		t.Fatal("expected SendTurn to be called")
	}
	thread, ok := engine.Thread(threadID)
	if !ok || thread.Session == nil {
		t.Fatalf("thread/session missing: %#v", thread)
	}
	if thread.Session.ProviderName != "Codex Test" || len(thread.Session.ConfigOptions) != 1 || thread.Session.ConfigOptions[0].ID != "model" {
		t.Fatalf("session = %#v, want provider-returned config options", thread.Session)
	}
	if thread.Session.Status != SessionStatusRunning || thread.Session.ActiveTurnID == "" {
		t.Fatalf("session = %#v, want running returned session", thread.Session)
	}
}

func TestReactorEnsuresProviderSessionForExistingReadyBinding(t *testing.T) {
	engine := NewEngine()
	fake := newFakeProviderRuntime()
	NewProviderEventReactor(context.Background(), engine, fake)
	threadID := ThreadID("thread-ready-rebind")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "create-ready-rebind", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	binding := &SessionBinding{ThreadID: threadID, ProviderInstanceID: "codex", Status: SessionStatusReady, UpdatedAt: time.Now()}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: binding}}); err != nil {
		t.Fatalf("thread.session.status.set: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-ready-rebind", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-ready-rebind", Text: "hello"}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	select {
	case <-fake.sendSignal:
	case <-time.After(2 * time.Second):
		t.Fatal("expected SendTurn to be called")
	}
	if calls := fake.startCalls(); calls != 1 {
		t.Fatalf("StartSession calls = %d, want 1 to rebind provider route before SendTurn", calls)
	}
	if got := fake.lastStartInput().ThreadID; got != string(threadID) {
		t.Fatalf("StartSession threadID = %q, want %q", got, threadID)
	}
}

func TestReactorDoesNotForwardStaleModelAfterProviderOnlySwitch(t *testing.T) {
	engine := NewEngine()
	fake := newFakeProviderRuntime()
	NewProviderEventReactor(context.Background(), engine, fake)
	threadID := ThreadID("thread-provider-switch-clears-model")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "create-provider-a-model", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "provider-a", ModelSelection: &provider.ModelSelection{Model: "a-model", Options: []byte(`{"effort":"high"}`)}}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: "switch-provider-b-only", ThreadID: threadID, ProviderInstanceID: "provider-b"}); err != nil {
		t.Fatalf("thread.meta.update: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-provider-b", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-provider-b", Text: "hello"}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	select {
	case <-fake.sendSignal:
	case <-time.After(2 * time.Second):
		t.Fatal("expected SendTurn to be called")
	}
	start := fake.lastStartInput()
	if start.ProviderInstanceID != "provider-b" {
		t.Fatalf("StartSession providerInstanceId = %q, want provider-b", start.ProviderInstanceID)
	}
	assertNoStaleModel := func(name string, selection *provider.ModelSelection) {
		t.Helper()
		if selection == nil {
			return
		}
		if selection.Model != "" || len(selection.Options) != 0 {
			t.Fatalf("%s modelSelection = %#v, want no provider-a model/options after the switch", name, selection)
		}
	}
	assertNoStaleModel("StartSession", start.ModelSelection)
	assertNoStaleModel("SendTurn", fake.lastSendInput().ModelSelection)
}

func TestReactorDoesNotReviveTurnInterruptedBeforeStartHandlerRuns(t *testing.T) {
	engine := NewEngine()
	fake := newFakeProviderRuntime()
	reactor := NewProviderEventReactor(context.Background(), engine, fake)
	threadID := ThreadID("thread-interrupt-before-start-handler")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "create-interrupt-before-start-handler", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	// Occupy the thread's serialized handler chain so the turn-start handler
	// body cannot run until the interrupt has been applied to the projection.
	gate := make(chan struct{})
	released := false
	t.Cleanup(func() {
		if !released {
			close(gate)
		}
	})
	reactor.enqueueThread(Event{Type: "test.gate", Payload: EventPayload{ThreadID: threadID}}, func() { <-gate })
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-interrupt-before-start-handler", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-interrupt-before-start-handler", Text: "hello"}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	thread, ok := engine.Thread(threadID)
	if !ok || thread.LatestTurn == nil {
		t.Fatalf("thread latest turn missing: %#v", thread)
	}
	turnID := thread.LatestTurn.ID
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnInterrupt, CommandID: "interrupt-before-start-handler", ThreadID: threadID, TurnID: turnID}); err != nil {
		t.Fatalf("thread.turn.interrupt: %v", err)
	}
	released = true
	close(gate)

	deadline := time.After(2 * time.Second)
	for {
		reactor.mu.Lock()
		_, pending := reactor.threadTails[threadID]
		reactor.mu.Unlock()
		if !pending {
			break
		}
		select {
		case <-deadline:
			t.Fatal("timed out waiting for reactor queue to drain")
		case <-time.After(10 * time.Millisecond):
		}
	}
	if calls := fake.startCalls(); calls != 0 {
		t.Fatalf("StartSession called %d times, want 0 after pre-handler interrupt", calls)
	}
	if calls := fake.sendCalls(); calls != 0 {
		t.Fatalf("SendTurn called %d times, want 0 after pre-handler interrupt", calls)
	}
	thread, _ = engine.Thread(threadID)
	if thread.LatestTurn == nil || thread.LatestTurn.ID != turnID || thread.LatestTurn.State != TurnStateInterrupted {
		t.Fatalf("latest turn = %#v, want interrupted original turn", thread.LatestTurn)
	}
	if thread.Session != nil {
		t.Fatalf("session = %#v, want no revived session binding", thread.Session)
	}
}

func TestReactorDoesNotSendTurnInterruptedBeforeSessionBinding(t *testing.T) {
	engine := NewEngine()
	fake := newFakeProviderRuntime()
	fake.startEntered = make(chan struct{}, 1)
	fake.startRelease = make(chan struct{})
	NewProviderEventReactor(context.Background(), engine, fake)
	threadID := ThreadID("thread-interrupt-before-session")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "create-interrupt-before-session", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-interrupt-before-session", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-interrupt", Text: "hello"}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	select {
	case <-fake.startEntered:
	case <-time.After(2 * time.Second):
		t.Fatal("expected StartSession to be entered")
	}
	thread, ok := engine.Thread(threadID)
	if !ok || thread.LatestTurn == nil {
		t.Fatalf("thread latest turn missing: %#v", thread)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnInterrupt, CommandID: "interrupt-before-session", ThreadID: threadID, TurnID: thread.LatestTurn.ID}); err != nil {
		t.Fatalf("thread.turn.interrupt: %v", err)
	}
	close(fake.startRelease)
	time.Sleep(100 * time.Millisecond)
	if calls := fake.sendCalls(); calls != 0 {
		t.Fatalf("SendTurn called %d times, want 0 after pre-session interrupt", calls)
	}
	thread, _ = engine.Thread(threadID)
	if thread.Session == nil || thread.Session.Status != SessionStatusReady || thread.Session.ActiveTurnID != "" {
		t.Fatalf("session = %#v, want ready binding because no prompt was dispatched", thread.Session)
	}
}

func TestReactorInterruptNoopsAfterProviderAlreadyCompletedTurn(t *testing.T) {
	engine := NewEngine()
	fake := newFakeProviderRuntime()
	fake.startEntered = make(chan struct{}, 1)
	fake.startRelease = make(chan struct{})
	NewProviderEventReactor(context.Background(), engine, fake)
	ingestion := NewProviderRuntimeIngestion(engine)

	threadID := ThreadID("thread-interrupt-after-complete")
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: "create-interrupt-after-complete", ThreadID: threadID, Title: "Thread", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnStart, CommandID: "turn-interrupt-after-complete", ThreadID: threadID, Message: &CommandMessage{MessageID: "msg-interrupt-after-complete", Text: "hello"}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	select {
	case <-fake.startEntered:
	case <-time.After(2 * time.Second):
		t.Fatal("expected StartSession to be entered")
	}
	thread, ok := engine.Thread(threadID)
	if !ok || thread.LatestTurn == nil {
		t.Fatalf("thread latest turn missing: %#v", thread)
	}
	turnID := thread.LatestTurn.ID
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadTurnInterrupt, CommandID: "interrupt-after-complete", ThreadID: threadID, TurnID: turnID}); err != nil {
		t.Fatalf("thread.turn.interrupt: %v", err)
	}
	ingestion.Ingest(provider.RuntimeEvent{EventID: "completed-before-interrupt-reactor", Type: provider.RuntimeEventTurnCompleted, ProviderInstanceID: "codex", ThreadID: string(threadID), TurnID: string(turnID), CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnCompleted}})

	thread, _ = engine.Thread(threadID)
	if thread.Session == nil || thread.Session.Status != SessionStatusReady || thread.LatestTurn == nil || thread.LatestTurn.State != TurnStateCompleted {
		t.Fatalf("thread after provider completion = %#v, want ready completed turn", thread)
	}
	close(fake.startRelease)
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadConfigOptionSet, CommandID: "barrier", ThreadID: threadID, OptionID: "mode", Value: "default"}); err != nil {
		t.Fatalf("config-option barrier: %v", err)
	}
	select {
	case <-fake.configSetSignal:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for reactor queue barrier")
	}
	if calls := fake.interruptCallCount(); calls != 0 {
		t.Fatalf("InterruptTurn calls = %d, want 0 after provider already completed the turn", calls)
	}
	thread, _ = engine.Thread(threadID)
	if thread.Session == nil || thread.Session.Status != SessionStatusReady {
		t.Fatalf("session after stale interrupt reactor = %#v, want provider-completed ready state preserved", thread.Session)
	}
}

func TestReactorProviderCallTimeoutUnwedgesThreadQueue(t *testing.T) {
	engine := NewEngine()
	fake := newFakeProviderRuntime()
	fake.configSetEntered = make(chan struct{}, 1)
	fake.configSetRelease = make(chan struct{})
	reactor := NewProviderEventReactor(context.Background(), engine, fake)
	reactor.providerRPCTimeout = 25 * time.Millisecond
	threadID := setupConfigOptionThread(t, engine)

	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadConfigOptionSet, CommandID: "set-hung-option", ThreadID: threadID, OptionID: "temperature", Value: "1"}); err != nil {
		t.Fatalf("config-option.set: %v", err)
	}
	select {
	case <-fake.configSetEntered:
	case <-time.After(2 * time.Second):
		t.Fatal("expected SetConfigOption to be entered")
	}

	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadConfigOptionSet, CommandID: "barrier", ThreadID: threadID, OptionID: "mode", Value: "default"}); err != nil {
		t.Fatalf("config-option.set: %v", err)
	}
	select {
	case <-fake.configSetEntered:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for subsequent command after provider RPC timeout")
	}
}

func TestReactorAppliesModelChangeWhenSwitchInSession(t *testing.T) {
	engine := NewEngine()
	fake := newFakeProviderRuntime()
	NewProviderEventReactor(context.Background(), engine, fake)
	threadID := setupConfigOptionThread(t, engine)

	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadConfigOptionSet, CommandID: "set-model", ThreadID: threadID, OptionID: "model", Value: "slow"}); err != nil {
		t.Fatalf("config-option.set: %v", err)
	}

	select {
	case <-fake.configSetSignal:
	case <-time.After(2 * time.Second):
		t.Fatal("expected SetConfigOption to be called for in-session model switch")
	}
	fake.mu.Lock()
	input := fake.configSetInputs[len(fake.configSetInputs)-1]
	fake.mu.Unlock()
	if input.Category != provider.ConfigOptionCategoryModel {
		t.Fatalf("config option category = %q, want model", input.Category)
	}
}
