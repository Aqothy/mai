// Package searchtest provides shared helpers for workspace-search
// benchmarks: a cached large-corpus generator and latency percentile
// reporting. Test-only; no production code imports it.
package searchtest

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"
)

// Corpus returns a workspace containing fileCount empty files spread over
// realistic nested directories. It is generated once and cached under the
// system temp directory: creating 100,000 files dominates any benchmark, so
// regenerating per run would drown the measurement.
func Corpus(tb testing.TB, fileCount int) string {
	tb.Helper()
	root := filepath.Join(os.TempDir(), fmt.Sprintf("maid-fff-bench-corpus-%d", fileCount))
	marker := filepath.Join(root, ".corpus-complete")
	if _, err := os.Stat(marker); err == nil {
		return root
	}
	if err := os.RemoveAll(root); err != nil {
		tb.Fatalf("reset corpus: %v", err)
	}
	extensions := []string{".go", ".swift", ".ts", ".md", ".json"}
	for i := 0; i < fileCount; {
		dir := filepath.Join(root,
			fmt.Sprintf("pkg%03d", i/1000),
			fmt.Sprintf("mod%02d", (i/100)%10))
		if err := os.MkdirAll(dir, 0o755); err != nil {
			tb.Fatalf("corpus mkdir: %v", err)
		}
		for j := 0; j < 100 && i < fileCount; j, i = j+1, i+1 {
			name := fmt.Sprintf("source_file_%06d%s", i, extensions[i%len(extensions)])
			if err := os.WriteFile(filepath.Join(dir, name), nil, 0o644); err != nil {
				tb.Fatalf("corpus write: %v", err)
			}
		}
	}
	if err := os.WriteFile(marker, nil, 0o644); err != nil {
		tb.Fatalf("corpus marker: %v", err)
	}
	return root
}

// ReportPercentiles attaches p50/p95/p99 latency metrics (in milliseconds)
// to a benchmark, sorting the samples in place. The plan's budgets are
// stated as percentiles, so ns/op alone cannot check them.
func ReportPercentiles(b *testing.B, samples []time.Duration) {
	if len(samples) == 0 {
		return
	}
	slices.Sort(samples)
	percentile := func(p float64) float64 {
		index := int(p * float64(len(samples)-1))
		return float64(samples[index].Nanoseconds()) / 1e6
	}
	b.ReportMetric(percentile(0.50), "p50-ms")
	b.ReportMetric(percentile(0.95), "p95-ms")
	b.ReportMetric(percentile(0.99), "p99-ms")
}
