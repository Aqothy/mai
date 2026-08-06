//go:build darwin && cgo

// Integration tests against the real vendored FFF library. They cover the
// ownership and lifecycle rules the wrapper promises: ranking, ignore rules,
// Unicode paths, empty results, repeated search stability, watcher
// convergence, and close behavior under concurrency.
package fff

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"
)

func writeFixtureFile(t *testing.T, root, relative string) {
	t.Helper()
	path := filepath.Join(root, filepath.FromSlash(relative))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", relative, err)
	}
	if err := os.WriteFile(path, []byte("fixture\n"), 0o644); err != nil {
		t.Fatalf("write %s: %v", relative, err)
	}
}

// newFixtureFinder builds a small git workspace so .gitignore semantics are
// exercised the same way they are in real workspaces.
func newFixtureFinder(t *testing.T) (Finder, string) {
	t.Helper()
	root := t.TempDir()
	// FSEvents reports the /private-prefixed real path on macOS; index the
	// canonical root so watcher updates land in the same index.
	root, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatalf("resolve fixture root: %v", err)
	}
	for _, relative := range []string{
		"README.md",
		"src/main.go",
		"src/service.go",
		"clients/swift/PromptComposer.swift",
		"docs/тест-файл.md",
		"ignored/secret.txt",
	} {
		writeFixtureFile(t, root, relative)
	}
	if err := os.WriteFile(filepath.Join(root, ".gitignore"), []byte("ignored/\n"), 0o644); err != nil {
		t.Fatalf("write .gitignore: %v", err)
	}
	git := exec.Command("git", "init", "-q", root)
	if output, err := git.CombinedOutput(); err != nil {
		t.Fatalf("git init: %v: %s", err, output)
	}

	finder, err := New(root)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	t.Cleanup(func() { _ = finder.Close() })

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := finder.WaitReady(ctx); err != nil {
		t.Fatalf("WaitReady: %v", err)
	}
	return finder, root
}

func relativePaths(matches []FileMatch) []string {
	paths := make([]string, len(matches))
	for i, match := range matches {
		paths[i] = match.RelativePath
	}
	return paths
}

func TestSearchRanksFuzzyMatchFirst(t *testing.T) {
	finder, _ := newFixtureFinder(t)
	matches, err := finder.SearchFiles("promptcomp", 10)
	if err != nil {
		t.Fatalf("SearchFiles: %v", err)
	}
	if len(matches) == 0 {
		t.Fatal("expected at least one match for promptcomp")
	}
	if matches[0].RelativePath != "clients/swift/PromptComposer.swift" {
		t.Fatalf("expected PromptComposer.swift first, got %v", relativePaths(matches))
	}
	if matches[0].DisplayName != "PromptComposer.swift" {
		t.Fatalf("expected display name PromptComposer.swift, got %q", matches[0].DisplayName)
	}
}

func TestEmptyQueryReturnsDefaultOrdering(t *testing.T) {
	finder, _ := newFixtureFinder(t)
	matches, err := finder.SearchFiles("", 50)
	if err != nil {
		t.Fatalf("SearchFiles: %v", err)
	}
	if len(matches) < 5 {
		t.Fatalf("expected the fixture files for an empty query, got %v", relativePaths(matches))
	}
}

func TestSearchObservesGitignore(t *testing.T) {
	finder, _ := newFixtureFinder(t)
	matches, err := finder.SearchFiles("secret", 10)
	if err != nil {
		t.Fatalf("SearchFiles: %v", err)
	}
	if slices.Contains(relativePaths(matches), "ignored/secret.txt") {
		t.Fatalf("gitignored file leaked into results: %v", relativePaths(matches))
	}
}

func TestSearchFindsUnicodePath(t *testing.T) {
	finder, _ := newFixtureFinder(t)
	matches, err := finder.SearchFiles("тест", 10)
	if err != nil {
		t.Fatalf("SearchFiles: %v", err)
	}
	if !slices.Contains(relativePaths(matches), "docs/тест-файл.md") {
		t.Fatalf("expected docs/тест-файл.md, got %v", relativePaths(matches))
	}
}

func TestSearchNoResults(t *testing.T) {
	finder, _ := newFixtureFinder(t)
	matches, err := finder.SearchFiles("zzzzqqqqxxxx", 10)
	if err != nil {
		t.Fatalf("SearchFiles: %v", err)
	}
	if len(matches) != 0 {
		t.Fatalf("expected no matches, got %v", relativePaths(matches))
	}
}

func TestRepeatedSearchIsStable(t *testing.T) {
	finder, _ := newFixtureFinder(t)
	for i := 0; i < 500; i++ {
		if _, err := finder.SearchFiles("main", 20); err != nil {
			t.Fatalf("SearchFiles iteration %d: %v", i, err)
		}
	}
}

func TestWatcherConvergence(t *testing.T) {
	finder, root := newFixtureFinder(t)

	waitForPresence := func(query, relative string, present bool) {
		t.Helper()
		deadline := time.Now().Add(10 * time.Second)
		for time.Now().Before(deadline) {
			matches, err := finder.SearchFiles(query, 50)
			if err != nil {
				t.Fatalf("SearchFiles: %v", err)
			}
			if slices.Contains(relativePaths(matches), relative) == present {
				return
			}
			time.Sleep(50 * time.Millisecond)
		}
		t.Fatalf("index did not converge: want %q present=%v", relative, present)
	}

	created := filepath.Join(root, "src", "created_later.go")
	if err := os.WriteFile(created, []byte("package src\n"), 0o644); err != nil {
		t.Fatalf("create file: %v", err)
	}
	waitForPresence("created_later", "src/created_later.go", true)

	renamed := filepath.Join(root, "src", "renamed_later.go")
	if err := os.Rename(created, renamed); err != nil {
		t.Fatalf("rename file: %v", err)
	}
	waitForPresence("renamed_later", "src/renamed_later.go", true)
	waitForPresence("created_later", "src/created_later.go", false)

	if err := os.Remove(renamed); err != nil {
		t.Fatalf("remove file: %v", err)
	}
	waitForPresence("renamed_later", "src/renamed_later.go", false)
}

func TestCloseIsIdempotentAndRejectsLaterCalls(t *testing.T) {
	finder, _ := newFixtureFinder(t)
	if err := finder.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if err := finder.Close(); err != nil {
		t.Fatalf("second Close: %v", err)
	}
	if _, err := finder.SearchFiles("main", 10); !errors.Is(err, ErrClosed) {
		t.Fatalf("expected ErrClosed from search, got %v", err)
	}
	if _, err := finder.ScanProgress(); !errors.Is(err, ErrClosed) {
		t.Fatalf("expected ErrClosed from progress, got %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := finder.WaitReady(ctx); !errors.Is(err, ErrClosed) {
		t.Fatalf("expected ErrClosed from WaitReady, got %v", err)
	}
}

func TestConcurrentSearchAndClose(t *testing.T) {
	finder, _ := newFixtureFinder(t)
	var wg sync.WaitGroup
	for worker := 0; worker < 8; worker++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 200; i++ {
				if _, err := finder.SearchFiles("main", 10); err != nil {
					if errors.Is(err, ErrClosed) {
						return
					}
					t.Errorf("SearchFiles: %v", err)
					return
				}
			}
		}()
	}
	time.Sleep(10 * time.Millisecond)
	if err := finder.Close(); err != nil {
		t.Fatalf("Close during searches: %v", err)
	}
	wg.Wait()
}

func TestSearchRejectsNonPositiveLimit(t *testing.T) {
	finder, _ := newFixtureFinder(t)
	if _, err := finder.SearchFiles("main", 0); err == nil {
		t.Fatal("expected error for limit 0")
	}
}
