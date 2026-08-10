//go:build darwin && arm64 && cgo

// Warm native path-query benchmarks against the plan's budget:
// p95 under 20ms on a 100,000-path workspace.
//
//	go test ./internal/workspacesearch/fff -bench . -benchtime 1000x
package fff

import (
	"context"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/workspacesearch/searchtest"
)

func warmBenchFinder(b *testing.B, root string) Finder {
	b.Helper()
	finder, err := New(root)
	if err != nil {
		b.Fatalf("New: %v", err)
	}
	b.Cleanup(func() { _ = finder.Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	started := time.Now()
	if err := finder.WaitReady(ctx); err != nil {
		b.Fatalf("WaitReady: %v", err)
	}
	b.Logf("cold scan of %s took %s", root, time.Since(started).Round(time.Millisecond))
	return finder
}

func benchmarkWarmSearch(b *testing.B, fileCount int, query string) {
	finder := warmBenchFinder(b, searchtest.Corpus(b, fileCount))
	samples := make([]time.Duration, 0, b.N)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		started := time.Now()
		if _, err := finder.SearchFiles(query, 50); err != nil {
			b.Fatalf("SearchFiles: %v", err)
		}
		samples = append(samples, time.Since(started))
	}
	b.StopTimer()
	searchtest.ReportPercentiles(b, samples)
}

func BenchmarkWarmSearch100k(b *testing.B) {
	const files = 100_000
	// Query shapes: a selective fuzzy needle, a broad needle matching every
	// file, a directory-scoped needle, a no-match worst case, and the empty
	// query serving default ordering.
	b.Run("selective", func(b *testing.B) { benchmarkWarmSearch(b, files, "file0421go") })
	b.Run("broad", func(b *testing.B) { benchmarkWarmSearch(b, files, "source") })
	b.Run("scoped", func(b *testing.B) { benchmarkWarmSearch(b, files, "pkg042/mod05") })
	b.Run("nomatch", func(b *testing.B) { benchmarkWarmSearch(b, files, "zzzzqqqqxxxx") })
	b.Run("empty", func(b *testing.B) { benchmarkWarmSearch(b, files, "") })
}

func BenchmarkWarmSearchSmall(b *testing.B) {
	benchmarkWarmSearch(b, 2_000, "file0004go")
}
