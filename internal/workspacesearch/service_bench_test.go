//go:build darwin && arm64 && cgo

// Service-layer benchmark over a real FFF index: how the registry behaves
// under concurrent clients.
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
