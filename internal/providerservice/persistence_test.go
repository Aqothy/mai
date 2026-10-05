package providerservice

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
	"github.com/Aqothy/maiD/internal/store"
)

func openRouteStore(t *testing.T) *store.SQLite {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "maid.db"))
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return st
}

func TestRouteWriteThroughPersistence(t *testing.T) {
	st := openRouteStore(t)
	adapter := &fakeAdapter{configure: resumableSessions}
	s := New(adapter.StartInstance, WithRouteStore(st))
	defer s.Close()

	spec := fakeSpec("codex")
	mustStartInstance(t, s, spec, false)
	specs, err := st.LoadInstances()
	if err != nil {
		t.Fatalf("LoadInstances: %v", err)
	}
	if len(specs) != 1 || specs[0].InstanceID != "codex" || specs[0].Driver != "fake" || string(specs[0].Config) != string(spec.Config) {
		t.Fatalf("instance spec not persisted: %+v", specs)
	}

	input := provider.StartSessionInput{ProviderInstanceID: "codex", ModelSelection: &provider.ModelSelection{Model: "gpt"}, ReplayHistory: true}
	if _, err := s.StartSession(context.Background(), "thread-1", input); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if started := adapter.instance(0).lastStartInput(); !started.ReplayHistory {
		t.Fatalf("adapter start input = %#v, want one-shot replay intent", started)
	}
	routes, err := st.LoadRoutes()
	if err != nil {
		t.Fatalf("LoadRoutes: %v", err)
	}
	route, ok := routes["thread-1"]
	if !ok {
		t.Fatalf("route not persisted: %+v", routes)
	}
	if route.InstanceID != "codex" || route.ProviderSessionID != "sess-1" {
		t.Fatalf("unexpected route: %+v", route)
	}
	if string(route.ResumeCursor) != `{"sessionId":"sess-1"}` {
		t.Fatalf("resume cursor not persisted: %s", route.ResumeCursor)
	}
	if route.StartInput.ModelSelection == nil || route.StartInput.ModelSelection.Model != "gpt" {
		t.Fatalf("start input not persisted: %+v", route.StartInput)
	}
	if route.StartInput.ReplayHistory {
		t.Fatalf("one-shot replay intent persisted in route: %+v", route.StartInput)
	}

	if err := s.StopSession(context.Background(), provider.StopSessionInput{ThreadID: "thread-1"}); err != nil {
		t.Fatalf("StopSession: %v", err)
	}
	routes, err = st.LoadRoutes()
	if err != nil {
		t.Fatalf("LoadRoutes after stop: %v", err)
	}
	if len(routes) != 0 {
		t.Fatalf("stop must delete the durable route: %+v", routes)
	}
}

func TestManifestInstanceDoesNotPersistLaunchConfiguration(t *testing.T) {
	st := openRouteStore(t)
	adapter := &fakeAdapter{configure: resumableSessions}
	s := New(adapter.StartInstance, WithRouteStore(st))
	defer s.Close()

	spec := provider.InstanceSpec{
		InstanceID: "custom-Custom Agent",
		Name:       "Custom Agent",
		Driver:     "fake",
		Config:     json.RawMessage(`{"command":["agent"],"env":{"TOKEN":"secret"}}`),
	}
	if _, err := s.StartManifestInstance(context.Background(), spec, false); err != nil {
		t.Fatalf("StartManifestInstance: %v", err)
	}
	specs, err := st.LoadInstances()
	if err != nil {
		t.Fatalf("LoadInstances: %v", err)
	}
	if len(specs) != 1 || specs[0].InstanceID != spec.InstanceID || len(specs[0].Config) != 0 {
		t.Fatalf("stored manifest reference = %#v, want identity without config", specs)
	}
}

func TestRestoredRouteLazilyRespawnsInstanceAndResumesSession(t *testing.T) {
	st := openRouteStore(t)
	spec := fakeSpec("codex")

	first := &fakeAdapter{configure: resumableSessions}
	before := New(first.StartInstance, WithRouteStore(st))
	mustStartInstance(t, before, spec, false)
	if _, err := before.StartSession(context.Background(), "thread-1", provider.StartSessionInput{
		ProviderInstanceID: "codex",
		ModelSelection:     &provider.ModelSelection{Model: "gpt"},
		Options:            json.RawMessage(`{"mode":"careful"}`),
	}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if err := before.SetConfigOption(context.Background(), provider.SetConfigOptionInput{
		ThreadID: "thread-1",
		OptionID: "reasoning",
		Value:    "high",
	}); err != nil {
		t.Fatalf("SetConfigOption: %v", err)
	}
	before.Close()

	// The restarted daemon keeps instances cold: no StartInstance here. The
	// first session start on the routed thread respawns the persisted instance
	// and hands the adapter the stored resume cursor.
	second := &fakeAdapter{configure: resumableSessions}
	after := New(second.StartInstance, WithRouteStore(st))
	defer after.Close()
	result, err := after.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ProviderInstanceID: "codex"})
	if err != nil {
		t.Fatalf("StartSession after restart: %v", err)
	}
	instance := second.instance(0)
	if instance == nil {
		t.Fatal("persisted instance was not respawned on first use")
	}
	input := instance.lastStartInput()
	if cursor := string(input.ResumeCursor); cursor != `{"sessionId":"sess-1"}` {
		t.Fatalf("resume cursor after restart = %q, want the persisted cursor", cursor)
	}
	if input.ModelSelection == nil || input.ModelSelection.Model != "gpt" {
		t.Fatalf("model selection after restart = %#v, want gpt", input.ModelSelection)
	}
	if len(input.ConfigSelections) != 1 || input.ConfigSelections[0].OptionID != "reasoning" || input.ConfigSelections[0].Value != "high" {
		t.Fatalf("config selections after restart = %#v, want reasoning=high", input.ConfigSelections)
	}
	if string(input.Options) != `{"mode":"careful"}` {
		t.Fatalf("options after restart = %s, want persisted options", input.Options)
	}
	if result.Session.ProviderSessionID != "sess-1" {
		t.Fatalf("session after restart = %#v, want the resumed provider session", result.Session)
	}

	routes, err := st.LoadRoutes()
	if err != nil {
		t.Fatalf("LoadRoutes after restart: %v", err)
	}
	persisted := routes["thread-1"].StartInput
	if len(persisted.ConfigSelections) != 1 || persisted.ConfigSelections[0].OptionID != "reasoning" {
		t.Fatalf("restart clobbered persisted config selections: %#v", persisted.ConfigSelections)
	}

	// After the restored route has rebound to the live generation, a fresh
	// session input must not silently inherit the old preferences again.
	mustStartSession(t, after, "thread-1", provider.StartSessionInput{ProviderInstanceID: "codex"})
	input = instance.lastStartInput()
	if input.ModelSelection != nil || len(input.ConfigSelections) != 0 || len(input.Options) != 0 {
		t.Fatalf("live session inherited restored preferences: %#v", input)
	}
	if cursor := string(input.ResumeCursor); cursor != `{"sessionId":"sess-1"}` {
		t.Fatalf("live session resume cursor = %q, want the bound session cursor", cursor)
	}
}

func TestDuplicateProviderSessionBindingDoesNotPublishLiveRoute(t *testing.T) {
	st := openRouteStore(t)
	adapter := &fakeAdapter{configure: resumableSessions}
	service := New(adapter.StartInstance, WithRouteStore(st))
	defer service.Close()
	spec := fakeSpec("codex")
	mustStartInstance(t, service, spec, false)
	mustStartSession(t, service, "thread-1", provider.StartSessionInput{ProviderInstanceID: "codex"})
	if _, err := service.StartSession(context.Background(), "thread-2", provider.StartSessionInput{ProviderInstanceID: "codex"}); !errors.Is(err, store.ErrProviderSessionBound) {
		t.Fatalf("StartSession thread-2 err = %v, want ErrProviderSessionBound", err)
	}
	if route := service.routeForThread("thread-2"); route.InstanceID != "" {
		t.Fatalf("duplicate live route = %+v", route)
	}
	routes, err := st.LoadRoutes()
	if err != nil {
		t.Fatalf("LoadRoutes: %v", err)
	}
	if len(routes) != 1 || routes["thread-1"].ProviderSessionID != "sess-1" {
		t.Fatalf("durable routes = %+v", routes)
	}
}

func TestImportedRoutePassesProviderSessionIDAfterRestart(t *testing.T) {
	st := openRouteStore(t)
	spec := fakeSpec("codex")
	if err := st.SaveInstance(spec); err != nil {
		t.Fatalf("SaveInstance: %v", err)
	}
	now := time.Now()
	_, imported, err := st.ImportThread(
		store.ThreadMeta{ThreadID: "thread-imported", ProviderInstanceID: "codex", CreatedAt: now, UpdatedAt: now},
		store.RouteRecord{
			InstanceID:        "codex",
			ProviderSessionID: "external-session",
			StartInput:        provider.StartSessionInput{ThreadID: "thread-imported", ProviderInstanceID: "codex"},
		},
	)
	if err != nil || !imported {
		t.Fatalf("ImportThread = imported %v, err %v", imported, err)
	}

	adapter := &fakeAdapter{configure: resumableSessions}
	service := New(adapter.StartInstance, WithRouteStore(st))
	defer service.Close()
	mustStartSession(t, service, "thread-imported", provider.StartSessionInput{ProviderInstanceID: "codex", ReplayHistory: true})
	input := adapter.instance(0).lastStartInput()
	if input.ProviderSessionID != "external-session" {
		t.Fatalf("provider session id = %q, want external-session", input.ProviderSessionID)
	}
	if !input.ReplayHistory {
		t.Fatalf("imported start input = %#v, want replay intent", input)
	}
}

func TestRouteLoadFailureFreezesPersistenceForRun(t *testing.T) {
	flaky := newFlakyRouteStore(0)
	flaky.routeLoadFailures = 1
	flaky.routes["thread-1"] = store.RouteRecord{
		InstanceID:        "codex",
		ProviderSessionID: "session-old",
		ResumeCursor:      json.RawMessage(`{"sessionId":"session-old"}`),
	}

	adapter := &fakeAdapter{configure: resumableSessions}
	s := New(adapter.StartInstance, WithRouteStore(flaky))
	defer s.Close()

	spec := fakeSpec("codex")
	mustStartInstance(t, s, spec, false)
	mustStartSession(t, s, "thread-1", provider.StartSessionInput{ProviderInstanceID: "codex"})

	flaky.mu.Lock()
	defer flaky.mu.Unlock()
	if flaky.routeSaveCalls != 0 {
		t.Fatalf("SaveRoute calls after failed restore = %d, want 0", flaky.routeSaveCalls)
	}
	if route := flaky.routes["thread-1"]; route.ProviderSessionID != "session-old" {
		t.Fatalf("durable route after failed restore = %+v, want original route preserved", route)
	}
}

func TestRestoredRouteRecoversSessionBeforeFirstOperation(t *testing.T) {
	st := openRouteStore(t)
	spec := fakeSpec("codex")

	first := &fakeAdapter{configure: resumableSessions}
	before := New(first.StartInstance, WithRouteStore(st))
	mustStartInstance(t, before, spec, false)
	mustStartSession(t, before, "thread-1", provider.StartSessionInput{ProviderInstanceID: "codex"})
	before.Close()

	// A restored route's generation never matches a live instance, so an
	// operation that skips StartSession still recovers the session (with the
	// stored start input and cursor) before dispatching.
	second := &fakeAdapter{configure: resumableSessions}
	after := New(second.StartInstance, WithRouteStore(st))
	defer after.Close()
	mustStartInstance(t, after, spec, false)
	if err := after.SendTurn(context.Background(), provider.SendTurnInput{ThreadID: "thread-1", Input: "hello"}); err != nil {
		t.Fatalf("SendTurn after restart: %v", err)
	}
	instance := second.instance(0)
	if instance == nil {
		t.Fatal("restarted instance was not spawned")
	}
	if instance.startInputCount() != 1 {
		t.Fatalf("StartSession calls = %d, want the recovery start before the turn", instance.startInputCount())
	}
	if cursor := string(instance.lastStartInput().ResumeCursor); cursor != `{"sessionId":"sess-1"}` {
		t.Fatalf("recovery resume cursor = %q, want the persisted cursor", cursor)
	}
	if instance.sendTurnCount() != 1 {
		t.Fatalf("SendTurn calls = %d, want 1", instance.sendTurnCount())
	}
}

type flakyRouteStore struct {
	mu                   sync.Mutex
	instanceSaveFailures int
	routeSaveFailures    int
	routeLoadFailures    int
	routeSaveCalls       int
	instances            map[provider.InstanceID]provider.InstanceSpec
	routes               map[string]store.RouteRecord
}

func newFlakyRouteStore(instanceSaveFailures int) *flakyRouteStore {
	return &flakyRouteStore{
		instanceSaveFailures: instanceSaveFailures,
		instances:            make(map[provider.InstanceID]provider.InstanceSpec),
		routes:               make(map[string]store.RouteRecord),
	}
}

func (s *flakyRouteStore) SaveInstance(spec provider.InstanceSpec) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.instanceSaveFailures > 0 {
		s.instanceSaveFailures--
		return errors.New("transient store failure")
	}
	s.instances[spec.InstanceID] = spec
	return nil
}

func (s *flakyRouteStore) SaveRoute(threadID string, record store.RouteRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.routeSaveCalls++
	if s.routeSaveFailures > 0 {
		s.routeSaveFailures--
		return errors.New("transient store failure")
	}
	if _, ok := s.instances[record.InstanceID]; !ok {
		return fmt.Errorf("foreign key: instance %q not stored", record.InstanceID)
	}
	s.routes[threadID] = record
	return nil
}

func (s *flakyRouteStore) DeleteRoute(threadID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.routes, threadID)
	return nil
}

func (s *flakyRouteStore) LoadRoutes() (map[string]store.RouteRecord, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.routeLoadFailures > 0 {
		s.routeLoadFailures--
		return nil, errors.New("transient route load failure")
	}
	return s.routes, nil
}

func (s *flakyRouteStore) LoadInstances() ([]provider.InstanceSpec, error) { return nil, nil }

func TestRoutePersistenceHealsFailedInstanceSave(t *testing.T) {
	flaky := newFlakyRouteStore(1)
	adapter := &fakeAdapter{configure: resumableSessions}
	s := New(adapter.StartInstance, WithRouteStore(flaky))
	defer s.Close()

	spec := fakeSpec("codex")
	mustStartInstance(t, s, spec, false)
	mustStartSession(t, s, "thread-1", provider.StartSessionInput{ProviderInstanceID: "codex"})

	flaky.mu.Lock()
	defer flaky.mu.Unlock()
	if _, ok := flaky.instances["codex"]; !ok {
		t.Fatal("route write did not re-save the missing instance spec")
	}
	if route, ok := flaky.routes["thread-1"]; !ok || route.ProviderSessionID != "sess-1" {
		t.Fatalf("route not persisted after instance heal: %+v", flaky.routes)
	}
}

func TestFailedStandaloneInstanceWriteRetriesOnClose(t *testing.T) {
	flaky := newFlakyRouteStore(1)
	adapter := &fakeAdapter{configure: resumableSessions}
	s := New(adapter.StartInstance, WithRouteStore(flaky))

	spec := fakeSpec("codex")
	mustStartInstance(t, s, spec, false)

	s.Close()

	flaky.mu.Lock()
	defer flaky.mu.Unlock()
	if _, ok := flaky.instances["codex"]; !ok {
		t.Fatal("failed standalone instance write was not retried at close")
	}
}

func TestFailedRouteWriteRetriesOnClose(t *testing.T) {
	flaky := newFlakyRouteStore(0)
	flaky.routeSaveFailures = 1
	adapter := &fakeAdapter{configure: resumableSessions}
	s := New(adapter.StartInstance, WithRouteStore(flaky))

	spec := fakeSpec("codex")
	mustStartInstance(t, s, spec, false)
	mustStartSession(t, s, "thread-1", provider.StartSessionInput{ProviderInstanceID: "codex"})
	flaky.mu.Lock()
	if len(flaky.routes) != 0 {
		flaky.mu.Unlock()
		t.Fatalf("route write should have failed: %+v", flaky.routes)
	}
	flaky.mu.Unlock()

	s.Close()

	flaky.mu.Lock()
	defer flaky.mu.Unlock()
	if route, ok := flaky.routes["thread-1"]; !ok || route.ProviderSessionID != "sess-1" {
		t.Fatalf("failed route write was not retried at close: %+v", flaky.routes)
	}
}

func TestFailedRouteWriteRetriesOnOtherThreadsWrite(t *testing.T) {
	flaky := newFlakyRouteStore(0)
	flaky.routeSaveFailures = 1
	adapter := &fakeAdapter{configure: resumableSessions}
	s := New(adapter.StartInstance, WithRouteStore(flaky))
	defer s.Close()

	spec := fakeSpec("codex")
	mustStartInstance(t, s, spec, false)
	mustStartSession(t, s, "thread-1", provider.StartSessionInput{ProviderInstanceID: "codex"})
	instance := adapter.instance(0)
	instance.mu.Lock()
	instance.startSession = func(input provider.StartSessionInput) (provider.Session, error) {
		return provider.Session{ProviderInstanceID: "codex", ProviderSessionID: "sess-2", ThreadID: input.ThreadID}, nil
	}
	instance.mu.Unlock()
	mustStartSession(t, s, "thread-2", provider.StartSessionInput{ProviderInstanceID: "codex"})

	flaky.mu.Lock()
	defer flaky.mu.Unlock()
	first, firstOK := flaky.routes["thread-1"]
	second, secondOK := flaky.routes["thread-2"]
	if len(flaky.routes) != 2 || !firstOK || !secondOK || first.ProviderSessionID != "sess-1" || second.ProviderSessionID != "sess-2" {
		t.Fatalf("routes after retry = %+v, want thread-1/sess-1 and thread-2/sess-2", flaky.routes)
	}
}

// draftModelSelections is the start input orchestration builds for a client
// draft: the selected model appears both as ModelSelection and as a
// model-category config selection.
func draftModelSelections(model string, effort string) provider.StartSessionInput {
	return provider.StartSessionInput{
		ProviderInstanceID: "codex",
		ModelSelection:     &provider.ModelSelection{Model: model},
		ConfigSelections: []provider.ConfigOptionSelection{
			{OptionID: "model", Value: model, Category: provider.ConfigOptionCategoryModel},
			{OptionID: "reasoning_effort", Value: effort, Category: provider.ConfigOptionCategoryThoughtLevel},
		},
	}
}

func assertCanonicalModel(t *testing.T, label string, input provider.StartSessionInput, model string, effort string) {
	t.Helper()
	if input.ModelSelection == nil || input.ModelSelection.Model != model {
		t.Fatalf("%s model selection = %#v, want %s", label, input.ModelSelection, model)
	}
	for _, selection := range input.ConfigSelections {
		switch selection.OptionID {
		case "model":
			if selection.Value != model {
				t.Fatalf("%s model config selection = %#v, want %s", label, selection, model)
			}
		case "reasoning_effort":
			if selection.Value != effort {
				t.Fatalf("%s reasoning selection = %#v, want %s", label, selection, effort)
			}
		}
	}
}

func TestChangedModelSurvivesDaemonRestartWithDraftConfigSelections(t *testing.T) {
	st := openRouteStore(t)
	spec := fakeSpec("codex")

	first := &fakeAdapter{configure: resumableSessions}
	before := New(first.StartInstance, WithRouteStore(st))
	mustStartInstance(t, before, spec, false)
	if _, err := before.StartSession(context.Background(), "thread-1", draftModelSelections("model-a", "high")); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	if err := before.SetConfigOption(context.Background(), provider.SetConfigOptionInput{
		ThreadID: "thread-1", OptionID: "model", Value: "model-b", Category: provider.ConfigOptionCategoryModel,
	}); err != nil {
		t.Fatalf("SetConfigOption: %v", err)
	}
	// The following turn rebinds the live route with the projection's view: the
	// current model selection, the draft's original model entry, and the
	// provider-normalized reasoning.
	if _, err := before.StartSession(context.Background(), "thread-1", draftModelSelections("model-b", "low")); err != nil {
		t.Fatalf("following-turn StartSession: %v", err)
	}
	following := draftModelSelections("model-b", "low")
	following.ConfigSelections[0].Value = "model-a"
	if _, err := before.StartSession(context.Background(), "thread-1", following); err != nil {
		t.Fatalf("stale projection StartSession: %v", err)
	}
	assertCanonicalModel(t, "following-turn adapter input", first.instance(0).lastStartInput(), "model-b", "low")
	before.Close()

	routes, err := st.LoadRoutes()
	if err != nil {
		t.Fatalf("LoadRoutes: %v", err)
	}
	assertCanonicalModel(t, "persisted route", routes["thread-1"].StartInput, "model-b", "low")

	second := &fakeAdapter{configure: resumableSessions}
	after := New(second.StartInstance, WithRouteStore(st))
	defer after.Close()
	// After a daemon restart the projection only knows the route's model, so
	// the stored route supplies the remaining preferences.
	restored := provider.StartSessionInput{ProviderInstanceID: "codex", ModelSelection: &provider.ModelSelection{Model: "model-b"}}
	if _, err := after.StartSession(context.Background(), "thread-1", restored); err != nil {
		t.Fatalf("StartSession after restart: %v", err)
	}
	assertCanonicalModel(t, "recovered adapter input", second.instance(0).lastStartInput(), "model-b", "low")
}

func TestRestoredConflictingRouteResumesWithCanonicalModel(t *testing.T) {
	st := openRouteStore(t)
	spec := fakeSpec("codex")
	if err := st.SaveInstance(spec); err != nil {
		t.Fatalf("SaveInstance: %v", err)
	}
	// Routes written before the fix kept the draft's model entry next to the
	// later model change.
	conflicting := draftModelSelections("model-b", "low")
	conflicting.ConfigSelections[0].Value = "model-a"
	conflicting.ConfigSelections = append(conflicting.ConfigSelections, provider.ConfigOptionSelection{OptionID: "fast", Value: true, Category: provider.ConfigOptionCategoryModel})
	if err := st.SaveRoute("thread-1", store.RouteRecord{InstanceID: "codex", ProviderSessionID: "sess-1", StartInput: conflicting}); err != nil {
		t.Fatalf("SaveRoute: %v", err)
	}

	adapter := &fakeAdapter{configure: resumableSessions}
	s := New(adapter.StartInstance, WithRouteStore(st))
	defer s.Close()
	restored := provider.StartSessionInput{ProviderInstanceID: "codex", ModelSelection: &provider.ModelSelection{Model: "model-b"}}
	if _, err := s.StartSession(context.Background(), "thread-1", restored); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	input := adapter.instance(0).lastStartInput()
	assertCanonicalModel(t, "recovered adapter input", input, "model-b", "low")
	if last := input.ConfigSelections[len(input.ConfigSelections)-1]; last.OptionID != "fast" || last.Value != true {
		t.Fatalf("non-model value in model category = %#v, want unchanged", last)
	}
}
