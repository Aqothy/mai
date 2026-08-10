package workspacesearch

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/workspacesearch/fff"
)

// fakeFinder is a controllable fff.Finder for registry-lifecycle tests.
type fakeFinder struct {
	root    string
	matches []fff.FileMatch

	scanDone chan struct{}

	mu       sync.Mutex
	closed   bool
	searches int
}

func newFakeFinder(root string) *fakeFinder {
	done := make(chan struct{})
	close(done)
	return &fakeFinder{
		root:     root,
		scanDone: done,
		matches: []fff.FileMatch{
			{RelativePath: "src/" + filepath.Base(root) + ".go", DisplayName: filepath.Base(root) + ".go"},
		},
	}
}

func (f *fakeFinder) WaitReady(ctx context.Context) error {
	select {
	case <-f.scanDone:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (f *fakeFinder) SearchFiles(string, int) ([]fff.FileMatch, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.closed {
		return nil, fff.ErrClosed
	}
	f.searches++
	return f.matches, nil
}

func (f *fakeFinder) ScanProgress() (fff.ScanProgress, error) {
	return fff.ScanProgress{}, nil
}

func (f *fakeFinder) Close() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.closed = true
	return nil
}

func (f *fakeFinder) isClosed() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.closed
}

// testService returns a registry whose factory records every created fake.
func testService(t *testing.T) (*Service, *sync.Map, *atomic.Int32) {
	t.Helper()
	var created sync.Map
	var creations atomic.Int32
	s := NewService()
	s.newIndex = func(root string) (fff.Finder, error) {
		creations.Add(1)
		finder := newFakeFinder(root)
		created.Store(root, finder)
		return finder, nil
	}
	t.Cleanup(s.Close)
	return s, &created, &creations
}

func makeRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatalf("resolve root: %v", err)
	}
	return root
}

func TestConcurrentFirstSearchesCreateOneIndex(t *testing.T) {
	s, _, creations := testService(t)
	root := makeRoot(t)

	var wg sync.WaitGroup
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := s.Search(context.Background(), root, "query", 10); err != nil {
				t.Errorf("Search: %v", err)
			}
		}()
	}
	wg.Wait()
	if got := creations.Load(); got != 1 {
		t.Fatalf("expected exactly one index creation, got %d", got)
	}
}

func TestSearchesForDistinctRootsDoNotMix(t *testing.T) {
	s, _, _ := testService(t)
	rootA, rootB := makeRoot(t), makeRoot(t)

	resultA, err := s.Search(context.Background(), rootA, "q", 10)
	if err != nil {
		t.Fatalf("Search rootA: %v", err)
	}
	resultB, err := s.Search(context.Background(), rootB, "q", 10)
	if err != nil {
		t.Fatalf("Search rootB: %v", err)
	}
	wantA := "src/" + filepath.Base(rootA) + ".go"
	wantB := "src/" + filepath.Base(rootB) + ".go"
	if resultA.Entries[0].RelativePath != wantA || resultB.Entries[0].RelativePath != wantB {
		t.Fatalf("results mixed roots: %v vs %v", resultA.Entries, resultB.Entries)
	}
}

func TestWarmingIndexReportsIndexingWithoutError(t *testing.T) {
	s, _, _ := testService(t)
	root := makeRoot(t)
	scanning := &fakeFinder{root: root, scanDone: make(chan struct{})}
	s.newIndex = func(string) (fff.Finder, error) { return scanning, nil }

	result, err := s.Search(context.Background(), root, "q", 10)
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if !result.Indexing || len(result.Entries) != 0 {
		t.Fatalf("expected indexing result, got %+v", result)
	}

	close(scanning.scanDone)
	scanning.matches = []fff.FileMatch{{RelativePath: "a.go", DisplayName: "a.go"}}
	result, err = s.Search(context.Background(), root, "q", 10)
	if err != nil {
		t.Fatalf("Search after scan: %v", err)
	}
	if result.Indexing || len(result.Entries) != 1 {
		t.Fatalf("expected warm result, got %+v", result)
	}
}

func TestSlowCreationReportsIndexingThenRecovers(t *testing.T) {
	s, _, _ := testService(t)
	root := makeRoot(t)
	release := make(chan struct{})
	s.newIndex = func(root string) (fff.Finder, error) {
		<-release
		return newFakeFinder(root), nil
	}

	result, err := s.Search(context.Background(), root, "q", 10)
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if !result.Indexing {
		t.Fatalf("expected indexing while creation is pending, got %+v", result)
	}
	close(release)
	deadline := time.Now().Add(5 * time.Second)
	for {
		result, err = s.Search(context.Background(), root, "q", 10)
		if err != nil {
			t.Fatalf("Search: %v", err)
		}
		if !result.Indexing {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("index never became ready")
		}
	}
}

func TestFailedInitializationSurfacesErrorAndAllowsRetry(t *testing.T) {
	s, _, _ := testService(t)
	root := makeRoot(t)
	bootErr := errors.New("boom")
	var fail atomic.Bool
	fail.Store(true)
	base := s.newIndex
	s.newIndex = func(root string) (fff.Finder, error) {
		if fail.Load() {
			return nil, bootErr
		}
		return base(root)
	}

	waitForSettledError := func() error {
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			if _, err := s.Search(context.Background(), root, "q", 10); err != nil {
				return err
			}
			time.Sleep(5 * time.Millisecond)
		}
		return nil
	}
	if err := waitForSettledError(); !errors.Is(err, bootErr) {
		t.Fatalf("expected initialization error, got %v", err)
	}

	fail.Store(false)
	deadline := time.Now().Add(5 * time.Second)
	for {
		result, err := s.Search(context.Background(), root, "q", 10)
		if err == nil && !result.Indexing {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("retry never succeeded: %v", err)
		}
	}
}

func TestValidationRejectsBadInputsWithoutCreatingIndexes(t *testing.T) {
	s, _, creations := testService(t)
	root := makeRoot(t)

	if _, err := s.Search(context.Background(), "relative/path", "q", 10); !errors.Is(err, ErrInvalidRoot) {
		t.Fatalf("expected ErrInvalidRoot for relative path, got %v", err)
	}
	if _, err := s.Search(context.Background(), filepath.Join(root, "missing"), "q", 10); !errors.Is(err, ErrInvalidRoot) {
		t.Fatalf("expected ErrInvalidRoot for missing dir, got %v", err)
	}
	file := filepath.Join(root, "file.txt")
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Search(context.Background(), file, "q", 10); !errors.Is(err, ErrInvalidRoot) {
		t.Fatalf("expected ErrInvalidRoot for non-directory, got %v", err)
	}
	if _, err := s.Search(context.Background(), root, strings.Repeat("q", MaxQueryBytes+1), 10); !errors.Is(err, ErrQueryTooLong) {
		t.Fatalf("expected ErrQueryTooLong, got %v", err)
	}
	if got := creations.Load(); got != 0 {
		t.Fatalf("invalid requests created %d indexes", got)
	}
}

func TestSanitizeEntriesFiltersAndDeduplicates(t *testing.T) {
	entries := sanitizeEntries([]fff.FileMatch{
		{RelativePath: "src/ok.go", DisplayName: "ok.go"},
		{RelativePath: "src/ok.go", DisplayName: "ok.go"},
		{RelativePath: "src/../src/ok.go", DisplayName: "ok.go"},
		{RelativePath: "../escape.go", DisplayName: "escape.go"},
		{RelativePath: "/abs/path.go", DisplayName: "path.go"},
		{RelativePath: "..", DisplayName: ".."},
		{RelativePath: "nested/название.md", DisplayName: ""},
	})
	if len(entries) != 2 {
		t.Fatalf("expected 2 sanitized entries, got %+v", entries)
	}
	if entries[0].RelativePath != "src/ok.go" {
		t.Fatalf("unexpected first entry: %+v", entries[0])
	}
	if entries[1].RelativePath != "nested/название.md" || entries[1].DisplayName != "название.md" {
		t.Fatalf("unexpected second entry: %+v", entries[1])
	}
}

func TestLimitDefaultsAndClamping(t *testing.T) {
	s, created, _ := testService(t)
	root := makeRoot(t)

	recordedLimits := make(chan int, 3)
	s.newIndex = func(root string) (fff.Finder, error) {
		finder := &limitRecordingFinder{fakeFinder: newFakeFinder(root), limits: recordedLimits}
		created.Store(root, finder)
		return finder, nil
	}
	for _, requested := range []int{0, -5, 1000} {
		if _, err := s.Search(context.Background(), root, "q", requested); err != nil {
			t.Fatalf("Search limit %d: %v", requested, err)
		}
	}
	for _, want := range []int{DefaultLimit, 1, MaxLimit} {
		if got := <-recordedLimits; got != want {
			t.Fatalf("expected limit %d, got %d", want, got)
		}
	}
}

type limitRecordingFinder struct {
	*fakeFinder
	limits chan int
}

func (f *limitRecordingFinder) SearchFiles(query string, limit int) ([]fff.FileMatch, error) {
	f.limits <- limit
	return f.fakeFinder.SearchFiles(query, limit)
}

func TestIdleEvictionClosesOnlyIdleIndexes(t *testing.T) {
	s, created, _ := testService(t)
	rootIdle, rootFresh := makeRoot(t), makeRoot(t)

	base := time.Now()
	current := base
	var clockMu sync.Mutex
	s.now = func() time.Time {
		clockMu.Lock()
		defer clockMu.Unlock()
		return current
	}

	if _, err := s.Search(context.Background(), rootIdle, "q", 10); err != nil {
		t.Fatal(err)
	}
	clockMu.Lock()
	current = base.Add(idleTTL - time.Minute)
	clockMu.Unlock()
	if _, err := s.Search(context.Background(), rootFresh, "q", 10); err != nil {
		t.Fatal(err)
	}
	clockMu.Lock()
	current = base.Add(idleTTL + time.Minute)
	clockMu.Unlock()
	s.evictIdle()

	idleFinder, _ := created.Load(rootIdle)
	freshFinder, _ := created.Load(rootFresh)
	if !idleFinder.(*fakeFinder).isClosed() {
		t.Fatal("idle index was not closed")
	}
	if freshFinder.(*fakeFinder).isClosed() {
		t.Fatal("fresh index was closed")
	}
	if _, err := s.Search(context.Background(), rootIdle, "q", 10); err != nil {
		t.Fatalf("evicted root must reopen cleanly: %v", err)
	}
}

func TestMaxIndexBoundEvictsLeastRecentlyUsed(t *testing.T) {
	s, created, _ := testService(t)

	roots := make([]string, maxIndexes+1)
	base := time.Now()
	current := base
	s.now = func() time.Time { return current }
	for i := range roots {
		roots[i] = makeRoot(t)
		current = base.Add(time.Duration(i) * time.Second)
		if _, err := s.Search(context.Background(), roots[i], "q", 10); err != nil {
			t.Fatal(err)
		}
	}

	first, _ := created.Load(roots[0])
	waitClosed := func(f *fakeFinder) bool {
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			if f.isClosed() {
				return true
			}
			time.Sleep(5 * time.Millisecond)
		}
		return false
	}
	if !waitClosed(first.(*fakeFinder)) {
		t.Fatal("LRU index was not evicted at the bound")
	}
	s.mu.Lock()
	count := len(s.indexes)
	s.mu.Unlock()
	if count != maxIndexes {
		t.Fatalf("expected %d indexes after eviction, got %d", maxIndexes, count)
	}
	for _, root := range roots[1:] {
		finder, _ := created.Load(root)
		if finder.(*fakeFinder).isClosed() {
			t.Fatalf("non-LRU index for %s was closed", root)
		}
	}
}

func TestCloseShutsDownAllIndexesAndRejectsRequests(t *testing.T) {
	s, created, _ := testService(t)
	roots := []string{makeRoot(t), makeRoot(t)}
	for _, root := range roots {
		if _, err := s.Search(context.Background(), root, "q", 10); err != nil {
			t.Fatal(err)
		}
	}
	s.Close()
	for _, root := range roots {
		finder, _ := created.Load(root)
		if !finder.(*fakeFinder).isClosed() {
			t.Fatalf("index for %s not closed on shutdown", root)
		}
	}
	if _, err := s.Search(context.Background(), roots[0], "q", 10); !errors.Is(err, ErrClosed) {
		t.Fatalf("expected ErrClosed after shutdown, got %v", err)
	}
	// Close must stay idempotent.
	s.Close()
}

func TestCanonicalRootSharesSymlinkedAliases(t *testing.T) {
	s, _, creations := testService(t)
	root := makeRoot(t)
	alias := filepath.Join(filepath.Dir(root), fmt.Sprintf("alias-%d", time.Now().UnixNano()))
	if err := os.Symlink(root, alias); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	defer os.Remove(alias)

	if _, err := s.Search(context.Background(), root, "q", 10); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Search(context.Background(), alias, "q", 10); err != nil {
		t.Fatal(err)
	}
	if got := creations.Load(); got != 1 {
		t.Fatalf("symlinked alias created a second index (%d creations)", got)
	}
}
