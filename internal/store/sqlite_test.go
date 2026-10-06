package store

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"reflect"
	"slices"
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

func TestThreadStoreRoundTripsAndOrdersByRecency(t *testing.T) {
	s := openTestStore(t)

	base := time.Date(2026, 7, 13, 10, 0, 0, 123456789, time.UTC)
	full := ThreadMeta{
		ThreadID:              "middle",
		Title:                 "First title",
		Cwd:                   "/tmp/project",
		AdditionalDirectories: []string{"/tmp/other"},
		ProviderInstanceID:    "gemini",
		ModelSelection:        &provider.ModelSelection{Model: "gemini-pro", Options: json.RawMessage(`{"temp":1}`)},
		CreatedAt:             base,
		UpdatedAt:             base,
	}
	// Sub-second fractions exercise the fixed-width timestamp encoding: with
	// RFC3339Nano's trimmed zeros, "10:00:00Z" would sort after "10:00:00.5Z".
	for _, thread := range []ThreadMeta{
		{ThreadID: "oldest", CreatedAt: base, UpdatedAt: base.Truncate(time.Second)},
		{ThreadID: "newest", CreatedAt: base, UpdatedAt: base.Add(500 * time.Millisecond)},
		full,
	} {
		if err := s.UpsertThread(thread); err != nil {
			t.Fatalf("UpsertThread(%s): %v", thread.ThreadID, err)
		}
	}
	full.Title = "Renamed"
	full.UpdatedAt = base.Add(250 * time.Millisecond)
	if err := s.UpsertThread(full); err != nil {
		t.Fatalf("UpsertThread update: %v", err)
	}

	threads, err := s.ListThreads()
	if err != nil {
		t.Fatalf("ListThreads: %v", err)
	}
	var order []string
	for _, thread := range threads {
		order = append(order, thread.ThreadID)
	}
	if !slices.Equal(order, []string{"newest", "middle", "oldest"}) {
		t.Fatalf("order = %v, want newest, middle, oldest", order)
	}
	got := threads[1]
	if !got.CreatedAt.Equal(full.CreatedAt) || !got.UpdatedAt.Equal(full.UpdatedAt) {
		t.Fatalf("timestamps did not round-trip: created=%v updated=%v", got.CreatedAt, got.UpdatedAt)
	}
	got.CreatedAt, got.UpdatedAt = full.CreatedAt, full.UpdatedAt
	if !reflect.DeepEqual(got, full) {
		t.Fatalf("thread = %+v, want %+v", got, full)
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
	if !reflect.DeepEqual(got.StartInput, record.StartInput) {
		t.Fatalf("start input = %+v, want %+v", got.StartInput, record.StartInput)
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

func TestImportThreadDeduplicatesProviderSession(t *testing.T) {
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
	if threadID, imported, err := s.ImportThread(meta, route); err != nil || !imported || threadID != meta.ThreadID {
		t.Fatalf("ImportThread = (%q, %v, %v), want a new import", threadID, imported, err)
	}
	duplicate := meta
	duplicate.ThreadID = "thread-import-2"
	duplicateRoute := route
	duplicateRoute.StartInput.ThreadID = duplicate.ThreadID
	importDuplicate := func(step string) {
		t.Helper()
		threadID, imported, err := s.ImportThread(duplicate, duplicateRoute)
		if err != nil || threadID != meta.ThreadID || imported {
			t.Fatalf("%s: duplicate import = (%q, %v, %v), want (%q, false)", step, threadID, imported, err, meta.ThreadID)
		}
	}
	importDuplicate("route bound")
	if err := s.DeleteRoute(meta.ThreadID); err != nil {
		t.Fatalf("DeleteRoute: %v", err)
	}
	importDuplicate("route released")
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
