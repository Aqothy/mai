package daemon

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/Aqothy/maiD/internal/orchestration"
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
