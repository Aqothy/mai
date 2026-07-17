package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"sync"
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
	if got.ProviderInstanceID != "gemini" || got.ModelSelection == nil || got.ModelSelection.Model != "gemini-pro" || string(got.ModelSelection.Options) != `{"temp":1}` {
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
	if len(threads) != 3 {
		t.Fatalf("ListThreads returned %d threads, want 3: %+v", len(threads), threads)
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
	if got.StartInput.ThreadID != "thread-1" || got.StartInput.ProviderInstanceID != "gemini" || got.StartInput.Cwd != "/tmp/project" || got.StartInput.ModelSelection == nil || got.StartInput.ModelSelection.Model != "gemini-pro" || len(got.StartInput.ConfigSelections) != 1 || got.StartInput.ConfigSelections[0].OptionID != "mode" || got.StartInput.ConfigSelections[0].Value != "plan" {
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

func TestImportThreadAtomicallyDeduplicatesProviderSession(t *testing.T) {
	s := openTestStore(t)
	if err := s.SaveInstance(provider.InstanceSpec{InstanceID: "codex", Driver: "acp"}); err != nil {
		t.Fatalf("SaveInstance: %v", err)
	}
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	meta := ThreadMeta{ThreadID: "thread-import-1", Title: "Imported", Cwd: "/tmp/project", ProviderInstanceID: "codex", CreatedAt: now, UpdatedAt: now}
	route := RouteRecord{
		InstanceID:        "codex",
		ProviderSessionID: "external-session",
		StartInput:        provider.StartSessionInput{ThreadID: meta.ThreadID, ProviderInstanceID: "codex", Cwd: meta.Cwd},
	}
	threadID, imported, err := s.ImportThread(meta, route)
	if err != nil {
		t.Fatalf("ImportThread: %v", err)
	}
	if threadID != meta.ThreadID || !imported {
		t.Fatalf("first import = (%q, %v), want (%q, true)", threadID, imported, meta.ThreadID)
	}

	duplicate := meta
	duplicate.ThreadID = "thread-import-2"
	threadID, imported, err = s.ImportThread(duplicate, route)
	if err != nil {
		t.Fatalf("duplicate ImportThread: %v", err)
	}
	if threadID != meta.ThreadID || imported {
		t.Fatalf("duplicate import = (%q, %v), want (%q, false)", threadID, imported, meta.ThreadID)
	}
	threads, err := s.ListThreads()
	if err != nil {
		t.Fatalf("ListThreads: %v", err)
	}
	if len(threads) != 1 || threads[0].ThreadID != meta.ThreadID {
		t.Fatalf("imported threads = %+v, want only the first thread", threads)
	}
	routes, err := s.LoadRoutes()
	if err != nil {
		t.Fatalf("LoadRoutes: %v", err)
	}
	if len(routes) != 1 || routes[meta.ThreadID].ProviderSessionID != route.ProviderSessionID {
		t.Fatalf("imported routes = %+v", routes)
	}
}

func TestRouteStoreRejectsDuplicateProviderSessionBindings(t *testing.T) {
	s := openTestStore(t)
	if err := s.SaveInstance(provider.InstanceSpec{InstanceID: "codex", Driver: "acp"}); err != nil {
		t.Fatalf("SaveInstance: %v", err)
	}
	route := RouteRecord{InstanceID: "codex", ProviderSessionID: "shared-session"}
	if err := s.SaveRoute("thread-1", route); err != nil {
		t.Fatalf("first SaveRoute: %v", err)
	}
	if err := s.SaveRoute("thread-2", route); !errors.Is(err, ErrProviderSessionBound) {
		t.Fatalf("duplicate SaveRoute err = %v, want ErrProviderSessionBound", err)
	}
	routes, err := s.LoadRoutes()
	if err != nil {
		t.Fatalf("LoadRoutes: %v", err)
	}
	if len(routes) != 1 || routes["thread-1"].ProviderSessionID != route.ProviderSessionID {
		t.Fatalf("routes = %+v, want only the original binding", routes)
	}
}

func TestImportThreadAdoptsExistingProviderSessionRoute(t *testing.T) {
	s := openTestStore(t)
	if err := s.SaveInstance(provider.InstanceSpec{InstanceID: "codex", Driver: "acp"}); err != nil {
		t.Fatalf("SaveInstance: %v", err)
	}
	now := time.Now()
	existingMeta := ThreadMeta{ThreadID: "thread-existing", ProviderInstanceID: "codex", CreatedAt: now, UpdatedAt: now}
	if err := s.UpsertThread(existingMeta); err != nil {
		t.Fatalf("UpsertThread: %v", err)
	}
	existingRoute := RouteRecord{
		InstanceID:        "codex",
		ProviderSessionID: "existing-session",
		StartInput:        provider.StartSessionInput{ThreadID: existingMeta.ThreadID, ProviderInstanceID: "codex"},
	}
	if err := s.SaveRoute(existingMeta.ThreadID, existingRoute); err != nil {
		t.Fatalf("SaveRoute: %v", err)
	}

	candidate := ThreadMeta{ThreadID: "thread-import", ProviderInstanceID: "codex", CreatedAt: now, UpdatedAt: now}
	threadID, imported, err := s.ImportThread(candidate, existingRoute)
	if err != nil {
		t.Fatalf("ImportThread: %v", err)
	}
	if threadID != existingMeta.ThreadID || imported {
		t.Fatalf("import existing route = (%q, %v), want (%q, false)", threadID, imported, existingMeta.ThreadID)
	}
	threads, err := s.ListThreads()
	if err != nil {
		t.Fatalf("ListThreads: %v", err)
	}
	if len(threads) != 1 || threads[0].ThreadID != existingMeta.ThreadID {
		t.Fatalf("threads = %+v, want only existing thread", threads)
	}
}

func TestImportThreadDeduplicatesAfterRouteIsReleased(t *testing.T) {
	s := openTestStore(t)
	if err := s.SaveInstance(provider.InstanceSpec{InstanceID: "codex", Driver: "acp"}); err != nil {
		t.Fatalf("SaveInstance: %v", err)
	}
	now := time.Now()
	meta := ThreadMeta{ThreadID: "thread-import-1", ProviderInstanceID: "codex", CreatedAt: now, UpdatedAt: now}
	route := RouteRecord{
		InstanceID:        "codex",
		ProviderSessionID: "external-session",
		StartInput:        provider.StartSessionInput{ThreadID: meta.ThreadID, ProviderInstanceID: "codex"},
	}
	if _, imported, err := s.ImportThread(meta, route); err != nil || !imported {
		t.Fatalf("ImportThread = imported %v, err %v", imported, err)
	}
	if err := s.DeleteRoute(meta.ThreadID); err != nil {
		t.Fatalf("DeleteRoute: %v", err)
	}

	duplicate := meta
	duplicate.ThreadID = "thread-import-2"
	duplicateRoute := route
	duplicateRoute.StartInput.ThreadID = duplicate.ThreadID
	threadID, imported, err := s.ImportThread(duplicate, duplicateRoute)
	if err != nil {
		t.Fatalf("duplicate ImportThread: %v", err)
	}
	if threadID != meta.ThreadID || imported {
		t.Fatalf("duplicate import = (%q, %v), want (%q, false)", threadID, imported, meta.ThreadID)
	}
	routes, err := s.LoadRoutes()
	if err != nil {
		t.Fatalf("LoadRoutes: %v", err)
	}
	if got := routes[meta.ThreadID]; got.ProviderSessionID != route.ProviderSessionID || got.StartInput.ThreadID != meta.ThreadID {
		t.Fatalf("restored imported route = %+v", got)
	}
	threads, err := s.ListThreads()
	if err != nil {
		t.Fatalf("ListThreads: %v", err)
	}
	if len(threads) != 1 || threads[0].ThreadID != meta.ThreadID {
		t.Fatalf("imported threads = %+v, want only the original thread", threads)
	}

	conflicting := route
	conflicting.ProviderSessionID = "replacement-session"
	if err := s.SaveRoute(meta.ThreadID, conflicting); err != nil {
		t.Fatalf("SaveRoute replacement: %v", err)
	}
	if _, _, err := s.ImportThread(duplicate, duplicateRoute); err == nil {
		t.Fatal("ImportThread over replacement route err = nil")
	}
	routes, err = s.LoadRoutes()
	if err != nil {
		t.Fatalf("LoadRoutes after conflict: %v", err)
	}
	if got := routes[meta.ThreadID].ProviderSessionID; got != conflicting.ProviderSessionID {
		t.Fatalf("route after conflict = %q, want %q", got, conflicting.ProviderSessionID)
	}
}

func TestImportThreadDeduplicatesConcurrentImports(t *testing.T) {
	s := openTestStore(t)
	if err := s.SaveInstance(provider.InstanceSpec{InstanceID: "codex", Driver: "acp"}); err != nil {
		t.Fatalf("SaveInstance: %v", err)
	}
	const count = 8
	results := make(chan struct {
		threadID string
		imported bool
		err      error
	}, count)
	var wg sync.WaitGroup
	for i := range count {
		wg.Add(1)
		go func() {
			defer wg.Done()
			now := time.Now()
			threadID, imported, err := s.ImportThread(
				ThreadMeta{ThreadID: fmt.Sprintf("thread-%d", i), ProviderInstanceID: "codex", CreatedAt: now, UpdatedAt: now},
				RouteRecord{InstanceID: "codex", ProviderSessionID: "external-session"},
			)
			results <- struct {
				threadID string
				imported bool
				err      error
			}{threadID, imported, err}
		}()
	}
	wg.Wait()
	close(results)

	var existing string
	importedCount := 0
	for result := range results {
		if result.err != nil {
			t.Fatalf("ImportThread: %v", result.err)
		}
		if existing == "" {
			existing = result.threadID
		}
		if result.threadID != existing {
			t.Fatalf("concurrent imports returned %q and %q", existing, result.threadID)
		}
		if result.imported {
			importedCount++
		}
	}
	if importedCount != 1 {
		t.Fatalf("new import count = %d, want 1", importedCount)
	}
}

func TestImportThreadRollsBackWhenInstanceIsUnknown(t *testing.T) {
	s := openTestStore(t)
	now := time.Now()
	_, _, err := s.ImportThread(
		ThreadMeta{ThreadID: "thread-import", CreatedAt: now, UpdatedAt: now},
		RouteRecord{InstanceID: "missing", ProviderSessionID: "external-session"},
	)
	if err == nil {
		t.Fatal("ImportThread with unknown instance err = nil, want foreign-key error")
	}
	threads, listErr := s.ListThreads()
	if listErr != nil {
		t.Fatalf("ListThreads: %v", listErr)
	}
	if len(threads) != 0 {
		t.Fatalf("failed import left thread rows: %+v", threads)
	}
}

func TestSaveRouteRequiresKnownInstance(t *testing.T) {
	s := openTestStore(t)
	err := s.SaveRoute("thread-1", RouteRecord{InstanceID: "never-started"})
	if err == nil {
		t.Fatal("expected foreign-key error for a route without its instance")
	}
	routes, loadErr := s.LoadRoutes()
	if loadErr != nil {
		t.Fatalf("LoadRoutes: %v", loadErr)
	}
	if len(routes) != 0 {
		t.Fatalf("failed SaveRoute left rows: %+v", routes)
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
