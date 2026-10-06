package orchestration

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// benchmarkProjectionWithThread returns a projection holding one created thread.
func benchmarkProjectionWithThread(threadID ThreadID) *Projection {
	p := NewProjection()
	p.Apply(Event{
		Sequence:   1,
		Type:       EventThreadCreated,
		OccurredAt: time.Unix(1, 0),
		Payload:    EventPayload{ThreadID: threadID, Title: "bench"},
	})
	return p
}

// BenchmarkProjectionReasoningTurn replays one reasoning item receiving
// coalesced textDelta flushes, the projection-side cost of a long streamed
// thought. Sub-benchmarks vary flush count; each flush carries deltaBytes of
// text, so the accumulated payload grows linearly while per-flush apply cost
// is what the benchmark exposes.
func BenchmarkProjectionReasoningTurn(b *testing.B) {
	const deltaBytes = 400
	delta := strings.Repeat("r", deltaBytes)
	for _, flushes := range []int{50, 300} {
		b.Run(fmt.Sprintf("flushes=%d(final=%dKB)", flushes, flushes*deltaBytes/1024), func(b *testing.B) {
			threadID := ThreadID("bench-reasoning")
			b.ReportAllocs()
			for b.Loop() {
				p := benchmarkProjectionWithThread(threadID)
				for f := 0; f < flushes; f++ {
					p.Apply(Event{
						Sequence:   uint64(f + 2),
						Type:       EventThreadItemUpserted,
						OccurredAt: time.Unix(2, 0),
						Payload: EventPayload{
							ThreadID: threadID,
							Item: &Item{
								ID:        "reasoning-1",
								Kind:      provider.ItemKindReasoning,
								Status:    provider.ItemStatusInProgress,
								TextDelta: delta,
							},
						},
					})
				}
			}
		})
	}
}
