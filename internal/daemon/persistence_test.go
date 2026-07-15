package daemon

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
	"github.com/Aqothy/maiD/internal/store"
)

func TestMain(m *testing.M) {
	dataDir, err := os.MkdirTemp("", "maid-daemon-tests-")
	if err != nil {
		panic(err)
	}
	if err := os.Setenv("MAID_DATA_DIR", dataDir); err != nil {
		_ = os.RemoveAll(dataDir)
		panic(err)
	}
	code := m.Run()
	_ = os.RemoveAll(dataDir)
	os.Exit(code)
}

// newTestServer builds a server with a test-scoped metadata store. Servers
// read the store at boot (thread/route rehydration), so tests sharing the
// package-wide MAID_DATA_DIR would leak persisted threads and routes into
// each other's daemons.
func newTestServer(t *testing.T) *Server {
	t.Helper()
	metadata, err := store.Open(filepath.Join(t.TempDir(), "maid.db"))
	if err != nil {
		t.Fatalf("open metadata store: %v", err)
	}
	return newServer(newLoggerFromEnv(), metadata)
}

func TestThreadMetadataSurvivesServerRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "maid.db")
	metadata, err := store.Open(path)
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	s := newServer(newLoggerFromEnv(), metadata)

	cwd := t.TempDir()
	if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{
		Type:     orchestration.CommandThreadCreate,
		ThreadID: "thread-1",
		Title:    "Persisted thread",
		Cwd:      cwd,
	}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{
		Type:     orchestration.CommandThreadMetaUpdate,
		ThreadID: "thread-1",
		Title:    "Renamed thread",
	}); err != nil {
		t.Fatalf("thread.meta-update: %v", err)
	}
	if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{Type: orchestration.CommandThreadTurnStart, ThreadID: "thread-1", Message: &orchestration.CommandMessage{Text: "persist this thread"}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}

	if err := s.Close(); err != nil {
		t.Fatalf("server close: %v", err)
	}

	reopened, err := store.Open(path)
	if err != nil {
		t.Fatalf("reopen store: %v", err)
	}
	defer reopened.Close()
	threads, err := reopened.ListThreads()
	if err != nil {
		t.Fatalf("ListThreads: %v", err)
	}
	if len(threads) != 1 {
		t.Fatalf("expected 1 persisted thread, got %+v", threads)
	}
	if threads[0].ThreadID != "thread-1" || threads[0].Title != "Renamed thread" || threads[0].Cwd != cwd {
		t.Fatalf("unexpected persisted thread meta: %+v", threads[0])
	}
	if threads[0].CreatedAt.IsZero() || threads[0].UpdatedAt.Before(threads[0].CreatedAt) {
		t.Fatalf("timestamps not persisted sensibly: %+v", threads[0])
	}
}

func TestServerRestartRehydratesThreadStubs(t *testing.T) {
	path := filepath.Join(t.TempDir(), "maid.db")
	metadata, err := store.Open(path)
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	s := newServer(newLoggerFromEnv(), metadata)

	cwd := t.TempDir()
	if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{
		Type:     orchestration.CommandThreadCreate,
		ThreadID: "thread-1",
		Title:    "Survives restarts",
		Cwd:      cwd,
	}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{Type: orchestration.CommandThreadTurnStart, ThreadID: "thread-1", Message: &orchestration.CommandMessage{Text: "persist this thread"}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	if err := s.Close(); err != nil {
		t.Fatalf("server close: %v", err)
	}

	reopened, err := store.Open(path)
	if err != nil {
		t.Fatalf("reopen store: %v", err)
	}
	restarted := newServer(newLoggerFromEnv(), reopened)
	defer restarted.Close()

	list := restarted.orchestration.ThreadListSnapshot()
	if len(list.Snapshot.Threads) != 1 {
		t.Fatalf("thread list after restart = %#v, want the rehydrated stub", list.Snapshot.Threads)
	}
	entry := list.Snapshot.Threads[0]
	if entry.ID != "thread-1" || entry.Title != "Survives restarts" || entry.Cwd != cwd {
		t.Fatalf("rehydrated entry = %#v", entry)
	}
	if entry.Session != nil {
		t.Fatalf("rehydrated stub must be idle (no session binding), got %#v", entry.Session)
	}
	snapshot, err := restarted.orchestration.ThreadSnapshot("thread-1")
	if err != nil {
		t.Fatalf("ThreadSnapshot after restart: %v", err)
	}
	if len(snapshot.Snapshot.Thread.Timeline) != 0 {
		t.Fatalf("rehydrated timeline = %#v, want empty", snapshot.Snapshot.Thread.Timeline)
	}
	// New epoch: nothing to replay; clients resnapshot.
	if replay := restarted.orchestration.ReplayEvents(orchestration.ReplayEventsInput{}); len(replay) != 0 {
		t.Fatalf("restart replayed events: %#v", replay)
	}
}

func TestServerBootReconcilesPersistedRoutes(t *testing.T) {
	metadata, err := store.Open(filepath.Join(t.TempDir(), "maid.db"))
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	spec := provider.InstanceSpec{InstanceID: "codex", Driver: "acp"}
	if err := metadata.SaveInstance(spec); err != nil {
		t.Fatalf("SaveInstance: %v", err)
	}
	if err := metadata.SaveRoute("orphan", store.RouteRecord{InstanceID: spec.InstanceID, ProviderSessionID: "session-orphan"}); err != nil {
		t.Fatalf("SaveRoute orphan: %v", err)
	}
	now := time.Now()
	// Simulate a crash after the synchronous route write but before the
	// debounced thread row caught up with the selected instance.
	if err := metadata.UpsertThread(store.ThreadMeta{ThreadID: "visible", ProviderInstanceID: "stale-instance", ModelSelection: &provider.ModelSelection{Model: "stale-model"}, CreatedAt: now, UpdatedAt: now}); err != nil {
		t.Fatalf("UpsertThread visible: %v", err)
	}
	if err := metadata.SaveRoute("visible", store.RouteRecord{
		InstanceID:        spec.InstanceID,
		ProviderSessionID: "session-visible",
		StartInput:        provider.StartSessionInput{ModelSelection: &provider.ModelSelection{Model: "route-model"}},
	}); err != nil {
		t.Fatalf("SaveRoute visible: %v", err)
	}

	s := newServer(newLoggerFromEnv(), metadata)
	defer s.Close()
	routes, err := metadata.LoadRoutes()
	if err != nil {
		t.Fatalf("LoadRoutes: %v", err)
	}
	if _, ok := routes["orphan"]; ok {
		t.Fatalf("orphaned route survived boot reconciliation: %+v", routes)
	}
	if route, ok := routes["visible"]; !ok || route.ProviderSessionID != "session-visible" {
		t.Fatalf("visible thread route was pruned: %+v", routes)
	}
	entry, ok := s.orchestration.ThreadListEntry("visible")
	if !ok || entry.ProviderInstanceID != spec.InstanceID {
		t.Fatalf("restored provider instance = %q, want newer route instance %q", entry.ProviderInstanceID, spec.InstanceID)
	}
	if entry.ModelSelection == nil || entry.ModelSelection.Model != "route-model" {
		t.Fatalf("restored model selection = %#v, want newer route selection", entry.ModelSelection)
	}
}

type flakyThreadStore struct {
	mu       sync.Mutex
	failures int
	saved    []store.ThreadMeta
}

func (s *flakyThreadStore) UpsertThread(meta store.ThreadMeta) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.failures > 0 {
		s.failures--
		return errors.New("transient store failure")
	}
	s.saved = append(s.saved, meta)
	return nil
}

func (s *flakyThreadStore) ListThreads() ([]store.ThreadMeta, error) { return nil, nil }

func TestThreadMetaWriterRetriesFailedUpsertOnNextFlush(t *testing.T) {
	engine := orchestration.NewEngine()
	defer engine.Close()
	if _, err := engine.Dispatch(context.Background(), orchestration.Command{
		Type:     orchestration.CommandThreadCreate,
		ThreadID: "thread-1",
		Title:    "Retried",
		Cwd:      t.TempDir(),
	}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := engine.Dispatch(context.Background(), orchestration.Command{Type: orchestration.CommandThreadTurnStart, ThreadID: "thread-1", Message: &orchestration.CommandMessage{Text: "persist this thread"}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}

	flaky := &flakyThreadStore{failures: 1}
	w := &threadMetaWriter{
		engine:  engine,
		threads: flaky,
		logger:  newLoggerFromEnv(),
		dirty:   make(map[orchestration.ThreadID]struct{}),
	}

	w.markDirty("thread-1")
	w.flush() // fails and must requeue the thread
	if len(flaky.saved) != 0 {
		t.Fatalf("first flush should have failed, saved %+v", flaky.saved)
	}
	w.flush() // retries the requeued thread
	if len(flaky.saved) != 1 || flaky.saved[0].Title != "Retried" {
		t.Fatalf("failed upsert was not retried: %+v", flaky.saved)
	}

	w.flush() // nothing left dirty; no duplicate write
	if len(flaky.saved) != 1 {
		t.Fatalf("clean flush must not rewrite: %+v", flaky.saved)
	}
}

func TestThreadMetaWriterSkipsDraftUntilFirstTurn(t *testing.T) {
	engine := orchestration.NewEngine()
	defer engine.Close()
	threadID := orchestration.ThreadID("thread-draft-persistence")
	if _, err := engine.Dispatch(context.Background(), orchestration.Command{Type: orchestration.CommandThreadCreate, ThreadID: threadID, Title: "New thread", Cwd: t.TempDir()}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}

	stored := &flakyThreadStore{}
	w := &threadMetaWriter{engine: engine, threads: stored, logger: newLoggerFromEnv(), dirty: make(map[orchestration.ThreadID]struct{})}
	w.markDirty(threadID)
	w.flush()
	if len(stored.saved) != 0 {
		t.Fatalf("draft metadata was persisted: %+v", stored.saved)
	}

	if _, err := engine.Dispatch(context.Background(), orchestration.Command{Type: orchestration.CommandThreadTurnStart, ThreadID: threadID, Title: "Promoted title", Message: &orchestration.CommandMessage{Text: "hello"}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	w.markDirty(threadID)
	w.flush()
	if len(stored.saved) != 1 || stored.saved[0].Title != "Promoted title" {
		t.Fatalf("promoted metadata = %+v, want one row with final title", stored.saved)
	}
}

func TestMetadataDBPathUsesDataDir(t *testing.T) {
	dataDir := t.TempDir()
	t.Setenv("MAID_DATA_DIR", dataDir)

	got, err := metadataDBPath()
	if err != nil {
		t.Fatalf("metadataDBPath: %v", err)
	}
	want := filepath.Join(dataDir, "maid.db")
	if got != want {
		t.Fatalf("metadataDBPath() = %q, want %q", got, want)
	}
}

func TestServerRunsWithoutMetadataStore(t *testing.T) {
	s := newServer(newLoggerFromEnv(), nil)
	defer s.Close()
	if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{
		Type:     orchestration.CommandThreadCreate,
		ThreadID: "thread-1",
		Title:    "In-memory only",
		Cwd:      t.TempDir(),
	}); err != nil {
		t.Fatalf("thread.create without store: %v", err)
	}
}
