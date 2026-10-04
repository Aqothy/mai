package providerservice

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

func fakeInstanceConfig(command []string) json.RawMessage {
	config, err := json.Marshal(map[string]any{"command": command})
	if err != nil {
		panic(err)
	}
	return config
}

// fakeSpec is a launchable fake instance spec whose config names its agent.
func fakeSpec(id provider.InstanceID) provider.InstanceSpec {
	return provider.InstanceSpec{InstanceID: id, Name: string(id), Driver: "fake", Config: fakeInstanceConfig([]string{string(id) + "-agent"})}
}

// fakeAdapter launches one fakeProviderInstance per StartInstance call and
// records every launch's config, instance and event listener in order.
type fakeAdapter struct {
	mu        sync.Mutex
	configs   []string
	instances []*fakeProviderInstance
	listeners []provider.RuntimeEventListener
	// beforeLaunch runs before launch n (1-based); it may block or fail it.
	beforeLaunch func(ctx context.Context, n int) error
	// configure customizes each launched instance before it is returned.
	configure func(*fakeProviderInstance)
}

func (a *fakeAdapter) StartInstance(ctx context.Context, spec provider.InstanceSpec, emit provider.RuntimeEventListener) (ProviderInstance, error) {
	a.mu.Lock()
	a.configs = append(a.configs, string(spec.Config))
	n := len(a.configs)
	beforeLaunch, configure := a.beforeLaunch, a.configure
	a.mu.Unlock()
	if beforeLaunch != nil {
		if err := beforeLaunch(ctx, n); err != nil {
			return nil, err
		}
	}
	instance := &fakeProviderInstance{info: provider.InstanceInfo{
		InstanceID: spec.InstanceID, Name: spec.Name, Driver: spec.Driver, Status: provider.InstanceStatusInitialized, PID: n,
		Capabilities: provider.Capabilities{SessionList: true, SessionDelete: true, SessionClose: true, AdditionalDirectories: true},
	}}
	if configure != nil {
		configure(instance)
	}
	a.mu.Lock()
	a.instances = append(a.instances, instance)
	a.listeners = append(a.listeners, emit)
	a.mu.Unlock()
	return instance, nil
}

func (a *fakeAdapter) launchConfigs() []string {
	a.mu.Lock()
	defer a.mu.Unlock()
	return append([]string(nil), a.configs...)
}

// instance returns the index-th successfully launched instance.
func (a *fakeAdapter) instance(index int) *fakeProviderInstance {
	a.mu.Lock()
	defer a.mu.Unlock()
	if index < 0 || index >= len(a.instances) {
		return nil
	}
	return a.instances[index]
}

// latest returns the most recently launched instance for id.
func (a *fakeAdapter) latest(id provider.InstanceID) *fakeProviderInstance {
	a.mu.Lock()
	defer a.mu.Unlock()
	for index := len(a.instances) - 1; index >= 0; index-- {
		if a.instances[index].info.InstanceID == id {
			return a.instances[index]
		}
	}
	return nil
}

// emit publishes event through the index-th launched instance's listener.
func (a *fakeAdapter) emit(index int, event provider.RuntimeEvent) {
	a.mu.Lock()
	listener := a.listeners[index]
	a.mu.Unlock()
	listener(event)
}

// resumableSessions makes an instance report native session "sess-1" and echo
// the resume cursor it is given (sess-1's cursor for a new session).
func resumableSessions(instance *fakeProviderInstance) {
	instance.startSession = func(input provider.StartSessionInput) (provider.Session, error) {
		cursor := input.ResumeCursor
		if len(cursor) == 0 {
			cursor = json.RawMessage(`{"sessionId":"sess-1"}`)
		}
		return provider.Session{ProviderInstanceID: input.ProviderInstanceID, ProviderSessionID: "sess-1", ThreadID: input.ThreadID, ResumeCursor: append(json.RawMessage(nil), cursor...)}, nil
	}
}

func newFakeService(t *testing.T, adapter *fakeAdapter, opts ...Option) *Service {
	t.Helper()
	s := New(adapter.StartInstance, opts...)
	t.Cleanup(s.Close)
	return s
}

func mustStartInstance(t *testing.T, s *Service, spec provider.InstanceSpec, restart bool) provider.InstanceInfo {
	t.Helper()
	info, err := s.StartInstance(context.Background(), spec, restart)
	if err != nil {
		t.Fatalf("StartInstance(%s, restart=%t): %v", spec.InstanceID, restart, err)
	}
	return info
}

func mustStartSession(t *testing.T, s *Service, threadID string, input provider.StartSessionInput) provider.StartSessionResult {
	t.Helper()
	input.ThreadID = threadID
	result, err := s.StartSession(context.Background(), threadID, input)
	if err != nil {
		t.Fatalf("StartSession(%s on %s): %v", threadID, input.ProviderInstanceID, err)
	}
	return result
}

// startedRoute starts the codex instance and binds thread-1 to it.
func startedRoute(t *testing.T, adapter *fakeAdapter, opts ...Option) *Service {
	t.Helper()
	s := newFakeService(t, adapter, opts...)
	mustStartInstance(t, s, fakeSpec("codex"), false)
	mustStartSession(t, s, "thread-1", provider.StartSessionInput{ProviderInstanceID: "codex"})
	return s
}

type fakeProviderInstance struct {
	mu                 sync.Mutex
	info               provider.InstanceInfo
	closed             bool
	startInputs        []provider.StartSessionInput
	sendTurns          []provider.SendTurnInput
	calls              []string
	startSession       func(provider.StartSessionInput) (provider.Session, error)
	startReplay        []provider.RuntimeEvent
	historyUnavailable bool
	sendTurn           func(context.Context, provider.SendTurnInput) error
	stopSession        func(context.Context, provider.StopSessionInput) error
	deleteSess         func(context.Context, string) error
	forkInputs         []provider.ForkSessionInput
	forkSession        func(context.Context, provider.ForkSessionInput) (provider.ForkSessionResult, error)
}

type fakeLoginProvider struct {
	*fakeProviderInstance
	authenticateCalls int
	logoutCalls       int
}

func (i *fakeLoginProvider) AuthenticateWithInput(context.Context, provider.AuthenticateInput) (provider.AuthenticationResult, error) {
	i.mu.Lock()
	i.authenticateCalls++
	i.mu.Unlock()
	return provider.AuthenticationResult{Instance: i.Info()}, nil
}

func (i *fakeLoginProvider) Logout(context.Context) (provider.InstanceInfo, error) {
	i.mu.Lock()
	i.logoutCalls++
	i.mu.Unlock()
	return i.Info(), nil
}

func (i *fakeProviderInstance) Info() provider.InstanceInfo {
	i.mu.Lock()
	defer i.mu.Unlock()
	return i.info
}
func (i *fakeProviderInstance) Close() error {
	i.mu.Lock()
	defer i.mu.Unlock()
	i.closed = true
	return nil
}
func (i *fakeProviderInstance) StartSession(_ context.Context, input provider.StartSessionInput) (provider.StartSessionResult, error) {
	i.mu.Lock()
	i.startInputs = append(i.startInputs, input)
	i.calls = append(i.calls, "StartSession")
	start := i.startSession
	replay := append([]provider.RuntimeEvent(nil), i.startReplay...)
	historyUnavailable := i.historyUnavailable
	i.mu.Unlock()
	if start != nil {
		session, err := start(input)
		return provider.StartSessionResult{Session: session, Replay: replay, HistoryUnavailable: historyUnavailable}, err
	}
	return provider.StartSessionResult{Session: provider.Session{ProviderInstanceID: input.ProviderInstanceID, ThreadID: input.ThreadID}, Replay: replay, HistoryUnavailable: historyUnavailable}, nil
}
func (i *fakeProviderInstance) SendTurn(ctx context.Context, input provider.SendTurnInput) error {
	i.mu.Lock()
	i.sendTurns = append(i.sendTurns, input)
	i.calls = append(i.calls, "SendTurn")
	send := i.sendTurn
	i.mu.Unlock()
	if send != nil {
		return send(ctx, input)
	}
	return nil
}
func (i *fakeProviderInstance) InterruptTurn(context.Context, provider.InterruptTurnInput) error {
	i.recordCall("InterruptTurn")
	return nil
}
func (i *fakeProviderInstance) SetConfigOption(context.Context, provider.SetConfigOptionInput) error {
	i.recordCall("SetConfigOption")
	return nil
}
func (i *fakeProviderInstance) RespondToRequest(context.Context, provider.RespondToRequestInput) error {
	i.recordCall("RespondToRequest")
	return nil
}
func (i *fakeProviderInstance) StopSession(ctx context.Context, input provider.StopSessionInput) error {
	i.mu.Lock()
	i.calls = append(i.calls, "StopSession")
	stop := i.stopSession
	i.mu.Unlock()
	if stop != nil {
		return stop(ctx, input)
	}
	return nil
}
func (i *fakeProviderInstance) ListSessions(context.Context, string) ([]provider.SessionSummary, error) {
	return nil, nil
}
func (i *fakeProviderInstance) DeleteSession(ctx context.Context, sessionID string) error {
	i.mu.Lock()
	i.calls = append(i.calls, "DeleteSession")
	del := i.deleteSess
	i.mu.Unlock()
	if del != nil {
		return del(ctx, sessionID)
	}
	return nil
}
func (i *fakeProviderInstance) CloseSession(context.Context, string) error {
	i.recordCall("CloseSession")
	return nil
}

func (i *fakeProviderInstance) ForkSession(ctx context.Context, input provider.ForkSessionInput) (provider.ForkSessionResult, error) {
	i.mu.Lock()
	i.calls = append(i.calls, "ForkSession")
	i.forkInputs = append(i.forkInputs, input)
	fork := i.forkSession
	i.mu.Unlock()
	if fork != nil {
		return fork(ctx, input)
	}
	return provider.ForkSessionResult{}, nil
}

func (i *fakeProviderInstance) recordCall(name string) {
	i.mu.Lock()
	defer i.mu.Unlock()
	i.calls = append(i.calls, name)
}

func (i *fakeProviderInstance) lastStartInput() provider.StartSessionInput {
	i.mu.Lock()
	defer i.mu.Unlock()
	if len(i.startInputs) == 0 {
		return provider.StartSessionInput{}
	}
	return i.startInputs[len(i.startInputs)-1]
}

func (i *fakeProviderInstance) startInputCount() int {
	i.mu.Lock()
	defer i.mu.Unlock()
	return len(i.startInputs)
}

func (i *fakeProviderInstance) sendTurnCount() int {
	i.mu.Lock()
	defer i.mu.Unlock()
	return len(i.sendTurns)
}

func (i *fakeProviderInstance) operationCount(name string) int {
	i.mu.Lock()
	defer i.mu.Unlock()
	count := 0
	for _, call := range i.calls {
		if call == name {
			count++
		}
	}
	return count
}

func TestStartInstanceSerializesConcurrentStartsForSameInstance(t *testing.T) {
	entered := make(chan struct{}, 2)
	release := make(chan struct{})
	adapter := &fakeAdapter{beforeLaunch: func(ctx context.Context, _ int) error {
		entered <- struct{}{}
		select {
		case <-release:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}}
	s := newFakeService(t, adapter)

	var wg sync.WaitGroup
	results := make(chan provider.InstanceInfo, 2)
	errs := make(chan error, 2)
	start := func() {
		wg.Add(1)
		go func() {
			defer wg.Done()
			conn, err := s.StartInstance(context.Background(), fakeSpec("codex"), false)
			if err != nil {
				errs <- err
				return
			}
			results <- conn
		}()
	}
	start()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("first start did not enter the provider factory")
	}
	start()
	secondFactoryCall := false
	select {
	case <-entered:
		secondFactoryCall = true
	case <-time.After(100 * time.Millisecond):
	}
	close(release)
	wg.Wait()
	close(results)
	close(errs)
	for err := range errs {
		t.Fatalf("StartInstance error: %v", err)
	}
	if secondFactoryCall || len(adapter.launchConfigs()) != 1 {
		t.Fatalf("launches = %d, want the concurrent start to wait for and reuse the first instance", len(adapter.launchConfigs()))
	}
	for conn := range results {
		if conn.PID != 1 {
			t.Fatalf("connection PID = %d, want reused first instance", conn.PID)
		}
	}
}

func TestStartInstanceReusesSemanticallyEqualConfiguration(t *testing.T) {
	adapter := &fakeAdapter{}
	s := newFakeService(t, adapter)

	first := provider.InstanceSpec{InstanceID: "codex", Name: "codex", Driver: "fake", Config: json.RawMessage(`{"command":["agent"],"env":{"A":"B"}}`)}
	second := provider.InstanceSpec{InstanceID: "codex", Name: "codex", Driver: "fake", Config: json.RawMessage(`{"env":{"A":"B"},"command":["agent"]}`)}
	firstInfo := mustStartInstance(t, s, first, false)
	secondInfo := mustStartInstance(t, s, second, false)
	if launches := len(adapter.launchConfigs()); launches != 1 || secondInfo.PID != firstInfo.PID {
		t.Fatalf("launches/PIDs = %d/%d/%d, want one reused instance", launches, firstInfo.PID, secondInfo.PID)
	}
}

func TestStartSessionRespawnsExitedProviderInstance(t *testing.T) {
	adapter := &fakeAdapter{}
	s := startedRoute(t, adapter)
	first := adapter.instance(0)
	first.mu.Lock()
	first.info.Status = provider.InstanceStatusExited
	first.mu.Unlock()

	mustStartSession(t, s, "thread-1", provider.StartSessionInput{ProviderInstanceID: "codex"})
	second := adapter.instance(1)
	if second == nil || second.startInputCount() != 1 {
		t.Fatalf("replacement instance = %#v, want the exited instance respawned for the session", second)
	}
	if got := first.startInputCount(); got != 1 {
		t.Fatalf("exited instance StartSession calls = %d, want only the initial call", got)
	}
}

func TestStartInstanceConfigurationChangeRequiresRestart(t *testing.T) {
	adapter := &fakeAdapter{}
	s := newFakeService(t, adapter)

	first := fakeSpec("codex")
	changed := first
	changed.Config = fakeInstanceConfig([]string{"agent-b"})
	mustStartInstance(t, s, first, false)
	if _, err := s.StartInstance(context.Background(), changed, false); err == nil || !strings.Contains(err.Error(), "different configuration") {
		t.Fatalf("changed StartInstance err = %v, want restart-required error", err)
	}
	if launches := len(adapter.launchConfigs()); launches != 1 {
		t.Fatalf("launches after rejected change = %d, want 1", launches)
	}
	mustStartInstance(t, s, changed, true)
	if launches := len(adapter.launchConfigs()); launches != 2 {
		t.Fatalf("launches after restart = %d, want 2", launches)
	}
}

func TestRuntimeEventsDoNotRebindThreadRoute(t *testing.T) {
	adapter := &fakeAdapter{}
	s := newFakeService(t, adapter)

	mustStartInstance(t, s, fakeSpec("old"), false)
	mustStartSession(t, s, "thread-1", provider.StartSessionInput{ProviderInstanceID: "old"})
	mustStartInstance(t, s, fakeSpec("new"), false)
	mustStartSession(t, s, "thread-1", provider.StartSessionInput{ProviderInstanceID: "new"})

	adapter.emit(0, provider.RuntimeEvent{EventID: "late-old", Type: provider.RuntimeEventThreadMetadataUpdate, ThreadID: "thread-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{Title: "late old event"}})
	if err := s.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", Input: "hello"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	if old, current := adapter.latest("old").sendTurnCount(), adapter.latest("new").sendTurnCount(); old != 0 || current != 1 {
		t.Fatalf("send turns routed old=%d new=%d, want old=0 new=1 after stale old event", old, current)
	}
}

func TestRuntimeEventSourceIdentityComesFromEmittingInstance(t *testing.T) {
	adapter := &fakeAdapter{}
	s := newFakeService(t, adapter)
	events := s.Events()

	spec := fakeSpec("old")
	spec.Name = "Old Provider"
	mustStartInstance(t, s, spec, false)
	adapter.emit(0, provider.RuntimeEvent{EventID: "spoofed", Type: provider.RuntimeEventThreadMetadataUpdate, Provider: "spoofed-driver", ProviderInstanceID: "spoofed-instance", ProviderName: "Spoofed", ThreadID: "thread-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{Title: "hello"}})

	select {
	case event := <-events:
		if event.ProviderInstanceID != "old" || event.ProviderName != "Old Provider" || event.Provider != "fake" {
			t.Fatalf("event source = (%q,%q,%q), want emitting instance identity", event.ProviderInstanceID, event.ProviderName, event.Provider)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for runtime event")
	}
}

func TestStartSessionNormalizesAdapterReturnedInstanceIDToRequestedInstance(t *testing.T) {
	adapter := &fakeAdapter{}
	s := newFakeService(t, adapter)

	mustStartInstance(t, s, fakeSpec("old"), false)
	newSpec := fakeSpec("new")
	newSpec.Name = "New Provider"
	mustStartInstance(t, s, newSpec, false)
	newInstance := adapter.latest("new")
	newInstance.mu.Lock()
	newInstance.startSession = func(input provider.StartSessionInput) (provider.Session, error) {
		return provider.Session{Provider: "spoofed", ProviderInstanceID: "old", ProviderName: "Old Provider", ThreadID: input.ThreadID, ResumeCursor: json.RawMessage(`{"sessionId":"new-session"}`)}, nil
	}
	newInstance.mu.Unlock()

	result := mustStartSession(t, s, "thread-1", provider.StartSessionInput{ProviderInstanceID: "new"})
	if result.Session.ProviderInstanceID != "new" || result.Session.ProviderName != "New Provider" || result.Session.Provider != "fake" {
		t.Fatalf("session identity = (%q,%q,%q), want selected new provider identity", result.Session.ProviderInstanceID, result.Session.ProviderName, result.Session.Provider)
	}
	mustStartSession(t, s, "thread-1", provider.StartSessionInput{ProviderInstanceID: "new"})
	if got := string(newInstance.lastStartInput().ResumeCursor); got != `{"sessionId":"new-session"}` {
		t.Fatalf("resume cursor for selected instance = %s, want new-session cursor", got)
	}
	if err := s.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", Input: "hello"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	if old, current := adapter.latest("old").sendTurnCount(), newInstance.sendTurnCount(); old != 0 || current != 1 {
		t.Fatalf("send turns routed old=%d new=%d, want old=0 new=1", old, current)
	}
}

func TestStartInstanceCreatedDuringCloseIsClosedAndRejected(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	adapter := &fakeAdapter{beforeLaunch: func(ctx context.Context, _ int) error {
		close(entered)
		select {
		case <-release:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}}
	s := New(adapter.StartInstance)

	done := make(chan error, 1)
	go func() {
		_, err := s.StartInstance(context.Background(), fakeSpec("codex"), false)
		done <- err
	}()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("provider factory was not entered")
	}

	s.Close()
	close(release)
	if err := <-done; err == nil {
		t.Fatal("StartInstance completed after Close without an error")
	}
	instance := adapter.instance(0)
	instance.mu.Lock()
	closed := instance.closed
	instance.mu.Unlock()
	if !closed {
		t.Fatal("provider instance created during Close was not closed")
	}
	if got := s.ListInstances(); len(got) != 0 {
		t.Fatalf("instances after Close = %#v, want none", got)
	}
}

func restartedEventService(t *testing.T, rebind bool) (*Service, *fakeAdapter) {
	t.Helper()
	adapter := &fakeAdapter{}
	s := startedRoute(t, adapter)
	mustStartInstance(t, s, fakeSpec("codex"), true)
	if rebind {
		mustStartSession(t, s, "thread-1", provider.StartSessionInput{ProviderInstanceID: "codex"})
	}
	return s, adapter
}

func TestRestartDropsNonterminalEventFromReplacedGeneration(t *testing.T) {
	s, adapter := restartedEventService(t, false)

	adapter.emit(0, provider.RuntimeEvent{EventID: "stale-running", Type: provider.RuntimeEventTurnStarted, ThreadID: "thread-1", TurnID: "turn-1", CreatedAt: time.Now()})
	adapter.emit(1, provider.RuntimeEvent{EventID: "fresh", Type: provider.RuntimeEventThreadMetadataUpdate, ThreadID: "thread-1", CreatedAt: time.Now()})
	select {
	case event := <-s.Events():
		if event.EventID != "fresh" {
			t.Fatalf("first event = %q, want stale nonterminal state dropped", event.EventID)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for fresh event")
	}
}

func TestRestartAdmitsOldTerminalEventAfterThreadRebinds(t *testing.T) {
	// A dying generation's TurnCompleted must still settle its turn even after
	// the provider route has moved. ProviderService preserves the event's source
	// generation; orchestration accepts it only until the replacement session is
	// actually bound.
	s, adapter := restartedEventService(t, true)

	adapter.emit(0, provider.RuntimeEvent{EventID: "late-terminal", Type: provider.RuntimeEventTurnCompleted, ThreadID: "thread-1", TurnID: "turn-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{TurnState: provider.RuntimeTurnFailed}})
	select {
	case event := <-s.Events():
		if event.EventID != "late-terminal" {
			t.Fatalf("first event = %q, want late terminal event admitted after rebind", event.EventID)
		}
		if event.Generation == 0 {
			t.Fatal("late terminal event lost its source generation")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for late terminal event")
	}
}

func TestRestartAdmitsTurnScopedRuntimeErrorFromReplacedGeneration(t *testing.T) {
	s, adapter := restartedEventService(t, false)

	// Turn-scoped runtime errors settle sessions and must survive the fence;
	// runtime errors without a turn are not session-settling and stay dropped.
	adapter.emit(0, provider.RuntimeEvent{EventID: "stale-turnless-error", Type: provider.RuntimeEventRuntimeError, ThreadID: "thread-1", CreatedAt: time.Now()})
	adapter.emit(0, provider.RuntimeEvent{EventID: "late-error", Type: provider.RuntimeEventRuntimeError, ThreadID: "thread-1", TurnID: "turn-1", CreatedAt: time.Now()})
	select {
	case event := <-s.Events():
		if event.EventID != "late-error" {
			t.Fatalf("first event = %q, want turn-scoped runtime error admitted (and turnless one dropped)", event.EventID)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for late runtime error")
	}
}

func TestStartSessionReturnsStampedReplayBatch(t *testing.T) {
	adapter := &fakeAdapter{configure: func(instance *fakeProviderInstance) {
		instance.startReplay = []provider.RuntimeEvent{{
			EventID:            "replayed",
			Type:               provider.RuntimeEventContentDelta,
			Provider:           "spoofed",
			ProviderInstanceID: "spoofed",
			ProviderName:       "spoofed",
			ThreadID:           "spoofed",
			Payload: provider.RuntimeEventPayload{
				StreamKind: provider.RuntimeContentAssistantText,
				Delta:      "history",
			},
		}}
	}}
	s := newFakeService(t, adapter)
	spec := fakeSpec("codex")
	spec.Name = "Codex"
	mustStartInstance(t, s, spec, false)

	result := mustStartSession(t, s, "thread-1", provider.StartSessionInput{ProviderInstanceID: "codex", ReplayHistory: true})
	if len(result.Replay) != 1 {
		t.Fatalf("replay = %#v, want one returned event", result.Replay)
	}
	replay := result.Replay[0]
	if replay.ThreadID != "thread-1" || replay.ProviderInstanceID != "codex" || replay.ProviderName != "Codex" || replay.Provider != "fake" || replay.Generation == 0 {
		t.Fatalf("replay identity = %#v, want authoritative service identity", replay)
	}
	if replay.Generation != result.Session.Generation {
		t.Fatalf("replay/session generations = %d/%d, want equal", replay.Generation, result.Session.Generation)
	}
}

// blockRestart makes every launch after the first wait for release and then
// return err.
func blockRestart(entered chan<- struct{}, release <-chan struct{}, err error) func(context.Context, int) error {
	return func(ctx context.Context, n int) error {
		if n == 1 {
			return nil
		}
		close(entered)
		select {
		case <-release:
			return err
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func TestFailedRestartKeepsPreviousProviderProcessEventsActive(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	adapter := &fakeAdapter{beforeLaunch: blockRestart(entered, release, errors.New("restart failed"))}
	s := newFakeService(t, adapter)
	events := s.Events()

	mustStartInstance(t, s, fakeSpec("codex"), false)
	errs := make(chan error, 1)
	go func() {
		_, err := s.StartInstance(context.Background(), fakeSpec("codex"), true)
		errs <- err
	}()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("restart did not enter adapter start")
	}

	expectOldProcessEvent := func(eventID provider.RuntimeEventID) {
		t.Helper()
		adapter.emit(0, provider.RuntimeEvent{EventID: eventID, Type: provider.RuntimeEventThreadMetadataUpdate, ThreadID: "thread-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{Title: "still live"}})
		select {
		case event := <-events:
			if event.EventID != eventID {
				t.Fatalf("event = %q, want %q", event.EventID, eventID)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("timed out waiting for old provider process event %q", eventID)
		}
	}
	expectOldProcessEvent("old-process-during-failed-restart")
	close(release)
	if err := <-errs; err == nil {
		t.Fatal("restart error = nil, want failure")
	}
	expectOldProcessEvent("old-process-after-failed-restart")
}

func TestStartSessionWaitsForInFlightRestartBeforeBindingAndSending(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	adapter := &fakeAdapter{beforeLaunch: blockRestart(entered, release, nil)}
	s := newFakeService(t, adapter)

	mustStartInstance(t, s, fakeSpec("codex"), false)
	restartDone := make(chan error, 1)
	go func() {
		_, err := s.StartInstance(context.Background(), fakeSpec("codex"), true)
		restartDone <- err
	}()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("restart did not enter adapter start")
	}

	sessionDone := make(chan error, 1)
	go func() {
		_, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ThreadID: "thread-1", ProviderInstanceID: "codex"})
		sessionDone <- err
	}()
	select {
	case err := <-sessionDone:
		t.Fatalf("StartSession completed during in-flight restart with err=%v; want it to wait for replacement", err)
	case <-time.After(50 * time.Millisecond):
	}

	close(release)
	if err := <-restartDone; err != nil {
		t.Fatalf("restart StartInstance: %v", err)
	}
	if err := <-sessionDone; err != nil {
		t.Fatalf("StartSession after restart: %v", err)
	}
	if err := s.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", Input: "hello"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}

	first, second := adapter.instance(0), adapter.instance(1)
	if first.startInputCount() != 0 || first.sendTurnCount() != 0 {
		t.Fatalf("old instance used: starts=%d sends=%d, want 0/0", first.startInputCount(), first.sendTurnCount())
	}
	if second.startInputCount() != 1 || second.sendTurnCount() != 1 {
		t.Fatalf("new instance starts=%d sends=%d, want 1/1", second.startInputCount(), second.sendTurnCount())
	}
}

func TestSendTurnDoesNotSerializeConcurrentTurnsForSameInstance(t *testing.T) {
	adapter := &fakeAdapter{}
	s := startedRoute(t, adapter)
	mustStartSession(t, s, "thread-2", provider.StartSessionInput{ProviderInstanceID: "codex"})

	instance := adapter.instance(0)
	entered := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	instance.mu.Lock()
	instance.sendTurn = func(ctx context.Context, input provider.SendTurnInput) error {
		if input.ThreadID != "thread-1" {
			return nil
		}
		once.Do(func() { close(entered) })
		select {
		case <-release:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	instance.mu.Unlock()

	firstDone := make(chan error, 1)
	go func() {
		firstDone <- s.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", Input: "slow"})
	}()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("first SendTurn did not enter provider")
	}

	secondDone := make(chan error, 1)
	go func() {
		secondDone <- s.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-2", Input: "fast"})
	}()
	select {
	case err := <-secondDone:
		if err != nil {
			t.Fatalf("second SendTurn: %v", err)
		}
	case <-time.After(100 * time.Millisecond):
		t.Fatal("second SendTurn was blocked by another thread on the same provider instance")
	}

	close(release)
	if err := <-firstDone; err != nil {
		t.Fatalf("first SendTurn: %v", err)
	}
}

func TestSessionManagementRejectsBoundSessionAfterProviderRestart(t *testing.T) {
	tests := []struct {
		name string
		call func(*Service) error
		want string
	}{
		{name: "delete", call: func(s *Service) error { return s.DeleteSession(context.Background(), "codex", "sess-1") }, want: "DeleteSession"},
		{name: "close", call: func(s *Service) error { return s.CloseSession(context.Background(), "codex", "sess-1") }, want: "CloseSession"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			adapter := &fakeAdapter{configure: resumableSessions}
			s := startedRoute(t, adapter)
			mustStartInstance(t, s, fakeSpec("codex"), true)

			if err := tt.call(s); err == nil || !strings.Contains(err.Error(), "bound to thread") {
				t.Fatalf("%s bound session err = %v, want rejection", tt.name, err)
			}
			if got := adapter.instance(1).operationCount(tt.want); got != 0 {
				t.Fatalf("replacement adapter %s calls = %d, want 0", tt.want, got)
			}
		})
	}
}

func TestSlowSessionDeleteDoesNotBlockStartSessionOnSameInstance(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	adapter := &fakeAdapter{configure: func(instance *fakeProviderInstance) {
		instance.deleteSess = func(ctx context.Context, _ string) error {
			close(entered)
			select {
			case <-release:
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		}
	}}
	s := newFakeService(t, adapter)
	mustStartInstance(t, s, fakeSpec("codex"), false)

	deleteDone := make(chan error, 1)
	go func() {
		deleteDone <- s.DeleteSession(context.Background(), "codex", "sess-unbound")
	}()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("DeleteSession did not reach the adapter")
	}

	startDone := make(chan error, 1)
	go func() {
		_, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ThreadID: "thread-1", ProviderInstanceID: "codex"})
		startDone <- err
	}()
	select {
	case err := <-startDone:
		if err != nil {
			t.Fatalf("StartSession during slow delete: %v", err)
		}
	case <-time.After(500 * time.Millisecond):
		t.Fatal("StartSession was blocked by a slow DeleteSession on the same instance")
	}

	close(release)
	if err := <-deleteDone; err != nil {
		t.Fatalf("DeleteSession: %v", err)
	}
}

func TestSessionManagementRPCContextIsBounded(t *testing.T) {
	deadlines := make(chan bool, 1)
	adapter := &fakeAdapter{configure: func(instance *fakeProviderInstance) {
		instance.deleteSess = func(ctx context.Context, _ string) error {
			_, hasDeadline := ctx.Deadline()
			deadlines <- hasDeadline
			return nil
		}
	}}
	s := newFakeService(t, adapter)
	mustStartInstance(t, s, fakeSpec("codex"), false)

	// The client's request context has no deadline; the service must impose one
	// so a hung agent cannot pin the RPC for as long as the client stays.
	if err := s.DeleteSession(context.Background(), "codex", "sess-unbound"); err != nil {
		t.Fatalf("DeleteSession: %v", err)
	}
	if !<-deadlines {
		t.Fatal("session-management adapter RPC ran without a deadline")
	}
}

func TestStartSessionReusesStoredResumeCursorAfterRestart(t *testing.T) {
	adapter := &fakeAdapter{configure: resumableSessions}
	s := newFakeService(t, adapter)
	mustStartInstance(t, s, fakeSpec("codex"), false)
	firstResult := mustStartSession(t, s, "thread-1", provider.StartSessionInput{ProviderInstanceID: "codex"})
	mustStartInstance(t, s, fakeSpec("codex"), true)
	secondResult := mustStartSession(t, s, "thread-1", provider.StartSessionInput{ProviderInstanceID: "codex"})
	if firstResult.Session.Generation == 0 || secondResult.Session.Generation == 0 || firstResult.Session.Generation == secondResult.Session.Generation {
		t.Fatalf("session generations before/after restart = %d/%d, want distinct non-zero generations", firstResult.Session.Generation, secondResult.Session.Generation)
	}
	if got := string(adapter.instance(1).lastStartInput().ResumeCursor); got != `{"sessionId":"sess-1"}` {
		t.Fatalf("resume cursor passed after restart = %s, want sess-1 cursor", got)
	}
}

func failStopSession(instance *fakeProviderInstance, err error) {
	instance.mu.Lock()
	instance.stopSession = func(context.Context, provider.StopSessionInput) error { return err }
	instance.mu.Unlock()
}

func TestSwitchingProviderSucceedsWhenPreviousInstanceStopFails(t *testing.T) {
	adapter := &fakeAdapter{}
	s := newFakeService(t, adapter)
	mustStartInstance(t, s, fakeSpec("old"), false)
	mustStartInstance(t, s, fakeSpec("new"), false)
	mustStartSession(t, s, "thread-1", provider.StartSessionInput{ProviderInstanceID: "old"})
	oldInstance := adapter.latest("old")
	failStopSession(oldInstance, errors.New("agent process is gone"))

	mustStartSession(t, s, "thread-1", provider.StartSessionInput{ProviderInstanceID: "new"})
	if got := oldInstance.operationCount("StopSession"); got != 1 {
		t.Fatalf("old provider StopSession calls = %d, want 1", got)
	}
	if err := s.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", Input: "hello"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	if old, current := oldInstance.sendTurnCount(), adapter.latest("new").sendTurnCount(); old != 0 || current != 1 {
		t.Fatalf("send turns routed old=%d new=%d, want old=0 new=1 after rebind", old, current)
	}
}

func TestReleaseSessionDropsRouteWhenProviderStopFails(t *testing.T) {
	adapter := &fakeAdapter{}
	s := startedRoute(t, adapter)
	failStopSession(adapter.instance(0), errors.New("agent process is gone"))

	if err := s.ReleaseSession(context.Background(), provider.StopSessionInput{ThreadID: "thread-1"}); err != nil {
		t.Fatalf("ReleaseSession: %v", err)
	}
	if got := adapter.instance(0).operationCount("StopSession"); got != 1 {
		t.Fatalf("provider StopSession calls = %d, want 1", got)
	}
	if err := s.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", Input: "must not route"}); err == nil || !strings.Contains(err.Error(), "no provider session route") {
		t.Fatalf("SendTurn after release err = %v, want no provider session route", err)
	}
}

func TestSwitchingProviderSkipsStopWhenRouteGenerationIsStale(t *testing.T) {
	adapter := &fakeAdapter{}
	s := newFakeService(t, adapter)
	mustStartInstance(t, s, fakeSpec("old"), false)
	mustStartInstance(t, s, fakeSpec("new"), false)
	mustStartSession(t, s, "thread-1", provider.StartSessionInput{ProviderInstanceID: "old"})
	// Restart "old" so the thread's route points at a replaced generation: the
	// session died with the old process, so the switch must not RPC a stop.
	mustStartInstance(t, s, fakeSpec("old"), true)
	replacement := adapter.latest("old")
	failStopSession(replacement, errors.New("should not be called for a stale-generation route"))

	mustStartSession(t, s, "thread-1", provider.StartSessionInput{ProviderInstanceID: "new"})
	if got := replacement.operationCount("StopSession"); got != 0 {
		t.Fatalf("replacement StopSession calls = %d, want 0 for stale-generation route", got)
	}
	if err := s.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", Input: "hello"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	if got := adapter.latest("new").sendTurnCount(); got != 1 {
		t.Fatalf("new instance send turns = %d, want 1 after rebind", got)
	}
}

func TestStartSessionClearsStoredResumeCursorWhenReboundSessionReturnsNone(t *testing.T) {
	adapter := &fakeAdapter{}
	s := newFakeService(t, adapter)
	mustStartInstance(t, s, fakeSpec("old"), false)
	oldInstance := adapter.latest("old")
	oldInstance.startSession = func(input provider.StartSessionInput) (provider.Session, error) {
		return provider.Session{ProviderInstanceID: "old", ThreadID: input.ThreadID, ResumeCursor: json.RawMessage(`{"sessionId":"old-session"}`)}, nil
	}
	mustStartSession(t, s, "thread-1", provider.StartSessionInput{ProviderInstanceID: "old"})
	mustStartInstance(t, s, fakeSpec("new"), false)
	mustStartSession(t, s, "thread-1", provider.StartSessionInput{ProviderInstanceID: "new"})
	mustStartSession(t, s, "thread-1", provider.StartSessionInput{ProviderInstanceID: "new"})

	if got := string(adapter.latest("new").lastStartInput().ResumeCursor); got != "" {
		t.Fatalf("resume cursor passed after no-cursor rebind = %s, want empty", got)
	}
}

func TestStopSessionDropsStoredResumeCursorSoNextTurnStartsFresh(t *testing.T) {
	adapter := &fakeAdapter{configure: resumableSessions}
	s := startedRoute(t, adapter)
	if err := s.StopSession(context.Background(), provider.StopSessionInput{ThreadID: "thread-1"}); err != nil {
		t.Fatalf("StopSession: %v", err)
	}
	mustStartSession(t, s, "thread-1", provider.StartSessionInput{ProviderInstanceID: "codex"})

	if got := string(adapter.instance(0).lastStartInput().ResumeCursor); got != "" {
		t.Fatalf("resume cursor passed after stop = %s, want empty (stop unbinds; the next turn starts a fresh session)", got)
	}
}

func TestThreadScopedOperationsRecoverStaleRouteBeforeAdapterCall(t *testing.T) {
	tests := []struct {
		name string
		call func(*Service) error
		want string
	}{
		{
			name: "interrupt",
			call: func(s *Service) error {
				return s.InterruptTurn(context.Background(), provider.InterruptTurnInput{ThreadID: "thread-1", TurnID: "turn-1"})
			},
			want: "InterruptTurn",
		},
		{
			name: "set config option",
			call: func(s *Service) error {
				return s.SetConfigOption(context.Background(), provider.SetConfigOptionInput{ThreadID: "thread-1", OptionID: "model", Value: "fast"})
			},
			want: "SetConfigOption",
		},
		{
			name: "respond to request",
			call: func(s *Service) error {
				return s.RespondToRequest(context.Background(), provider.RespondToRequestInput{ThreadID: "thread-1", RequestID: "req-1", Decision: provider.ApprovalDecisionAccept})
			},
			want: "RespondToRequest",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			adapter := &fakeAdapter{configure: resumableSessions}
			s := startedRoute(t, adapter)
			mustStartInstance(t, s, fakeSpec("codex"), true)
			if err := tt.call(s); err != nil {
				t.Fatalf("%s: %v", tt.name, err)
			}

			first, second := adapter.instance(0), adapter.instance(1)
			if got := first.operationCount(tt.want); got != 0 {
				t.Fatalf("old instance %s calls = %d, want 0", tt.want, got)
			}
			if got := second.operationCount(tt.want); got != 1 {
				t.Fatalf("new instance %s calls = %d, want 1", tt.want, got)
			}
			if got := string(second.lastStartInput().ResumeCursor); got != `{"sessionId":"sess-1"}` {
				t.Fatalf("recovered session resume cursor = %s, want sess-1 cursor", got)
			}
		})
	}
}

func TestPreferenceChangesSurviveProviderRestart(t *testing.T) {
	adapter := &fakeAdapter{configure: resumableSessions}
	s := newFakeService(t, adapter)
	mustStartInstance(t, s, fakeSpec("codex"), false)
	mustStartSession(t, s, "thread-1", provider.StartSessionInput{ProviderInstanceID: "codex", ModelSelection: &provider.ModelSelection{Model: "slow"}})
	if err := s.SetConfigOption(context.Background(), provider.SetConfigOptionInput{ThreadID: "thread-1", OptionID: "model", Value: "fast", Category: provider.ConfigOptionCategoryModel}); err != nil {
		t.Fatalf("SetConfigOption model: %v", err)
	}
	if err := s.SetConfigOption(context.Background(), provider.SetConfigOptionInput{ThreadID: "thread-1", OptionID: "reasoning", Value: "high"}); err != nil {
		t.Fatalf("SetConfigOption reasoning: %v", err)
	}
	// A boolean option can carry the model category; the provider applies it,
	// so the service must not fail — it only skips recording a model preference.
	if err := s.SetConfigOption(context.Background(), provider.SetConfigOptionInput{ThreadID: "thread-1", OptionID: "fast", Value: true, Category: provider.ConfigOptionCategoryModel}); err != nil {
		t.Fatalf("SetConfigOption boolean model-category option: %v", err)
	}
	if got := adapter.instance(0).operationCount("SetConfigOption"); got != 3 {
		t.Fatalf("SetConfigOption calls = %d, want 3", got)
	}
	mustStartInstance(t, s, fakeSpec("codex"), true)
	if err := s.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", Input: "hello"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}

	input := adapter.instance(1).lastStartInput()
	if input.ModelSelection == nil || input.ModelSelection.Model != "fast" {
		t.Fatalf("recovered model selection = %#v, want fast", input.ModelSelection)
	}
	if len(input.ConfigSelections) != 1 || input.ConfigSelections[0].OptionID != "reasoning" || input.ConfigSelections[0].Value != "high" {
		t.Fatalf("recovered config selections = %#v, want reasoning=high", input.ConfigSelections)
	}
}

func TestStopSessionDoesNotRecoverStaleRouteAfterRestart(t *testing.T) {
	adapter := &fakeAdapter{configure: resumableSessions}
	s := startedRoute(t, adapter)
	mustStartInstance(t, s, fakeSpec("codex"), true)
	if err := s.StopSession(context.Background(), provider.StopSessionInput{ThreadID: "thread-1"}); err != nil {
		t.Fatalf("StopSession: %v", err)
	}

	second := adapter.instance(1)
	if got := second.startInputCount(); got != 0 {
		t.Fatalf("restart instance start sessions = %d, want 0 for stop", got)
	}
	if got := second.operationCount("StopSession"); got != 1 {
		t.Fatalf("restart instance StopSession calls = %d, want 1", got)
	}
}

func TestServiceGatesAuthenticationCapabilities(t *testing.T) {
	instance := &fakeLoginProvider{fakeProviderInstance: &fakeProviderInstance{info: provider.InstanceInfo{
		InstanceID: "login", Name: "Login", Driver: "test", Status: provider.InstanceStatusInitialized,
	}}}
	s := New(func(context.Context, provider.InstanceSpec, provider.RuntimeEventListener) (ProviderInstance, error) {
		return instance, nil
	})
	defer s.Close()
	if _, err := s.StartInstance(context.Background(), provider.InstanceSpec{InstanceID: "login", Name: "Login", Driver: "test"}, false); err != nil {
		t.Fatalf("StartInstance: %v", err)
	}

	if _, err := s.Authenticate(context.Background(), "login", provider.AuthenticateInput{MethodID: "login"}); err == nil || !strings.Contains(err.Error(), "authentication") {
		t.Fatalf("Authenticate without capability err = %v", err)
	}
	if _, err := s.Logout(context.Background(), "login"); err == nil || !strings.Contains(err.Error(), "logout") {
		t.Fatalf("Logout without capability err = %v", err)
	}
	if instance.authenticateCalls != 0 || instance.logoutCalls != 0 {
		t.Fatalf("unsupported auth calls = authenticate %d, logout %d", instance.authenticateCalls, instance.logoutCalls)
	}

	instance.mu.Lock()
	instance.info.Capabilities.Auth = true
	instance.mu.Unlock()
	if _, err := s.Authenticate(context.Background(), "login", provider.AuthenticateInput{MethodID: "login"}); err != nil {
		t.Fatalf("Authenticate with capability: %v", err)
	}
	if _, err := s.Logout(context.Background(), "login"); err == nil || !strings.Contains(err.Error(), "logout") {
		t.Fatalf("Logout with only auth capability err = %v", err)
	}

	instance.mu.Lock()
	instance.info.Capabilities.Auth = false
	instance.info.Capabilities.Logout = true
	instance.mu.Unlock()
	if _, err := s.Logout(context.Background(), "login"); err != nil {
		t.Fatalf("Logout with capability: %v", err)
	}
	if instance.authenticateCalls != 1 || instance.logoutCalls != 1 {
		t.Fatalf("supported auth calls = authenticate %d, logout %d", instance.authenticateCalls, instance.logoutCalls)
	}
}

func TestForkSessionUsesPrivateRouteAndInheritsWorkspaceRoots(t *testing.T) {
	instance := &fakeProviderInstance{info: provider.InstanceInfo{
		InstanceID: "codex", Name: "Codex", Driver: "codex-app-server",
		Status:       provider.InstanceStatusInitialized,
		Capabilities: provider.Capabilities{Fork: true, AdditionalDirectories: true},
	}}
	instance.startSession = func(input provider.StartSessionInput) (provider.Session, error) {
		sessionID := input.ProviderSessionID
		if sessionID == "" {
			sessionID = "native-source"
		}
		return provider.Session{
			ProviderInstanceID: input.ProviderInstanceID,
			ProviderSessionID:  sessionID,
			ThreadID:           input.ThreadID,
			Cwd:                input.Cwd,
		}, nil
	}
	instance.forkSession = func(_ context.Context, input provider.ForkSessionInput) (provider.ForkSessionResult, error) {
		// The provider receives the source's settings with the fork request.
		if input.ProviderSessionID != "native-source" || input.ModelSelection == nil || input.ModelSelection.Model != "gpt-6-luna" || len(input.ConfigSelections) != 2 || input.ConfigSelections[1].Value != "low" {
			t.Fatalf("fork input = %#v", input)
		}
		return provider.ForkSessionResult{Summary: provider.SessionSummary{SessionID: "native-fork"}}, nil
	}
	s := New(func(context.Context, provider.InstanceSpec, provider.RuntimeEventListener) (ProviderInstance, error) {
		return instance, nil
	})
	defer s.Close()
	if _, err := s.StartInstance(context.Background(), provider.InstanceSpec{InstanceID: "codex", Name: "Codex", Driver: "codex-app-server"}, false); err != nil {
		t.Fatalf("StartInstance: %v", err)
	}
	additional := []string{"/workspace/two", "/workspace/three"}
	if _, err := s.StartSession(context.Background(), "thread-source", provider.StartSessionInput{
		ThreadID: "thread-source", ProviderInstanceID: "codex", Cwd: "/workspace/one", AdditionalDirectories: additional,
		ModelSelection: &provider.ModelSelection{Model: "gpt-6-luna"},
		ConfigSelections: []provider.ConfigOptionSelection{
			{OptionID: "model", Value: "gpt-6-luna", Category: provider.ConfigOptionCategoryModel},
			{OptionID: "reasoning_effort", Value: "low", Category: provider.ConfigOptionCategoryThoughtLevel},
		},
	}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	fork, err := s.ForkSession(context.Background(), "thread-source")
	if err != nil {
		t.Fatalf("ForkSession: %v", err)
	}
	summary := fork.Summary
	if fork.InstanceID != "codex" || summary.SessionID != "native-fork" || summary.Cwd != "/workspace/one" || len(summary.AdditionalDirectories) != 2 || summary.AdditionalDirectories[1] != "/workspace/three" {
		t.Fatalf("fork result = %q, %#v", fork.InstanceID, summary)
	}
	additional[1] = "mutated"
	if summary.AdditionalDirectories[1] != "/workspace/three" {
		t.Fatal("fork summary aliases caller workspace roots")
	}
	settings := fork.Settings
	if settings.ModelSelection == nil || settings.ModelSelection.Model != "gpt-6-luna" || len(settings.ConfigSelections) != 2 || settings.ConfigSelections[1].Value != "low" {
		t.Fatalf("fork settings = %#v, want source Luna/Low", settings)
	}

	// The imported fork route has no live session; its first start must apply
	// the stored settings even when the caller supplies only the model.
	if err := s.RegisterImportedSession("thread-fork", "codex", "native-fork", provider.StartSessionInput{Cwd: summary.Cwd, ModelSelection: settings.ModelSelection, ConfigSelections: settings.ConfigSelections}); err != nil {
		t.Fatalf("RegisterImportedSession: %v", err)
	}
	if _, err := s.StartSession(context.Background(), "thread-fork", provider.StartSessionInput{ProviderInstanceID: "codex", Cwd: summary.Cwd, ModelSelection: &provider.ModelSelection{Model: "gpt-6-luna"}}); err != nil {
		t.Fatalf("open fork: %v", err)
	}
	resume := instance.lastStartInput()
	if resume.ProviderSessionID != "native-fork" || len(resume.ConfigSelections) != 2 || resume.ConfigSelections[1].Value != "low" || resume.Cwd != "/workspace/one" {
		t.Fatalf("fork resume input = %#v, want native-fork at Luna/Low in source cwd", resume)
	}
	instance.mu.Lock()
	instance.forkSession = func(context.Context, provider.ForkSessionInput) (provider.ForkSessionResult, error) {
		return provider.ForkSessionResult{Summary: provider.SessionSummary{SessionID: "native-source"}}, nil
	}
	instance.mu.Unlock()
	if _, err := s.ForkSession(context.Background(), "thread-source"); err == nil || !strings.Contains(err.Error(), "source session id") {
		t.Fatalf("same-session fork err = %v, want source-id rejection", err)
	}
}

func TestServiceGatesProviderSpecificSessionCapabilities(t *testing.T) {
	instance := &fakeProviderInstance{info: provider.InstanceInfo{
		InstanceID: "limited", Name: "Limited", Driver: "limited", Status: provider.InstanceStatusInitialized,
	}}
	s := New(func(context.Context, provider.InstanceSpec, provider.RuntimeEventListener) (ProviderInstance, error) {
		return instance, nil
	})
	defer s.Close()
	if _, err := s.StartInstance(context.Background(), provider.InstanceSpec{InstanceID: "limited", Name: "Limited", Driver: "limited"}, false); err != nil {
		t.Fatalf("StartInstance: %v", err)
	}

	if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{
		ThreadID: "thread-1", ProviderInstanceID: "limited", AdditionalDirectories: []string{"/extra"},
	}); err == nil || !strings.Contains(err.Error(), "additional directories") {
		t.Fatalf("unsupported additional directories err = %v", err)
	}
	if instance.startInputCount() != 0 {
		t.Fatal("unsupported additional directories reached adapter StartSession")
	}
	if _, err := s.ListSessions(context.Background(), "limited", ""); err == nil || !strings.Contains(err.Error(), "session list") {
		t.Fatalf("unsupported list err = %v", err)
	}
	if err := s.DeleteSession(context.Background(), "limited", "session-1"); err == nil || !strings.Contains(err.Error(), "session delete") {
		t.Fatalf("unsupported delete err = %v", err)
	}
	if err := s.CloseSession(context.Background(), "limited", "session-1"); err == nil || !strings.Contains(err.Error(), "session close") {
		t.Fatalf("unsupported close err = %v", err)
	}
	if instance.operationCount("DeleteSession") != 0 || instance.operationCount("CloseSession") != 0 {
		t.Fatal("unsupported lifecycle operation reached adapter")
	}
}
