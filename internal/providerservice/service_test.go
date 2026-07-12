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

type fakeStartAdapter struct {
	mu          sync.Mutex
	starts      int
	startDelay  time.Duration
	instanceSeq int
}

func (a *fakeStartAdapter) StartInstance(ctx context.Context, req provider.InstanceSpec, _ provider.RuntimeEventListener) (ProviderInstance, error) {
	select {
	case <-time.After(a.startDelay):
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	a.mu.Lock()
	a.starts++
	a.instanceSeq++
	seq := a.instanceSeq
	a.mu.Unlock()
	return &fakeProviderInstance{info: provider.InstanceInfo{InstanceID: req.InstanceID, Name: req.Name, Driver: req.Driver, Status: provider.InstanceStatusInitialized, PID: seq}}, nil
}

func (a *fakeStartAdapter) startCount() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.starts
}

type fakeProviderInstance struct {
	mu           sync.Mutex
	info         provider.InstanceInfo
	closed       bool
	startInputs  []provider.StartSessionInput
	sendTurns    []provider.SendTurnInput
	calls        []string
	startSession func(provider.StartSessionInput) (provider.Session, error)
	sendTurn     func(context.Context, provider.SendTurnInput) error
	stopSession  func(context.Context, provider.StopSessionInput) error
	deleteSess   func(context.Context, string) error
}

func (i *fakeProviderInstance) Info() provider.InstanceInfo { return i.info }
func (i *fakeProviderInstance) Close() error {
	i.mu.Lock()
	defer i.mu.Unlock()
	i.closed = true
	return nil
}
func (i *fakeProviderInstance) StartSession(_ context.Context, input provider.StartSessionInput) (provider.Session, error) {
	i.mu.Lock()
	i.startInputs = append(i.startInputs, input)
	i.calls = append(i.calls, "StartSession")
	start := i.startSession
	i.mu.Unlock()
	if start != nil {
		return start(input)
	}
	return provider.Session{ProviderInstanceID: input.ProviderInstanceID, ThreadID: input.ThreadID}, nil
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
func (i *fakeProviderInstance) SetInteractionMode(context.Context, provider.SetInteractionModeInput) error {
	i.recordCall("SetInteractionMode")
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

type resumeCursorAdapter struct {
	mu        sync.Mutex
	instances []*fakeProviderInstance
}

type cursorRebindAdapter struct {
	mu        sync.Mutex
	instances map[provider.InstanceID]*fakeProviderInstance
}

type eventingAdapter struct {
	mu        sync.Mutex
	instances map[provider.InstanceID]*fakeProviderInstance
	listeners map[provider.InstanceID]provider.RuntimeEventListener
}

func (a *resumeCursorAdapter) StartInstance(_ context.Context, req provider.InstanceSpec, _ provider.RuntimeEventListener) (ProviderInstance, error) {
	a.mu.Lock()
	seq := len(a.instances) + 1
	instance := &fakeProviderInstance{info: provider.InstanceInfo{InstanceID: req.InstanceID, Name: req.Name, Driver: req.Driver, Status: provider.InstanceStatusInitialized, PID: seq}}
	instance.startSession = func(input provider.StartSessionInput) (provider.Session, error) {
		cursor := input.ResumeCursor
		if len(cursor) == 0 {
			cursor = json.RawMessage(`{"sessionId":"sess-1"}`)
		}
		return provider.Session{ProviderInstanceID: req.InstanceID, ProviderSessionID: "sess-1", ThreadID: input.ThreadID, ResumeCursor: append(json.RawMessage(nil), cursor...)}, nil
	}
	a.instances = append(a.instances, instance)
	a.mu.Unlock()
	return instance, nil
}

func (a *resumeCursorAdapter) instance(index int) *fakeProviderInstance {
	a.mu.Lock()
	defer a.mu.Unlock()
	if index < 0 || index >= len(a.instances) {
		return nil
	}
	return a.instances[index]
}

func (a *cursorRebindAdapter) StartInstance(_ context.Context, req provider.InstanceSpec, _ provider.RuntimeEventListener) (ProviderInstance, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.instances == nil {
		a.instances = make(map[provider.InstanceID]*fakeProviderInstance)
	}
	instance := &fakeProviderInstance{info: provider.InstanceInfo{InstanceID: req.InstanceID, Name: req.Name, Driver: req.Driver, Status: provider.InstanceStatusInitialized}}
	switch req.InstanceID {
	case "old":
		instance.startSession = func(input provider.StartSessionInput) (provider.Session, error) {
			return provider.Session{ProviderInstanceID: req.InstanceID, ThreadID: input.ThreadID, ResumeCursor: json.RawMessage(`{"sessionId":"old-session"}`)}, nil
		}
	default:
		instance.startSession = func(input provider.StartSessionInput) (provider.Session, error) {
			return provider.Session{ProviderInstanceID: req.InstanceID, ThreadID: input.ThreadID}, nil
		}
	}
	a.instances[req.InstanceID] = instance
	return instance, nil
}

func (a *cursorRebindAdapter) instance(id provider.InstanceID) *fakeProviderInstance {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.instances[id]
}

func (a *eventingAdapter) StartInstance(_ context.Context, req provider.InstanceSpec, emit provider.RuntimeEventListener) (ProviderInstance, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.instances == nil {
		a.instances = make(map[provider.InstanceID]*fakeProviderInstance)
	}
	if a.listeners == nil {
		a.listeners = make(map[provider.InstanceID]provider.RuntimeEventListener)
	}
	instance := &fakeProviderInstance{info: provider.InstanceInfo{InstanceID: req.InstanceID, Name: req.Name, Driver: req.Driver, Status: provider.InstanceStatusInitialized}}
	a.instances[req.InstanceID] = instance
	a.listeners[req.InstanceID] = emit
	return instance, nil
}

func (a *eventingAdapter) instance(id provider.InstanceID) *fakeProviderInstance {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.instances[id]
}

func (a *eventingAdapter) emit(id provider.InstanceID, event provider.RuntimeEvent) {
	a.mu.Lock()
	listener := a.listeners[id]
	a.mu.Unlock()
	if listener != nil {
		listener(event)
	}
}

type restartingEventingAdapter struct {
	mu        sync.Mutex
	instances []*fakeProviderInstance
	listeners []provider.RuntimeEventListener
}

type failingRestartEventingAdapter struct {
	mu        sync.Mutex
	starts    int
	instances []*fakeProviderInstance
	listeners []provider.RuntimeEventListener
	entered   chan struct{}
	release   chan struct{}
}

type blockingRestartAdapter struct {
	mu        sync.Mutex
	starts    int
	instances []*fakeProviderInstance
	entered   chan struct{}
	release   chan struct{}
}

func (a *restartingEventingAdapter) StartInstance(_ context.Context, req provider.InstanceSpec, emit provider.RuntimeEventListener) (ProviderInstance, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	seq := len(a.instances) + 1
	instance := &fakeProviderInstance{info: provider.InstanceInfo{InstanceID: req.InstanceID, Name: req.Name, Driver: req.Driver, Status: provider.InstanceStatusInitialized, PID: seq}}
	a.instances = append(a.instances, instance)
	a.listeners = append(a.listeners, emit)
	return instance, nil
}

func (a *restartingEventingAdapter) emit(startIndex int, event provider.RuntimeEvent) {
	a.mu.Lock()
	if startIndex < 0 || startIndex >= len(a.listeners) {
		a.mu.Unlock()
		return
	}
	listener := a.listeners[startIndex]
	a.mu.Unlock()
	if listener != nil {
		listener(event)
	}
}

func (a *failingRestartEventingAdapter) StartInstance(ctx context.Context, req provider.InstanceSpec, emit provider.RuntimeEventListener) (ProviderInstance, error) {
	a.mu.Lock()
	if a.entered == nil {
		a.entered = make(chan struct{})
	}
	if a.release == nil {
		a.release = make(chan struct{})
	}
	a.starts++
	seq := a.starts
	if seq == 1 {
		instance := &fakeProviderInstance{info: provider.InstanceInfo{InstanceID: req.InstanceID, Name: req.Name, Driver: req.Driver, Status: provider.InstanceStatusInitialized, PID: seq}}
		a.instances = append(a.instances, instance)
		a.listeners = append(a.listeners, emit)
		a.mu.Unlock()
		return instance, nil
	}
	entered := a.entered
	release := a.release
	a.mu.Unlock()
	close(entered)
	select {
	case <-release:
		return nil, errors.New("restart failed")
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (a *failingRestartEventingAdapter) emit(startIndex int, event provider.RuntimeEvent) {
	a.mu.Lock()
	if startIndex < 0 || startIndex >= len(a.listeners) {
		a.mu.Unlock()
		return
	}
	listener := a.listeners[startIndex]
	a.mu.Unlock()
	if listener != nil {
		listener(event)
	}
}

func (a *blockingRestartAdapter) StartInstance(ctx context.Context, req provider.InstanceSpec, _ provider.RuntimeEventListener) (ProviderInstance, error) {
	a.mu.Lock()
	if a.entered == nil {
		a.entered = make(chan struct{})
	}
	if a.release == nil {
		a.release = make(chan struct{})
	}
	a.starts++
	seq := a.starts
	if seq > 1 {
		entered := a.entered
		release := a.release
		a.mu.Unlock()
		close(entered)
		select {
		case <-release:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		a.mu.Lock()
	}
	instance := &fakeProviderInstance{info: provider.InstanceInfo{InstanceID: req.InstanceID, Name: req.Name, Driver: req.Driver, Status: provider.InstanceStatusInitialized, PID: seq}}
	a.instances = append(a.instances, instance)
	a.mu.Unlock()
	return instance, nil
}

func (a *blockingRestartAdapter) instance(index int) *fakeProviderInstance {
	a.mu.Lock()
	defer a.mu.Unlock()
	if index < 0 || index >= len(a.instances) {
		return nil
	}
	return a.instances[index]
}

func TestStartConnectionSerializesConcurrentStartsForSameInstance(t *testing.T) {
	adapter := &fakeStartAdapter{startDelay: 50 * time.Millisecond}
	s := New(adapter.StartInstance)
	defer s.Close()

	req := provider.InstanceSpec{InstanceID: "codex", Name: "codex", Driver: "fake", Config: fakeInstanceConfig([]string{"agent"})}
	var wg sync.WaitGroup
	results := make(chan provider.InstanceInfo, 2)
	errs := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			conn, err := s.StartInstance(context.Background(), req, false)
			if err != nil {
				errs <- err
				return
			}
			results <- conn
		}()
	}
	wg.Wait()
	close(results)
	close(errs)
	for err := range errs {
		t.Fatalf("StartInstance error: %v", err)
	}
	if starts := adapter.startCount(); starts != 1 {
		t.Fatalf("adapter starts = %d, want 1", starts)
	}
	for conn := range results {
		if conn.PID != 1 {
			t.Fatalf("connection PID = %d, want reused first instance", conn.PID)
		}
	}
}

func TestStartInstanceReusesSemanticallyEqualConfiguration(t *testing.T) {
	adapter := &fakeStartAdapter{}
	s := New(adapter.StartInstance)
	defer s.Close()

	first := provider.InstanceSpec{InstanceID: "codex", Name: "codex", Driver: "fake", Config: json.RawMessage(`{"command":["agent"],"env":{"A":"B"}}`)}
	second := provider.InstanceSpec{InstanceID: "codex", Name: "codex", Driver: "fake", Config: json.RawMessage(`{"env":{"A":"B"},"command":["agent"]}`)}
	firstInfo, err := s.StartInstance(context.Background(), first, false)
	if err != nil {
		t.Fatalf("first StartInstance: %v", err)
	}
	secondInfo, err := s.StartInstance(context.Background(), second, false)
	if err != nil {
		t.Fatalf("second StartInstance: %v", err)
	}
	if adapter.startCount() != 1 || secondInfo.PID != firstInfo.PID {
		t.Fatalf("starts/PIDs = %d/%d/%d, want one reused instance", adapter.startCount(), firstInfo.PID, secondInfo.PID)
	}
}

func TestStartInstanceConfigurationChangeRequiresRestart(t *testing.T) {
	adapter := &fakeStartAdapter{}
	s := New(adapter.StartInstance)
	defer s.Close()

	first := provider.InstanceSpec{InstanceID: "codex", Name: "codex", Driver: "fake", Config: fakeInstanceConfig([]string{"agent-a"})}
	changed := provider.InstanceSpec{InstanceID: "codex", Name: "codex", Driver: "fake", Config: fakeInstanceConfig([]string{"agent-b"})}
	if _, err := s.StartInstance(context.Background(), first, false); err != nil {
		t.Fatalf("first StartInstance: %v", err)
	}
	if _, err := s.StartInstance(context.Background(), changed, false); err == nil || !strings.Contains(err.Error(), "different configuration") {
		t.Fatalf("changed StartInstance err = %v, want restart-required error", err)
	}
	if adapter.startCount() != 1 {
		t.Fatalf("adapter starts after rejected change = %d, want 1", adapter.startCount())
	}
	if _, err := s.StartInstance(context.Background(), changed, true); err != nil {
		t.Fatalf("restart with changed config: %v", err)
	}
	if adapter.startCount() != 2 {
		t.Fatalf("adapter starts after restart = %d, want 2", adapter.startCount())
	}
}

func TestRuntimeEventsDoNotRebindThreadRoute(t *testing.T) {
	adapter := &eventingAdapter{}
	s := New(adapter.StartInstance)
	defer s.Close()

	oldReq := provider.InstanceSpec{InstanceID: "old", Name: "old", Driver: "fake", Config: fakeInstanceConfig([]string{"old-agent"})}
	newReq := provider.InstanceSpec{InstanceID: "new", Name: "new", Driver: "fake", Config: fakeInstanceConfig([]string{"new-agent"})}
	if _, err := s.StartInstance(context.Background(), oldReq, false); err != nil {
		t.Fatalf("old StartInstance: %v", err)
	}
	if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ThreadID: "thread-1", ProviderInstanceID: "old"}); err != nil {
		t.Fatalf("old StartSession: %v", err)
	}
	if _, err := s.StartInstance(context.Background(), newReq, false); err != nil {
		t.Fatalf("new StartInstance: %v", err)
	}
	if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ThreadID: "thread-1", ProviderInstanceID: "new"}); err != nil {
		t.Fatalf("new StartSession: %v", err)
	}

	adapter.emit("old", provider.RuntimeEvent{EventID: "late-old", Type: provider.RuntimeEventThreadMetadataUpdate, ThreadID: "thread-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{Title: "late old event"}})
	if err := s.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", Input: "hello"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}

	oldInstance := adapter.instance("old")
	newInstance := adapter.instance("new")
	if oldInstance == nil || newInstance == nil {
		t.Fatalf("instances missing: old=%#v new=%#v", oldInstance, newInstance)
	}
	if oldInstance.sendTurnCount() != 0 || newInstance.sendTurnCount() != 1 {
		t.Fatalf("send turns routed old=%d new=%d, want old=0 new=1 after stale old event", oldInstance.sendTurnCount(), newInstance.sendTurnCount())
	}
}

func TestRuntimeEventSourceIdentityComesFromEmittingInstance(t *testing.T) {
	adapter := &eventingAdapter{}
	s := New(adapter.StartInstance)
	defer s.Close()
	events := s.Events()

	req := provider.InstanceSpec{InstanceID: "old", Name: "Old Provider", Driver: "fake", Config: fakeInstanceConfig([]string{"old-agent"})}
	if _, err := s.StartInstance(context.Background(), req, false); err != nil {
		t.Fatalf("StartInstance: %v", err)
	}
	adapter.emit("old", provider.RuntimeEvent{EventID: "spoofed", Type: provider.RuntimeEventThreadMetadataUpdate, Provider: "spoofed-driver", ProviderInstanceID: "spoofed-instance", ProviderName: "Spoofed", ThreadID: "thread-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{Title: "hello"}})

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
	adapter := &eventingAdapter{}
	s := New(adapter.StartInstance)
	defer s.Close()

	if _, err := s.StartInstance(context.Background(), provider.InstanceSpec{InstanceID: "old", Name: "Old Provider", Driver: "fake", Config: fakeInstanceConfig([]string{"old-agent"})}, false); err != nil {
		t.Fatalf("old StartInstance: %v", err)
	}
	if _, err := s.StartInstance(context.Background(), provider.InstanceSpec{InstanceID: "new", Name: "New Provider", Driver: "fake", Config: fakeInstanceConfig([]string{"new-agent"})}, false); err != nil {
		t.Fatalf("new StartInstance: %v", err)
	}
	newInstance := adapter.instance("new")
	if newInstance == nil {
		t.Fatal("new provider instance missing")
	}
	newInstance.mu.Lock()
	newInstance.startSession = func(input provider.StartSessionInput) (provider.Session, error) {
		return provider.Session{Provider: "spoofed", ProviderInstanceID: "old", ProviderName: "Old Provider", ThreadID: input.ThreadID, ResumeCursor: json.RawMessage(`{"sessionId":"new-session"}`)}, nil
	}
	newInstance.mu.Unlock()

	session, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ThreadID: "thread-1", ProviderInstanceID: "new"})
	if err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if session.ProviderInstanceID != "new" || session.ProviderName != "New Provider" || session.Provider != "fake" {
		t.Fatalf("session identity = (%q,%q,%q), want selected new provider identity", session.ProviderInstanceID, session.ProviderName, session.Provider)
	}
	if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ThreadID: "thread-1", ProviderInstanceID: "new"}); err != nil {
		t.Fatalf("second StartSession: %v", err)
	}
	if got := string(newInstance.lastStartInput().ResumeCursor); got != `{"sessionId":"new-session"}` {
		t.Fatalf("resume cursor for selected instance = %s, want new-session cursor", got)
	}
	if err := s.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", Input: "hello"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	oldInstance := adapter.instance("old")
	if oldInstance == nil {
		t.Fatal("old provider instance missing")
	}
	if oldInstance.sendTurnCount() != 0 || newInstance.sendTurnCount() != 1 {
		t.Fatalf("send turns routed old=%d new=%d, want old=0 new=1", oldInstance.sendTurnCount(), newInstance.sendTurnCount())
	}
}

func TestStartInstanceCreatedDuringCloseIsClosedAndRejected(t *testing.T) {
	entered := make(chan struct{})
	release := make(chan struct{})
	created := make(chan *fakeProviderInstance, 1)
	s := New(func(ctx context.Context, spec provider.InstanceSpec, _ provider.RuntimeEventListener) (ProviderInstance, error) {
		close(entered)
		select {
		case <-release:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		instance := &fakeProviderInstance{info: provider.InstanceInfo{InstanceID: spec.InstanceID, Name: spec.Name, Driver: spec.Driver, Status: provider.InstanceStatusInitialized}}
		created <- instance
		return instance, nil
	})

	done := make(chan error, 1)
	go func() {
		_, err := s.StartInstance(context.Background(), provider.InstanceSpec{InstanceID: "codex", Name: "Codex", Driver: "fake"}, false)
		done <- err
	}()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("provider factory was not entered")
	}

	s.Close()
	close(release)
	instance := <-created
	if err := <-done; err == nil {
		t.Fatal("StartInstance completed after Close without an error")
	}
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

func restartedEventService(t *testing.T, rebind bool) (*Service, *restartingEventingAdapter) {
	t.Helper()
	adapter := &restartingEventingAdapter{}
	s := New(adapter.StartInstance)
	t.Cleanup(s.Close)
	req := provider.InstanceSpec{InstanceID: "codex", Name: "Codex", Driver: "fake", Config: fakeInstanceConfig([]string{"agent"})}
	if _, err := s.StartInstance(context.Background(), req, false); err != nil {
		t.Fatalf("initial StartInstance: %v", err)
	}
	if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ThreadID: "thread-1", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("initial StartSession: %v", err)
	}
	if _, err := s.StartInstance(context.Background(), req, true); err != nil {
		t.Fatalf("restart StartInstance: %v", err)
	}
	if rebind {
		if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ThreadID: "thread-1", ProviderInstanceID: "codex"}); err != nil {
			t.Fatalf("replacement StartSession: %v", err)
		}
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

func TestFailedRestartKeepsPreviousProviderProcessEventsActive(t *testing.T) {
	adapter := &failingRestartEventingAdapter{entered: make(chan struct{}), release: make(chan struct{})}
	s := New(adapter.StartInstance)
	defer s.Close()
	events := s.Events()

	req := provider.InstanceSpec{InstanceID: "codex", Name: "Codex", Driver: "fake", Config: fakeInstanceConfig([]string{"agent"})}
	if _, err := s.StartInstance(context.Background(), req, false); err != nil {
		t.Fatalf("initial StartInstance: %v", err)
	}
	errs := make(chan error, 1)
	go func() {
		_, err := s.StartInstance(context.Background(), req, true)
		errs <- err
	}()
	select {
	case <-adapter.entered:
	case <-time.After(2 * time.Second):
		t.Fatal("restart did not enter adapter start")
	}

	adapter.emit(0, provider.RuntimeEvent{EventID: "old-process-during-failed-restart", Type: provider.RuntimeEventThreadMetadataUpdate, ThreadID: "thread-1", CreatedAt: time.Now(), Payload: provider.RuntimeEventPayload{Title: "still live"}})
	select {
	case event := <-events:
		if event.EventID != "old-process-during-failed-restart" {
			t.Fatalf("event = %q, want old-process-during-failed-restart", event.EventID)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for old provider process event during failed restart")
	}

	close(adapter.release)
	if err := <-errs; err == nil {
		t.Fatal("restart error = nil, want failure")
	}
}

func TestStartSessionWaitsForInFlightRestartBeforeBindingAndSending(t *testing.T) {
	adapter := &blockingRestartAdapter{entered: make(chan struct{}), release: make(chan struct{})}
	s := New(adapter.StartInstance)
	defer s.Close()

	req := provider.InstanceSpec{InstanceID: "codex", Name: "Codex", Driver: "fake", Config: fakeInstanceConfig([]string{"agent"})}
	if _, err := s.StartInstance(context.Background(), req, false); err != nil {
		t.Fatalf("initial StartInstance: %v", err)
	}
	restartDone := make(chan error, 1)
	go func() {
		_, err := s.StartInstance(context.Background(), req, true)
		restartDone <- err
	}()
	select {
	case <-adapter.entered:
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

	close(adapter.release)
	if err := <-restartDone; err != nil {
		t.Fatalf("restart StartInstance: %v", err)
	}
	if err := <-sessionDone; err != nil {
		t.Fatalf("StartSession after restart: %v", err)
	}
	if err := s.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", Input: "hello"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}

	first := adapter.instance(0)
	second := adapter.instance(1)
	if first == nil || second == nil {
		t.Fatalf("instances missing: first=%#v second=%#v", first, second)
	}
	first.mu.Lock()
	firstStarts := len(first.startInputs)
	first.mu.Unlock()
	second.mu.Lock()
	secondStarts := len(second.startInputs)
	second.mu.Unlock()
	if firstStarts != 0 || first.sendTurnCount() != 0 {
		t.Fatalf("old instance used: starts=%d sends=%d, want 0/0", firstStarts, first.sendTurnCount())
	}
	if secondStarts != 1 || second.sendTurnCount() != 1 {
		t.Fatalf("new instance starts=%d sends=%d, want 1/1", secondStarts, second.sendTurnCount())
	}
}

func TestSendTurnDoesNotSerializeConcurrentTurnsForSameInstance(t *testing.T) {
	adapter := &eventingAdapter{}
	s := New(adapter.StartInstance)
	defer s.Close()

	if _, err := s.StartInstance(context.Background(), provider.InstanceSpec{InstanceID: "codex", Name: "Codex", Driver: "fake", Config: fakeInstanceConfig([]string{"agent"})}, false); err != nil {
		t.Fatalf("StartInstance: %v", err)
	}
	if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ThreadID: "thread-1", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("StartSession thread-1: %v", err)
	}
	if _, err := s.StartSession(context.Background(), "thread-2", provider.StartSessionInput{ThreadID: "thread-2", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("StartSession thread-2: %v", err)
	}

	instance := adapter.instance("codex")
	if instance == nil {
		t.Fatal("provider instance missing")
	}
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
			adapter := &resumeCursorAdapter{}
			s := New(adapter.StartInstance)
			defer s.Close()

			req := provider.InstanceSpec{InstanceID: "codex", Name: "codex", Driver: "fake", Config: fakeInstanceConfig([]string{"agent"})}
			if _, err := s.StartInstance(context.Background(), req, false); err != nil {
				t.Fatalf("initial StartInstance: %v", err)
			}
			if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ThreadID: "thread-1", ProviderInstanceID: "codex"}); err != nil {
				t.Fatalf("StartSession: %v", err)
			}
			if _, err := s.StartInstance(context.Background(), req, true); err != nil {
				t.Fatalf("restart StartInstance: %v", err)
			}

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
	adapter := &eventingAdapter{}
	s := New(adapter.StartInstance)
	defer s.Close()

	req := provider.InstanceSpec{InstanceID: "codex", Name: "Codex", Driver: "fake", Config: fakeInstanceConfig([]string{"agent"})}
	if _, err := s.StartInstance(context.Background(), req, false); err != nil {
		t.Fatalf("StartInstance: %v", err)
	}
	instance := adapter.instance("codex")
	if instance == nil {
		t.Fatal("provider instance missing")
	}
	entered := make(chan struct{})
	release := make(chan struct{})
	instance.mu.Lock()
	instance.deleteSess = func(ctx context.Context, _ string) error {
		close(entered)
		select {
		case <-release:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	instance.mu.Unlock()

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
	adapter := &eventingAdapter{}
	s := New(adapter.StartInstance)
	defer s.Close()

	req := provider.InstanceSpec{InstanceID: "codex", Name: "Codex", Driver: "fake", Config: fakeInstanceConfig([]string{"agent"})}
	if _, err := s.StartInstance(context.Background(), req, false); err != nil {
		t.Fatalf("StartInstance: %v", err)
	}
	instance := adapter.instance("codex")
	deadlines := make(chan bool, 1)
	instance.mu.Lock()
	instance.deleteSess = func(ctx context.Context, _ string) error {
		_, hasDeadline := ctx.Deadline()
		deadlines <- hasDeadline
		return nil
	}
	instance.mu.Unlock()

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
	adapter := &resumeCursorAdapter{}
	s := New(adapter.StartInstance)
	defer s.Close()

	req := provider.InstanceSpec{InstanceID: "codex", Name: "codex", Driver: "fake", Config: fakeInstanceConfig([]string{"agent"})}
	if _, err := s.StartInstance(context.Background(), req, false); err != nil {
		t.Fatalf("initial StartInstance: %v", err)
	}
	firstSession, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ThreadID: "thread-1", ProviderInstanceID: "codex"})
	if err != nil {
		t.Fatalf("initial StartSession: %v", err)
	}
	if _, err := s.StartInstance(context.Background(), req, true); err != nil {
		t.Fatalf("restart StartInstance: %v", err)
	}
	secondSession, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ThreadID: "thread-1", ProviderInstanceID: "codex"})
	if err != nil {
		t.Fatalf("restart StartSession: %v", err)
	}
	if firstSession.Generation == 0 || secondSession.Generation == 0 || firstSession.Generation == secondSession.Generation {
		t.Fatalf("session generations before/after restart = %d/%d, want distinct non-zero generations", firstSession.Generation, secondSession.Generation)
	}

	second := adapter.instance(1)
	if second == nil {
		t.Fatal("second provider instance missing")
	}
	if got := string(second.lastStartInput().ResumeCursor); got != `{"sessionId":"sess-1"}` {
		t.Fatalf("resume cursor passed after restart = %s, want sess-1 cursor", got)
	}
}

func TestSwitchingProviderSucceedsWhenPreviousInstanceStopFails(t *testing.T) {
	adapter := &cursorRebindAdapter{}
	s := New(adapter.StartInstance)
	defer s.Close()

	for _, id := range []provider.InstanceID{"old", "new"} {
		req := provider.InstanceSpec{InstanceID: id, Name: string(id), Driver: "fake", Config: fakeInstanceConfig([]string{string(id) + "-agent"})}
		if _, err := s.StartInstance(context.Background(), req, false); err != nil {
			t.Fatalf("StartInstance(%s): %v", id, err)
		}
	}
	if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ThreadID: "thread-1", ProviderInstanceID: "old"}); err != nil {
		t.Fatalf("old StartSession: %v", err)
	}
	oldInstance := adapter.instance("old")
	oldInstance.mu.Lock()
	oldInstance.stopSession = func(context.Context, provider.StopSessionInput) error {
		return errors.New("agent process is gone")
	}
	oldInstance.mu.Unlock()

	if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ThreadID: "thread-1", ProviderInstanceID: "new"}); err != nil {
		t.Fatalf("StartSession on new instance after failed release: %v", err)
	}
	if got := oldInstance.operationCount("StopSession"); got != 1 {
		t.Fatalf("old provider StopSession calls = %d, want 1", got)
	}
	if err := s.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", Input: "hello"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	newInstance := adapter.instance("new")
	if oldInstance.sendTurnCount() != 0 || newInstance.sendTurnCount() != 1 {
		t.Fatalf("send turns routed old=%d new=%d, want old=0 new=1 after rebind", oldInstance.sendTurnCount(), newInstance.sendTurnCount())
	}
}

func TestReleaseSessionDropsRouteWhenProviderStopFails(t *testing.T) {
	adapter := &cursorRebindAdapter{}
	s := New(adapter.StartInstance)
	defer s.Close()

	req := provider.InstanceSpec{InstanceID: "old", Name: "old", Driver: "fake", Config: fakeInstanceConfig([]string{"old-agent"})}
	if _, err := s.StartInstance(context.Background(), req, false); err != nil {
		t.Fatalf("StartInstance: %v", err)
	}
	if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ThreadID: "thread-1", ProviderInstanceID: "old"}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	oldInstance := adapter.instance("old")
	oldInstance.mu.Lock()
	oldInstance.stopSession = func(context.Context, provider.StopSessionInput) error {
		return errors.New("agent process is gone")
	}
	oldInstance.mu.Unlock()

	if err := s.ReleaseSession(context.Background(), provider.StopSessionInput{ThreadID: "thread-1"}); err != nil {
		t.Fatalf("ReleaseSession: %v", err)
	}
	if got := oldInstance.operationCount("StopSession"); got != 1 {
		t.Fatalf("old provider StopSession calls = %d, want 1", got)
	}
	if err := s.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", Input: "must not route"}); err == nil || !strings.Contains(err.Error(), "no provider session route") {
		t.Fatalf("SendTurn after release err = %v, want no provider session route", err)
	}
}

func TestSwitchingProviderSkipsStopWhenRouteGenerationIsStale(t *testing.T) {
	adapter := &cursorRebindAdapter{}
	s := New(adapter.StartInstance)
	defer s.Close()

	for _, id := range []provider.InstanceID{"old", "new"} {
		req := provider.InstanceSpec{InstanceID: id, Name: string(id), Driver: "fake", Config: fakeInstanceConfig([]string{string(id) + "-agent"})}
		if _, err := s.StartInstance(context.Background(), req, false); err != nil {
			t.Fatalf("StartInstance(%s): %v", id, err)
		}
	}
	if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ThreadID: "thread-1", ProviderInstanceID: "old"}); err != nil {
		t.Fatalf("old StartSession: %v", err)
	}
	// Restart "old" so the thread's route points at a replaced generation: the
	// session died with the old process, so the switch must not RPC a stop.
	oldReq := provider.InstanceSpec{InstanceID: "old", Name: "old", Driver: "fake", Config: fakeInstanceConfig([]string{"old-agent"})}
	if _, err := s.StartInstance(context.Background(), oldReq, true); err != nil {
		t.Fatalf("restart old StartInstance: %v", err)
	}
	replacement := adapter.instance("old")
	replacement.mu.Lock()
	replacement.stopSession = func(context.Context, provider.StopSessionInput) error {
		return errors.New("should not be called for a stale-generation route")
	}
	replacement.mu.Unlock()

	if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ThreadID: "thread-1", ProviderInstanceID: "new"}); err != nil {
		t.Fatalf("StartSession on new instance: %v", err)
	}
	if got := replacement.operationCount("StopSession"); got != 0 {
		t.Fatalf("replacement StopSession calls = %d, want 0 for stale-generation route", got)
	}
	if err := s.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", Input: "hello"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}
	if got := adapter.instance("new").sendTurnCount(); got != 1 {
		t.Fatalf("new instance send turns = %d, want 1 after rebind", got)
	}
}

func TestStartSessionClearsStoredResumeCursorWhenReboundSessionReturnsNone(t *testing.T) {
	adapter := &cursorRebindAdapter{}
	s := New(adapter.StartInstance)
	defer s.Close()

	oldReq := provider.InstanceSpec{InstanceID: "old", Name: "old", Driver: "fake", Config: fakeInstanceConfig([]string{"old-agent"})}
	newReq := provider.InstanceSpec{InstanceID: "new", Name: "new", Driver: "fake", Config: fakeInstanceConfig([]string{"new-agent"})}
	if _, err := s.StartInstance(context.Background(), oldReq, false); err != nil {
		t.Fatalf("old StartInstance: %v", err)
	}
	if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ThreadID: "thread-1", ProviderInstanceID: "old"}); err != nil {
		t.Fatalf("old StartSession: %v", err)
	}
	if _, err := s.StartInstance(context.Background(), newReq, false); err != nil {
		t.Fatalf("new StartInstance: %v", err)
	}
	if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ThreadID: "thread-1", ProviderInstanceID: "new"}); err != nil {
		t.Fatalf("first new StartSession: %v", err)
	}
	if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ThreadID: "thread-1", ProviderInstanceID: "new"}); err != nil {
		t.Fatalf("second new StartSession: %v", err)
	}

	newInstance := adapter.instance("new")
	if newInstance == nil {
		t.Fatal("new provider instance missing")
	}
	if got := string(newInstance.lastStartInput().ResumeCursor); got != "" {
		t.Fatalf("resume cursor passed after no-cursor rebind = %s, want empty", got)
	}
}

func TestStopSessionDropsStoredResumeCursorSoNextTurnStartsFresh(t *testing.T) {
	adapter := &resumeCursorAdapter{}
	s := New(adapter.StartInstance)
	defer s.Close()

	req := provider.InstanceSpec{InstanceID: "codex", Name: "codex", Driver: "fake", Config: fakeInstanceConfig([]string{"agent"})}
	if _, err := s.StartInstance(context.Background(), req, false); err != nil {
		t.Fatalf("StartInstance: %v", err)
	}
	if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ThreadID: "thread-1", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("initial StartSession: %v", err)
	}
	if err := s.StopSession(context.Background(), provider.StopSessionInput{ThreadID: "thread-1"}); err != nil {
		t.Fatalf("StopSession: %v", err)
	}
	if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ThreadID: "thread-1", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("StartSession after stop: %v", err)
	}

	instance := adapter.instance(0)
	if instance == nil {
		t.Fatal("provider instance missing")
	}
	if got := string(instance.lastStartInput().ResumeCursor); got != "" {
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
			name: "set interaction mode",
			call: func(s *Service) error {
				return s.SetInteractionMode(context.Background(), provider.SetInteractionModeInput{ThreadID: "thread-1", Mode: "plan"})
			},
			want: "SetInteractionMode",
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
			adapter := &resumeCursorAdapter{}
			s := New(adapter.StartInstance)
			defer s.Close()

			req := provider.InstanceSpec{InstanceID: "codex", Name: "codex", Driver: "fake", Config: fakeInstanceConfig([]string{"agent"})}
			if _, err := s.StartInstance(context.Background(), req, false); err != nil {
				t.Fatalf("initial StartInstance: %v", err)
			}
			if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ThreadID: "thread-1", ProviderInstanceID: "codex"}); err != nil {
				t.Fatalf("initial StartSession: %v", err)
			}
			if _, err := s.StartInstance(context.Background(), req, true); err != nil {
				t.Fatalf("restart StartInstance: %v", err)
			}
			if err := tt.call(s); err != nil {
				t.Fatalf("%s: %v", tt.name, err)
			}

			first := adapter.instance(0)
			second := adapter.instance(1)
			if first == nil || second == nil {
				t.Fatalf("instances missing: first=%#v second=%#v", first, second)
			}
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
	adapter := &resumeCursorAdapter{}
	s := New(adapter.StartInstance)
	defer s.Close()

	req := provider.InstanceSpec{InstanceID: "codex", Name: "codex", Driver: "fake", Config: fakeInstanceConfig([]string{"agent"})}
	if _, err := s.StartInstance(context.Background(), req, false); err != nil {
		t.Fatalf("initial StartInstance: %v", err)
	}
	if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{
		ThreadID: "thread-1", ProviderInstanceID: "codex", InteractionMode: "default",
		ModelSelection: &provider.ModelSelection{Model: "slow"},
	}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if err := s.SetInteractionMode(context.Background(), provider.SetInteractionModeInput{ThreadID: "thread-1", Mode: "plan"}); err != nil {
		t.Fatalf("SetInteractionMode: %v", err)
	}
	if err := s.SetConfigOption(context.Background(), provider.SetConfigOptionInput{ThreadID: "thread-1", OptionID: "model", Value: "fast", Category: provider.ConfigOptionCategoryModel}); err != nil {
		t.Fatalf("SetConfigOption: %v", err)
	}
	if _, err := s.StartInstance(context.Background(), req, true); err != nil {
		t.Fatalf("restart StartInstance: %v", err)
	}
	if err := s.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", Input: "hello"}); err != nil {
		t.Fatalf("SendTurn: %v", err)
	}

	input := adapter.instance(1).lastStartInput()
	if input.InteractionMode != "plan" {
		t.Fatalf("recovered interaction mode = %q, want plan", input.InteractionMode)
	}
	if input.ModelSelection == nil || input.ModelSelection.Model != "fast" {
		t.Fatalf("recovered model selection = %#v, want fast", input.ModelSelection)
	}
}

func TestStopSessionDoesNotRecoverStaleRouteAfterRestart(t *testing.T) {
	adapter := &resumeCursorAdapter{}
	s := New(adapter.StartInstance)
	defer s.Close()

	req := provider.InstanceSpec{InstanceID: "codex", Name: "codex", Driver: "fake", Config: fakeInstanceConfig([]string{"agent"})}
	if _, err := s.StartInstance(context.Background(), req, false); err != nil {
		t.Fatalf("initial StartInstance: %v", err)
	}
	if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ThreadID: "thread-1", ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("initial StartSession: %v", err)
	}
	if _, err := s.StartInstance(context.Background(), req, true); err != nil {
		t.Fatalf("restart StartInstance: %v", err)
	}
	if err := s.StopSession(context.Background(), provider.StopSessionInput{ThreadID: "thread-1"}); err != nil {
		t.Fatalf("StopSession: %v", err)
	}

	second := adapter.instance(1)
	if second == nil {
		t.Fatal("second provider instance missing")
	}
	if got := second.startInputCount(); got != 0 {
		t.Fatalf("restart instance start sessions = %d, want 0 for stop", got)
	}
	if got := second.operationCount("StopSession"); got != 1 {
		t.Fatalf("restart instance StopSession calls = %d, want 1", got)
	}
}

func TestEventsChannelClosesOnServiceClose(t *testing.T) {
	s := New(nil)
	events := s.Events()

	s.Close()

	select {
	case _, ok := <-events:
		if ok {
			t.Fatal("events channel is open after service close")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for events channel to close")
	}
}
