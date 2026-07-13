package store

import (
	"encoding/json"
	"path/filepath"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

func openTestStore(t *testing.T) *SQLite {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "maid.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func TestThreadStoreRoundTrip(t *testing.T) {
	s := openTestStore(t)

	created := time.Date(2026, 7, 13, 10, 0, 0, 123456789, time.UTC)
	meta := ThreadMeta{
		ThreadID:           "thread-1",
		Title:              "First thread",
		Cwd:                "/tmp/project",
		ProviderInstanceID: "gemini",
		ModelSelection:     &provider.ModelSelection{Model: "gemini-pro", Options: json.RawMessage(`{"temp":1}`)},
		CreatedAt:          created,
		UpdatedAt:          created,
	}
	if err := s.UpsertThread(meta); err != nil {
		t.Fatalf("UpsertThread: %v", err)
	}

	meta.Title = "Renamed"
	meta.UpdatedAt = created.Add(time.Hour)
	if err := s.UpsertThread(meta); err != nil {
		t.Fatalf("UpsertThread update: %v", err)
	}

	threads, err := s.ListThreads()
	if err != nil {
		t.Fatalf("ListThreads: %v", err)
	}
	if len(threads) != 1 {
		t.Fatalf("expected 1 thread, got %d", len(threads))
	}
	got := threads[0]
	if got.Title != "Renamed" || got.Cwd != "/tmp/project" {
		t.Fatalf("unexpected thread meta: %+v", got)
	}
	if got.ProviderInstanceID != "gemini" || got.ModelSelection == nil || got.ModelSelection.Model != "gemini-pro" {
		t.Fatalf("provider selection did not round-trip: %+v", got)
	}
	if !got.CreatedAt.Equal(created) || !got.UpdatedAt.Equal(created.Add(time.Hour)) {
		t.Fatalf("timestamps did not round-trip: created=%v updated=%v", got.CreatedAt, got.UpdatedAt)
	}
}

func TestListThreadsOrdersByUpdatedAtDescending(t *testing.T) {
	s := openTestStore(t)

	base := time.Date(2026, 7, 13, 10, 0, 0, 0, time.UTC)
	// Sub-second fractions exercise the fixed-width timestamp encoding: with
	// RFC3339Nano's trimmed zeros, "10:00:00Z" would sort after "10:00:00.5Z".
	for _, thread := range []ThreadMeta{
		{ThreadID: "oldest", CreatedAt: base, UpdatedAt: base},
		{ThreadID: "newest", CreatedAt: base, UpdatedAt: base.Add(500 * time.Millisecond)},
		{ThreadID: "middle", CreatedAt: base, UpdatedAt: base.Add(250 * time.Millisecond)},
	} {
		if err := s.UpsertThread(thread); err != nil {
			t.Fatalf("UpsertThread(%s): %v", thread.ThreadID, err)
		}
	}

	threads, err := s.ListThreads()
	if err != nil {
		t.Fatalf("ListThreads: %v", err)
	}
	var order []string
	for _, thread := range threads {
		order = append(order, thread.ThreadID)
	}
	want := []string{"newest", "middle", "oldest"}
	for i := range want {
		if order[i] != want[i] {
			t.Fatalf("expected order %v, got %v", want, order)
		}
	}
}

func TestRouteStoreRoundTrip(t *testing.T) {
	s := openTestStore(t)

	spec := provider.InstanceSpec{InstanceID: "gemini", Name: "Gemini", Driver: "acp", Config: json.RawMessage(`{"command":"gemini"}`)}
	if err := s.SaveInstance(spec); err != nil {
		t.Fatalf("SaveInstance: %v", err)
	}

	record := RouteRecord{
		InstanceID:        "gemini",
		ProviderSessionID: "native-session-1",
		ResumeCursor:      json.RawMessage(`{"sessionId":"native-session-1"}`),
		StartInput: provider.StartSessionInput{
			ThreadID:           "thread-1",
			ProviderInstanceID: "gemini",
			Cwd:                "/tmp/project",
			ModelSelection:     &provider.ModelSelection{Model: "gemini-pro"},
			ConfigSelections:   []provider.ConfigOptionSelection{{OptionID: "mode", Value: "plan"}},
		},
	}
	if err := s.SaveRoute("thread-1", record); err != nil {
		t.Fatalf("SaveRoute: %v", err)
	}

	record.ProviderSessionID = "native-session-2"
	if err := s.SaveRoute("thread-1", record); err != nil {
		t.Fatalf("SaveRoute rebind: %v", err)
	}

	routes, err := s.LoadRoutes()
	if err != nil {
		t.Fatalf("LoadRoutes: %v", err)
	}
	if len(routes) != 1 {
		t.Fatalf("expected 1 route, got %d", len(routes))
	}
	got := routes["thread-1"]
	if got.InstanceID != "gemini" || got.ProviderSessionID != "native-session-2" {
		t.Fatalf("unexpected route: %+v", got)
	}
	if string(got.ResumeCursor) != `{"sessionId":"native-session-1"}` {
		t.Fatalf("resume cursor did not round-trip: %s", got.ResumeCursor)
	}
	if got.StartInput.ModelSelection == nil || got.StartInput.ModelSelection.Model != "gemini-pro" || len(got.StartInput.ConfigSelections) != 1 {
		t.Fatalf("start input did not round-trip: %+v", got.StartInput)
	}

	if err := s.DeleteRoute("thread-1"); err != nil {
		t.Fatalf("DeleteRoute: %v", err)
	}
	routes, err = s.LoadRoutes()
	if err != nil {
		t.Fatalf("LoadRoutes after delete: %v", err)
	}
	if len(routes) != 0 {
		t.Fatalf("expected no routes after delete, got %d", len(routes))
	}

	specs, err := s.LoadInstances()
	if err != nil {
		t.Fatalf("LoadInstances: %v", err)
	}
	if len(specs) != 1 || specs[0].InstanceID != "gemini" || specs[0].Driver != "acp" || string(specs[0].Config) != `{"command":"gemini"}` {
		t.Fatalf("instance spec did not round-trip: %+v", specs)
	}
}

func TestSaveRouteRequiresKnownInstance(t *testing.T) {
	s := openTestStore(t)
	err := s.SaveRoute("thread-1", RouteRecord{InstanceID: "never-started"})
	if err == nil {
		t.Fatal("expected foreign-key error for a route without its instance")
	}
}

func TestReopenSurvivesRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "maid.db")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if err := s.UpsertThread(ThreadMeta{ThreadID: "thread-1", Title: "kept", CreatedAt: time.Now(), UpdatedAt: time.Now()}); err != nil {
		t.Fatalf("UpsertThread: %v", err)
	}
	if err := s.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	reopened, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer reopened.Close()
	threads, err := reopened.ListThreads()
	if err != nil {
		t.Fatalf("ListThreads: %v", err)
	}
	if len(threads) != 1 || threads[0].Title != "kept" {
		t.Fatalf("thread did not survive reopen: %+v", threads)
	}
}
