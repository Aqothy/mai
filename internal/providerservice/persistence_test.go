package providerservice

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"sync"
	"testing"

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
	adapter := &resumeCursorAdapter{}
	s := New(adapter.StartInstance, WithRouteStore(st))
	defer s.Close()

	spec := provider.InstanceSpec{InstanceID: "codex", Name: "codex", Driver: "fake", Config: fakeInstanceConfig([]string{"agent"})}
	if _, err := s.StartInstance(context.Background(), spec, false); err != nil {
		t.Fatalf("StartInstance: %v", err)
	}
	specs, err := st.LoadInstances()
	if err != nil {
		t.Fatalf("LoadInstances: %v", err)
	}
	if len(specs) != 1 || specs[0].InstanceID != "codex" || specs[0].Driver != "fake" || string(specs[0].Config) != string(spec.Config) {
		t.Fatalf("instance spec not persisted: %+v", specs)
	}

	input := provider.StartSessionInput{ProviderInstanceID: "codex", ModelSelection: &provider.ModelSelection{Model: "gpt"}}
	if _, err := s.StartSession(context.Background(), "thread-1", input); err != nil {
		t.Fatalf("StartSession: %v", err)
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

type flakyRouteStore struct {
	mu                   sync.Mutex
	instanceSaveFailures int
	routeSaveFailures    int
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

func (s *flakyRouteStore) LoadRoutes() (map[string]store.RouteRecord, error) { return s.routes, nil }
func (s *flakyRouteStore) LoadInstances() ([]provider.InstanceSpec, error)   { return nil, nil }

func TestRoutePersistenceHealsFailedInstanceSave(t *testing.T) {
	flaky := newFlakyRouteStore(1)
	adapter := &resumeCursorAdapter{}
	s := New(adapter.StartInstance, WithRouteStore(flaky))
	defer s.Close()

	spec := provider.InstanceSpec{InstanceID: "codex", Name: "codex", Driver: "fake", Config: fakeInstanceConfig([]string{"agent"})}
	if _, err := s.StartInstance(context.Background(), spec, false); err != nil {
		t.Fatalf("StartInstance: %v", err)
	}
	if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}

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
	adapter := &resumeCursorAdapter{}
	s := New(adapter.StartInstance, WithRouteStore(flaky))

	spec := provider.InstanceSpec{InstanceID: "codex", Name: "codex", Driver: "fake", Config: fakeInstanceConfig([]string{"agent"})}
	if _, err := s.StartInstance(context.Background(), spec, false); err != nil {
		t.Fatalf("StartInstance: %v", err)
	}

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
	adapter := &resumeCursorAdapter{}
	s := New(adapter.StartInstance, WithRouteStore(flaky))

	spec := provider.InstanceSpec{InstanceID: "codex", Name: "codex", Driver: "fake", Config: fakeInstanceConfig([]string{"agent"})}
	if _, err := s.StartInstance(context.Background(), spec, false); err != nil {
		t.Fatalf("StartInstance: %v", err)
	}
	if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}
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
	adapter := &resumeCursorAdapter{}
	s := New(adapter.StartInstance, WithRouteStore(flaky))
	defer s.Close()

	spec := provider.InstanceSpec{InstanceID: "codex", Name: "codex", Driver: "fake", Config: fakeInstanceConfig([]string{"agent"})}
	if _, err := s.StartInstance(context.Background(), spec, false); err != nil {
		t.Fatalf("StartInstance: %v", err)
	}
	if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("StartSession thread-1: %v", err)
	}
	if _, err := s.StartSession(context.Background(), "thread-2", provider.StartSessionInput{ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("StartSession thread-2: %v", err)
	}

	flaky.mu.Lock()
	defer flaky.mu.Unlock()
	if len(flaky.routes) != 2 {
		t.Fatalf("expected both routes persisted after retry, got %+v", flaky.routes)
	}
}

func TestServiceCloseKeepsDurableRoutes(t *testing.T) {
	st := openRouteStore(t)
	adapter := &resumeCursorAdapter{}
	s := New(adapter.StartInstance, WithRouteStore(st))

	spec := provider.InstanceSpec{InstanceID: "codex", Name: "codex", Driver: "fake", Config: fakeInstanceConfig([]string{"agent"})}
	if _, err := s.StartInstance(context.Background(), spec, false); err != nil {
		t.Fatalf("StartInstance: %v", err)
	}
	if _, err := s.StartSession(context.Background(), "thread-1", provider.StartSessionInput{ProviderInstanceID: "codex"}); err != nil {
		t.Fatalf("StartSession: %v", err)
	}

	s.Close()

	routes, err := st.LoadRoutes()
	if err != nil {
		t.Fatalf("LoadRoutes: %v", err)
	}
	if route, ok := routes["thread-1"]; !ok || route.ProviderSessionID != "sess-1" {
		t.Fatalf("route lost on shutdown: %+v", routes)
	}
}
