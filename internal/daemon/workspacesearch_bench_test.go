//go:build darwin && arm64 && cgo

// Warm workspace.searchFiles benchmark against the budget: daemon receive to
// response p95 under 35ms on a 100,000-path workspace, including the real
// WebSocket/JSON-RPC round trip a client pays on loopback.
//
//	go test ./internal/daemon -bench WorkspaceSearchFiles -benchtime 1000x
package daemon

import (
	"context"
	"testing"
	"time"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/workspacesearch/searchtest"
)

func warmWorkspaceServer(b *testing.B, root string) *Server {
	b.Helper()
	s := newServer(newLoggerFromEnv(), nil)
	b.Cleanup(func() { _ = s.Close() })
	deadline := time.Now().Add(2 * time.Minute)
	for {
		result, err := s.searchWorkspaceFiles(context.Background(), wire.WorkspaceSearchFilesParams{Cwd: root, Query: "warmup"})
		if err != nil {
			b.Fatalf("warm-up search: %v", err)
		}
		if !result.Indexing {
			return s
		}
		if time.Now().After(deadline) {
			b.Fatal("workspace index never became ready")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func BenchmarkWorkspaceSearchFilesRPC100k(b *testing.B) {
	root := searchtest.Corpus(b, 100_000)
	s := warmWorkspaceServer(b, root)
	client := newRecordingClient(b, s)
	params := wire.WorkspaceSearchFilesParams{Cwd: root, Query: "file0421go"}
	samples := make([]time.Duration, 0, b.N)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var result wire.WorkspaceSearchFilesResult
		started := time.Now()
		err := client.callErr(wire.MethodWorkspaceSearchFiles, params, &result)
		samples = append(samples, time.Since(started))
		if err != nil {
			b.Fatalf("workspace.searchFiles: %v", err)
		}
	}
	b.StopTimer()
	searchtest.ReportPercentiles(b, samples)
}
