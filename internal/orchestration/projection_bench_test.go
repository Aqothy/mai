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

// benchmarkLongThread builds a thread shaped like the handoff's measured long
// session: interleaved messages and file-change tool calls with large
// old/new text payloads retained server-side.
func benchmarkLongThread(p *Projection, threadID ThreadID, fileChanges int, fileBytes int) {
	oldText := strings.Repeat("o", fileBytes)
	newText := strings.Repeat("n", fileBytes)
	sequence := uint64(2)
	for i := 0; i < fileChanges; i++ {
		p.Apply(Event{
			Sequence:   sequence,
			Type:       EventThreadMessageSent,
			OccurredAt: time.Unix(3, 0),
			Payload: EventPayload{
				ThreadID:  threadID,
				MessageID: MessageID(fmt.Sprintf("assistant-%d", i)),
				Role:      MessageRoleAssistant,
				Text:      strings.Repeat("m", 200),
			},
		})
		sequence++
		p.Apply(Event{
			Sequence:   sequence,
			Type:       EventThreadItemUpserted,
			OccurredAt: time.Unix(3, 0),
			Payload: EventPayload{
				ThreadID: threadID,
				Item: &Item{
					ID:     fmt.Sprintf("edit-%d", i),
					Kind:   provider.ItemKindFileChange,
					Status: provider.ItemStatusCompleted,
					ToolCall: &provider.ToolCall{
						Action: provider.ToolActionEdit,
						Changes: []provider.FileChange{{
							Path:    fmt.Sprintf("/tmp/file-%d.go", i),
							OldText: oldText,
							NewText: newText,
						}},
					},
				},
			},
		})
		sequence++
	}
}

// BenchmarkThreadSnapshotProjection measures the full snapshot build
// (projectThreadForClient) for a long thread; in production this runs while
// the engine mutex is held, so per-op time here is direct engine stall time
// per subscribe.
func BenchmarkThreadSnapshotProjection(b *testing.B) {
	threadID := ThreadID("bench-snapshot")
	p := benchmarkProjectionWithThread(threadID)
	benchmarkLongThread(p, threadID, 44, 32*1024)
	b.ReportAllocs()
	for b.Loop() {
		if _, err := p.ThreadSnapshot(threadID); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkThreadListSnapshot measures the sidebar snapshot across many long
// threads, which scans every timeline for pending approvals under the engine
// mutex.
func BenchmarkThreadListSnapshot(b *testing.B) {
	p := NewProjection()
	for t := 0; t < 30; t++ {
		threadID := ThreadID(fmt.Sprintf("bench-list-%d", t))
		p.Apply(Event{
			Sequence:   1,
			Type:       EventThreadCreated,
			OccurredAt: time.Unix(1, 0),
			Payload:    EventPayload{ThreadID: threadID, Title: "bench"},
		})
		benchmarkLongThread(p, threadID, 20, 1024)
	}
	b.ReportAllocs()
	for b.Loop() {
		p.ThreadListSnapshot()
	}
}
