//go:build darwin && arm64 && cgo

// Service-layer benchmarks over a real FFF index: what root
// canonicalization, registry lookup, and result sanitization add on top of
// the native search, and how the registry behaves under concurrent clients.
//
//	go test ./internal/workspacesearch -bench . -benchtime 1000x
package workspacesearch

import (
	"context"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/workspacesearch/searchtest"
)

func warmBenchService(b *testing.B, root string) *Service {
	b.Helper()
	s := NewService()
	b.Cleanup(s.Close)
	deadline := time.Now().Add(2 * time.Minute)
	for {
		result, err := s.Search(context.Background(), root, "warmup", 50)
		if err != nil {
			b.Fatalf("warm-up search: %v", err)
		}
		if !result.Indexing {
			return s
		}
		if time.Now().After(deadline) {
			b.Fatal("index never became ready")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func BenchmarkServiceWarmSearch100k(b *testing.B) {
	root := searchtest.Corpus(b, 100_000)
	s := warmBenchService(b, root)
	ctx := context.Background()
	samples := make([]time.Duration, 0, b.N)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		started := time.Now()
		if _, err := s.Search(ctx, root, "file0421go", 50); err != nil {
			b.Fatalf("Search: %v", err)
		}
		samples = append(samples, time.Since(started))
	}
	b.StopTimer()
	searchtest.ReportPercentiles(b, samples)
}

// BenchmarkServiceWarmSearchParallel models several clients querying one
// workspace at once; the registry lock must not serialize native searches.
func BenchmarkServiceWarmSearchParallel100k(b *testing.B) {
	root := searchtest.Corpus(b, 100_000)
	s := warmBenchService(b, root)
	ctx := context.Background()
	b.ReportAllocs()
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			if _, err := s.Search(ctx, root, "file0421go", 50); err != nil {
				b.Fatalf("Search: %v", err)
			}
		}
	})
}
