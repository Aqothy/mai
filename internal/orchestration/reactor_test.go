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
	mu                 sync.Mutex
	configSetCalls     int
	configSetInputs    []provider.SetConfigOptionInput
	configSetSignal    chan struct{}
	startInputs        []provider.StartSessionInput
	startSession       provider.Session
	startReplay        []provider.RuntimeEvent
	historyUnavailable bool
	startErr           error
	sendInputs         []provider.SendTurnInput
	interruptCalls     int
	interruptSignal    chan struct{}
	interruptErr       error
	stopCalls          int
	releaseCalls       int
	releaseInputs      []provider.StopSessionInput
	stopSignal         chan struct{}
	stopErr            error
	respondInputs      []provider.RespondToRequestInput
	respondSignal      chan struct{}
	respondErr         error
	startEntered       chan struct{}
	startRelease       chan struct{}
	configSetEntered   chan struct{}
	configSetRelease   chan struct{}
	sendSignal         chan struct{}
}

func newFakeProviderRuntime() *fakeProviderRuntime {
	return &fakeProviderRuntime{configSetSignal: make(chan struct{}, 4), interruptSignal: make(chan struct{}, 4), stopSignal: make(chan struct{}, 4), sendSignal: make(chan struct{}, 4), respondSignal: make(chan struct{}, 4)}
}

func newTestReactor(engine *Engine, runtime ProviderRuntime) *ProviderEventReactor {
	return NewProviderEventReactor(context.Background(), engine, runtime, NewProviderRuntimeIngestion(engine))
}

func (f *fakeProviderRuntime) StartSession(ctx context.Context, _ string, input provider.StartSessionInput) (provider.StartSessionResult, error) {
	f.mu.Lock()
	f.startInputs = append(f.startInputs, input)
	session := f.startSession
	replay := append([]provider.RuntimeEvent(nil), f.startReplay...)
	historyUnavailable := f.historyUnavailable
	startErr := f.startErr
	entered := f.startEntered
	release := f.startRelease
	f.mu.Unlock()
	if startErr != nil {
		return provider.StartSessionResult{}, startErr
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
			return provider.StartSessionResult{}, ctx.Err()
		}
	}
	if session.ProviderInstanceID == "" {
		session.ProviderInstanceID = "codex"
	}
	return provider.StartSessionResult{Session: session, Replay: replay, HistoryUnavailable: historyUnavailable}, nil
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
func (f *fakeProviderRuntime) ReleaseSession(_ context.Context, input provider.StopSessionInput) error {
	f.mu.Lock()
	f.releaseCalls++
	f.releaseInputs = append(f.releaseInputs, input)
	err := f.stopErr
	f.mu.Unlock()
	select {
	case f.stopSignal <- struct{}{}:
	default:
	}
	return err
}
func (f *fakeProviderRuntime) RespondToRequest(_ context.Context, input provider.RespondToRequestInput) error {
	f.mu.Lock()
	f.respondInputs = append(f.respondInputs, input)
	err := f.respondErr
	f.mu.Unlock()
	select {
	case f.respondSignal <- struct{}{}:
	default:
	}
	return err
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

func (f *fakeProviderRuntime) lastReleaseInput() provider.StopSessionInput {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.releaseInputs) == 0 {
		return provider.StopSessionInput{}
	}
	return f.releaseInputs[len(f.releaseInputs)-1]
}

func (f *fakeProviderRuntime) respondCallCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.respondInputs)
}

func (f *fakeProviderRuntime) lastRespondInput() provider.RespondToRequestInput {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.respondInputs) == 0 {
		return provider.RespondToRequestInput{}
	}
	return f.respondInputs[len(f.respondInputs)-1]
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

func setupApprovalThread(t *testing.T, engine *Engine, threadID ThreadID, withSession bool) {
	t.Helper()
	if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: CommandID("create-" + string(threadID)), ThreadID: threadID, ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if withSession {
		if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadSessionStatusSet, ThreadID: threadID, Payload: EventPayload{Session: &SessionBinding{ProviderInstanceID: "codex", Status: SessionStatusRunning, ActiveTurnID: "turn-approval"}}}); err != nil {
			t.Fatalf("thread.session.status.set: %v", err)
		}
	}
	if _, err := engine.AppendEvent(context.Background(), EventInput{Type: EventThreadApprovalOpened, ThreadID: threadID, Payload: EventPayload{Approval: &ApprovalEvent{RequestID: "approval-1", TurnID: "turn-approval", Options: []provider.ApprovalOption{{ID: "allow"}, {ID: "reject"}}}}}); err != nil {
		t.Fatalf("thread.approval.open: %v", err)
	}
}

func waitForReactorIdle(t *testing.T, reactor *ProviderEventReactor, threadID ThreadID) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		reactor.mu.Lock()
		_, pending := reactor.threadTails[threadID]
		reactor.mu.Unlock()
		if !pending {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("reactor queue for %q did not drain", threadID)
}

func TestReactorPreparesSessionBeforeFirstTurn(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	fake := newFakeProviderRuntime()
	fake.startSession = provider.Session{ProviderInstanceID: "codex", ConfigOptions: []provider.ConfigOption{{ID: "model", Category: provider.ConfigOptionCategoryModel, CurrentValue: "fast"}}}
	reactor := &ProviderEventReactor{engine: engine, provider: fake, ingestion: NewProviderRuntimeIngestion(engine), providerRPCTimeout: time.Second}
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
	if input := fake.lastStartInput(); input.ThreadID != string(threadID) || input.ModelSelection == nil || input.ModelSelection.Model != "fast" || input.ReplayHistory {
		t.Fatalf("start input = %#v", input)
	}
	if thread.Session == nil || thread.Session.Status != SessionStatusReady || len(thread.Session.ConfigOptions) != 1 {
		t.Fatalf("prepared session = %#v", thread.Session)
	}
	if thread.LatestTurn != nil || len(thread.Timeline) != 0 {
		t.Fatalf("preparation created conversation content: turn=%#v timeline=%#v", thread.LatestTurn, thread.Timeline)
	}
}

func TestReactorRequestsReplayWhenPreparingRestoredEmptyThread(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	fake := newFakeProviderRuntime()
	fake.startSession = provider.Session{ProviderInstanceID: "codex"}
	fake.startReplay = []provider.RuntimeEvent{{
		Type:     provider.RuntimeEventItemCompleted,
		ThreadID: "thread-restored-replay",
		ItemID:   "restored-user",
		Payload:  provider.RuntimeEventPayload{ItemType: provider.ItemKindUserMessage, Detail: "restored question"},
	}}
	reactor := &ProviderEventReactor{engine: engine, provider: fake, ingestion: NewProviderRuntimeIngestion(engine), providerRPCTimeout: time.Second}
	threadID := ThreadID("thread-restored-replay")
	now := time.Now()
	engine.RestoreThreads([]RestoredThread{{
		ThreadID:           threadID,
		ProviderInstanceID: "codex",
		CreatedAt:          now,
		UpdatedAt:          now,
	}})

	result, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadSessionPrepare, CommandID: "prepare-restored", ThreadID: threadID})
	if err != nil {
		t.Fatalf("thread.session.prepare: %v", err)
	}
	reactor.handleSessionPrepare(Event{Type: EventThreadSessionPrepareRequested, Sequence: result.Sequence, Payload: EventPayload{ThreadID: threadID}})

	if input := fake.lastStartInput(); !input.ReplayHistory {
		t.Fatalf("start input = %#v, want replay history", input)
	}
	thread, _ := engine.Thread(threadID)
	if thread.ReplayHistoryPending {
		t.Fatalf("restored replay intent remained pending after synchronous replay: %#v", thread)
	}
	if len(thread.Timeline) != 1 || thread.Timeline[0].Message == nil || thread.Timeline[0].Message.Text != "restored question" {
		t.Fatalf("timeline = %#v, want replay applied before preparation completed", thread.Timeline)
	}
	events := engine.ReplayEvents(ReplayEventsInput{ThreadID: threadID, FromSequenceExclusive: result.Sequence})
	var historySequence, readySequence uint64
	for _, event := range events {
		switch event.Type {
		case EventThreadHistoryReplayCompleted:
			historySequence = event.Sequence
		case EventThreadSessionStatusSet:
			if event.Payload.Session != nil && event.Payload.Session.Status == SessionStatusReady {
				readySequence = event.Sequence
			}
		}
	}
	if historySequence == 0 || readySequence == 0 || historySequence >= readySequence {
		t.Fatalf("history/ready sequences = %d/%d, want replay completion before ready", historySequence, readySequence)
	}
}

func TestReactorCompletesUnavailableHistoryWithWarning(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	fake := newFakeProviderRuntime()
	fake.startSession = provider.Session{ProviderInstanceID: "codex"}
	fake.historyUnavailable = true
	reactor := &ProviderEventReactor{engine: engine, provider: fake, ingestion: NewProviderRuntimeIngestion(engine), providerRPCTimeout: time.Second}
	threadID := ThreadID("thread-restored-unavailable")
	now := time.Now()
	engine.RestoreThreads([]RestoredThread{{ThreadID: threadID, ProviderInstanceID: "codex", CreatedAt: now, UpdatedAt: now}})

	result, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadSessionPrepare, CommandID: "prepare-restored-unavailable", ThreadID: threadID})
	if err != nil {
		t.Fatalf("thread.session.prepare: %v", err)
	}
	reactor.handleSessionPrepare(Event{Type: EventThreadSessionPrepareRequested, Sequence: result.Sequence, Payload: EventPayload{ThreadID: threadID}})

	thread, _ := engine.Thread(threadID)
	if thread.ReplayHistoryPending || thread.Session == nil || thread.Session.Status != SessionStatusReady {
		t.Fatalf("thread = %#v, want degraded restore completed and ready", thread)
	}
	if len(thread.Timeline) != 1 || thread.Timeline[0].Item == nil || thread.Timeline[0].Item.Kind != provider.ItemKindWarning || thread.Timeline[0].Item.Title != "history unavailable for this agent" {
		t.Fatalf("timeline = %#v, want visible history-unavailable warning", thread.Timeline)
	}
}

func TestReactorRetriesPendingReplayWithTimelineContent(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	fake := newFakeProviderRuntime()
	fake.startSession = provider.Session{ProviderInstanceID: "codex"}
	reactor := &ProviderEventReactor{engine: engine, provider: fake, ingestion: NewProviderRuntimeIngestion(engine), providerRPCTimeout: time.Second}
	threadID := ThreadID("thread-restored-with-content")
	now := time.Now()
	engine.RestoreThreads([]RestoredThread{{ThreadID: threadID, ProviderInstanceID: "codex", CreatedAt: now, UpdatedAt: now}})
	if _, err := engine.AppendEvent(context.Background(), EventInput{
		Type:     EventThreadMessageSent,
		ThreadID: threadID,
		Payload:  EventPayload{MessageID: "message-restored", Role: MessageRoleAssistant, Text: "already restored"},
	}); err != nil {
		t.Fatalf("append existing history: %v", err)
	}

	result, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadSessionPrepare, CommandID: "prepare-restored-with-content", ThreadID: threadID})
	if err != nil {
		t.Fatalf("thread.session.prepare: %v", err)
	}
	reactor.handleSessionPrepare(Event{Type: EventThreadSessionPrepareRequested, Sequence: result.Sequence, Payload: EventPayload{ThreadID: threadID}})
	if input := fake.lastStartInput(); !input.ReplayHistory {
		t.Fatalf("start input = %#v, want pending replay retried", input)
	}
	thread, _ := engine.Thread(threadID)
	if thread.ReplayHistoryPending || thread.Session == nil || thread.Session.Status != SessionStatusReady {
		t.Fatalf("thread after replay retry = %#v, want replay completed and ready", thread)
	}
	if len(thread.Timeline) != 1 || thread.Timeline[0].Message == nil || thread.Timeline[0].Message.Text != "already restored" {
		t.Fatalf("timeline after replay retry = %#v, want existing history preserved without duplication", thread.Timeline)
	}
}

func TestReactorRetriesRestoredReplayAfterPreparationFailure(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	fake := newFakeProviderRuntime()
	fake.startErr = errors.New("agent unreachable")
	reactor := &ProviderEventReactor{engine: engine, provider: fake, ingestion: NewProviderRuntimeIngestion(engine), providerRPCTimeout: time.Second}
	threadID := ThreadID("thread-restored-replay-retry")
	now := time.Now()
	engine.RestoreThreads([]RestoredThread{{ThreadID: threadID, ProviderInstanceID: "codex", CreatedAt: now, UpdatedAt: now}})

	first, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadSessionPrepare, CommandID: "prepare-restored-fails", ThreadID: threadID})
	if err != nil {
		t.Fatalf("first thread.session.prepare: %v", err)
	}
	reactor.handleSessionPrepare(Event{Type: EventThreadSessionPrepareRequested, Sequence: first.Sequence, Payload: EventPayload{ThreadID: threadID}})
	if input := fake.lastStartInput(); !input.ReplayHistory {
		t.Fatalf("first start input = %#v, want replay history", input)
	}
	thread, _ := engine.Thread(threadID)
	if !thread.ReplayHistoryPending {
		t.Fatal("failed preparation consumed restored replay intent")
	}

	fake.mu.Lock()
	fake.startErr = nil
	fake.mu.Unlock()
	second, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadSessionPrepare, CommandID: "prepare-restored-retry", ThreadID: threadID})
	if err != nil {
		t.Fatalf("second thread.session.prepare: %v", err)
	}
	reactor.handleSessionPrepare(Event{Type: EventThreadSessionPrepareRequested, Sequence: second.Sequence, Payload: EventPayload{ThreadID: threadID}})
	if input := fake.lastStartInput(); !input.ReplayHistory {
		t.Fatalf("retry start input = %#v, want replay history", input)
	}
	thread, _ = engine.Thread(threadID)
	if thread.ReplayHistoryPending || thread.Session == nil || thread.Session.Status != SessionStatusReady || thread.Session.LastError != "" {
		t.Fatalf("thread after successful replay retry = %#v, want ready with consumed replay intent", thread)
	}
}

func TestReactorRejectsProviderOrModelChangeDuringPreparation(t *testing.T) {
	tests := []struct {
		name   string
		change Command
	}{
		{name: "provider", change: Command{ProviderInstanceID: "provider-b"}},
		{name: "model", change: Command{ModelSelection: &provider.ModelSelection{Model: "model-b"}}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			engine := NewEngine()
			defer engine.Close()
			fake := newFakeProviderRuntime()
			fake.startSession = provider.Session{ProviderInstanceID: "provider-a"}
			fake.startEntered = make(chan struct{}, 1)
			fake.startRelease = make(chan struct{})
			newTestReactor(engine, fake)

			threadID := ThreadID("thread-prepare-selection-" + tt.name)
			if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadCreate, CommandID: CommandID("create-prepare-selection-" + tt.name), ThreadID: threadID, ProviderInstanceID: "provider-a", ModelSelection: &provider.ModelSelection{Model: "model-a"}}); err != nil {
				t.Fatalf("thread.create: %v", err)
			}
			if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadSessionPrepare, CommandID: CommandID("prepare-selection-" + tt.name), ThreadID: threadID}); err != nil {
				t.Fatalf("thread.session.prepare: %v", err)
			}
			select {
			case <-fake.startEntered:
			case <-time.After(2 * time.Second):
				t.Fatal("preparation did not start")
			}
			if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadMetaUpdate, CommandID: CommandID("rename-during-prepare-" + tt.name), ThreadID: threadID, Title: "Renamed"}); err != nil {
				t.Fatalf("title-only thread.meta.update: %v", err)
			}
			change := tt.change
			change.Type = CommandThreadMetaUpdate
			change.CommandID = CommandID("change-during-prepare-" + tt.name)
			change.ThreadID = threadID
			if _, err := engine.Dispatch(context.Background(), change); err == nil || !strings.Contains(err.Error(), "preparing") {
				t.Fatalf("selection change during preparation err = %v, want preparing rejection", err)
			}
			thread, _ := engine.Thread(threadID)
			if thread.Title != "Renamed" || thread.ProviderInstanceID != "provider-a" || thread.ModelSelection == nil || thread.ModelSelection.Model != "model-a" {
				t.Fatalf("thread after rejected selection change = %#v, want renamed with original selection", thread)
			}

			close(fake.startRelease)
			waitForSessionStatus(t, engine, threadID, SessionStatusReady)
		})
	}
}

func TestReactorRejectsTurnStartDuringPreparation(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	fake := newFakeProviderRuntime()
	fake.startSession = provider.Session{ProviderInstanceID: "codex", ConfigOptions: []provider.ConfigOption{{ID: "model", Category: provider.ConfigOptionCategoryModel, CurrentValue: "fast"}}}
	fake.startEntered = make(chan struct{}, 2)
	fake.startRelease = make(chan struct{})
	newTestReactor(engine, fake)

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
	newTestReactor(engine, fake)

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
	reactor := &ProviderEventReactor{engine: engine, provider: fake, ingestion: NewProviderRuntimeIngestion(engine), providerRPCTimeout: time.Second}
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
	newTestReactor(engine, fake)
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
	reactor := &ProviderEventReactor{engine: engine, provider: fake, ingestion: NewProviderRuntimeIngestion(engine), providerRPCTimeout: time.Second}
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
	reactor := &ProviderEventReactor{engine: engine, provider: fake, ingestion: NewProviderRuntimeIngestion(engine), providerRPCTimeout: time.Second}
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
	reactor := newTestReactor(engine, fake)
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
	newTestReactor(engine, fake)
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
	if fake.releaseCallCount() != 1 || fake.lastReleaseInput().ThreadID != string(threadID) {
		t.Fatalf("release calls/input = %d/%#v, want one release for %q", fake.releaseCallCount(), fake.lastReleaseInput(), threadID)
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
	newTestReactor(engine, fake)
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
	if thread.LatestTurn == nil || thread.LatestTurn.ID != thread.Session.ActiveTurnID || thread.LatestTurn.State != TurnStateRunning || thread.LatestTurn.CompletedAt != nil {
		t.Fatalf("latest turn = %#v, want initial binding to leave the active turn running", thread.LatestTurn)
	}
}

func TestReactorEnsuresProviderSessionForExistingReadyBinding(t *testing.T) {
	engine := NewEngine()
	fake := newFakeProviderRuntime()
	newTestReactor(engine, fake)
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
	newTestReactor(engine, fake)
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
	reactor := newTestReactor(engine, fake)
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
	reactor := newTestReactor(engine, fake)
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
	waitForReactorIdle(t, reactor, threadID)
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
	newTestReactor(engine, fake)
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
	reactor := newTestReactor(engine, fake)
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
	waitForReactorIdle(t, reactor, threadID)
	thread, _ := engine.Thread(threadID)
	foundTimeout := false
	for _, item := range thread.Timeline.Items() {
		if item.Kind == provider.ItemKindError && strings.Contains(item.Title, context.DeadlineExceeded.Error()) {
			foundTimeout = true
		}
	}
	if !foundTimeout {
		t.Fatalf("items = %#v, want visible provider RPC timeout", thread.Timeline.Items())
	}
}

func TestReactorForwardsConfigOptionWithDerivedCategory(t *testing.T) {
	engine := NewEngine()
	fake := newFakeProviderRuntime()
	newTestReactor(engine, fake)
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
	if input.ThreadID != string(threadID) || input.OptionID != "model" || input.Value != "slow" || input.Category != provider.ConfigOptionCategoryModel {
		t.Fatalf("config option input = %#v, want thread/model/slow with model category", input)
	}
}

func TestReactorForwardsApprovalResponse(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	fake := newFakeProviderRuntime()
	reactor := newTestReactor(engine, fake)
	threadID := ThreadID("thread-forward-approval")
	setupApprovalThread(t, engine, threadID, true)

	if _, err := engine.Dispatch(context.Background(), Command{
		Type:      CommandThreadApprovalRespond,
		CommandID: "respond-forward-approval",
		ThreadID:  threadID,
		RequestID: "approval-1",
		Decision:  provider.ApprovalDecisionAccept,
		OptionID:  "allow",
	}); err != nil {
		t.Fatalf("thread.approval.respond: %v", err)
	}
	select {
	case <-fake.respondSignal:
	case <-time.After(2 * time.Second):
		t.Fatal("approval response was not forwarded")
	}
	waitForReactorIdle(t, reactor, threadID)
	input := fake.lastRespondInput()
	if input.ThreadID != string(threadID) || input.RequestID != "approval-1" || input.Decision != provider.ApprovalDecisionAccept || input.OptionID != "allow" {
		t.Fatalf("RespondToRequest input = %#v, want exact approved option response", input)
	}
}

func TestReactorApprovalResponseFailureCreatesTurnScopedError(t *testing.T) {
	engine := NewEngine()
	defer engine.Close()
	fake := newFakeProviderRuntime()
	fake.respondErr = errors.New("approval transport failed")
	reactor := newTestReactor(engine, fake)
	threadID := ThreadID("thread-failed-approval")
	setupApprovalThread(t, engine, threadID, true)

	if _, err := engine.Dispatch(context.Background(), Command{
		Type:      CommandThreadApprovalRespond,
		CommandID: "respond-failed-approval",
		ThreadID:  threadID,
		RequestID: "approval-1",
		Decision:  provider.ApprovalDecisionDecline,
		OptionID:  "reject",
	}); err != nil {
		t.Fatalf("thread.approval.respond: %v", err)
	}
	select {
	case <-fake.respondSignal:
	case <-time.After(2 * time.Second):
		t.Fatal("approval response was not attempted")
	}
	waitForReactorIdle(t, reactor, threadID)
	thread, _ := engine.Thread(threadID)
	items := thread.Timeline.Items()
	if len(items) != 1 || items[0].Kind != provider.ItemKindError || items[0].Title != "approval transport failed" || items[0].TurnID != "turn-approval" {
		t.Fatalf("items = %#v, want turn-scoped approval forwarding error", items)
	}
}

func TestReactorDoesNotForwardStaleApprovalResponse(t *testing.T) {
	t.Run("sessionless", func(t *testing.T) {
		engine := NewEngine()
		defer engine.Close()
		fake := newFakeProviderRuntime()
		reactor := newTestReactor(engine, fake)
		threadID := ThreadID("thread-sessionless-approval")
		setupApprovalThread(t, engine, threadID, false)

		if _, err := engine.Dispatch(context.Background(), Command{Type: CommandThreadApprovalRespond, CommandID: "respond-sessionless-approval", ThreadID: threadID, RequestID: "approval-1", Decision: provider.ApprovalDecisionAccept, OptionID: "allow"}); err != nil {
			t.Fatalf("thread.approval.respond: %v", err)
		}
		waitForReactorIdle(t, reactor, threadID)
		if calls := fake.respondCallCount(); calls != 0 {
			t.Fatalf("RespondToRequest calls = %d, want none without a provider session", calls)
		}
	})

	t.Run("unknown request", func(t *testing.T) {
		engine := NewEngine()
		defer engine.Close()
		fake := newFakeProviderRuntime()
		reactor := newTestReactor(engine, fake)
		threadID := ThreadID("thread-unknown-approval")
		setupApprovalThread(t, engine, threadID, true)

		reactor.handleApprovalResponse(Event{Type: EventThreadApprovalResponseRequested, Payload: EventPayload{ThreadID: threadID, RequestID: "missing", Decision: provider.ApprovalDecisionAccept}})
		if calls := fake.respondCallCount(); calls != 0 {
			t.Fatalf("RespondToRequest calls = %d, want none for an unknown request", calls)
		}
		thread, _ := engine.Thread(threadID)
		items := thread.Timeline.Items()
		if len(items) != 1 || items[0].Kind != provider.ItemKindError || !strings.Contains(items[0].Title, "unknown approval request") {
			t.Fatalf("items = %#v, want visible unknown-request error", items)
		}
	})
}
