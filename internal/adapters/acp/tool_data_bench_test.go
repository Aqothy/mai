package acp

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/Aqothy/go-acp/schema"
)

// BenchmarkToolCallUpdateAccumulation replays the reconcileToolState data
// path for one large file edit: a sparse start, one content update carrying
// the full old/new text, then trailing sparse status updates. Each update
// pays patch extraction, overlay, and conversion to the complete neutral
// snapshot — the same work production performs per ACP tool_call_update.
func BenchmarkToolCallUpdateAccumulation(b *testing.B) {
	for _, fileKB := range []int{8, 64} {
		b.Run(fmt.Sprintf("file=%dKB", fileKB), func(b *testing.B) {
			oldText := strings.Repeat("o", fileKB*1024)
			newText := strings.Repeat("n", fileKB*1024)
			contentUpdate, err := json.Marshal(map[string]any{
				"sessionUpdate": "tool_call_update",
				"toolCallId":    "tool-1",
				"status":        "in_progress",
				"content": []map[string]any{{
					"type":    "diff",
					"path":    "/repo/main.go",
					"oldText": oldText,
					"newText": newText,
				}},
			})
			if err != nil {
				b.Fatal(err)
			}
			rawUpdates := []string{
				`{"sessionUpdate":"tool_call","toolCallId":"tool-1","title":"Edit main.go","kind":"edit","status":"pending","rawInput":{"path":"/repo/main.go"}}`,
				string(contentUpdate),
				`{"sessionUpdate":"tool_call_update","toolCallId":"tool-1","status":"in_progress"}`,
				`{"sessionUpdate":"tool_call_update","toolCallId":"tool-1","status":"in_progress"}`,
				`{"sessionUpdate":"tool_call_update","toolCallId":"tool-1","status":"completed"}`,
			}
			updates := make([]schema.SessionUpdate, len(rawUpdates))
			for index, raw := range rawUpdates {
				if err := json.Unmarshal([]byte(raw), &updates[index]); err != nil {
					b.Fatal(err)
				}
			}
			b.ReportAllocs()
			for b.Loop() {
				var accumulated *toolCallPatch
				for _, update := range updates {
					accumulated = accumulated.overlay(toolCallPatchFromUpdate(update))
					if call := accumulated.toolCall(); call == nil {
						b.Fatal("tool call is nil")
					}
				}
			}
		})
	}
}
