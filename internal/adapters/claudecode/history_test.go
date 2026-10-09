package claudecode

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/Aqothy/maiD/internal/provider"
)

// Replay shows what the user saw live, built from the transcript's current
// conversation:
//   - a branch the user rewound away from is gone;
//   - parallel tool calls, written as sibling lines, are all kept;
//   - the Task tools' results make the plan;
//   - a steer the CLI folded in (only a queued_command attachment) joins its
//     turn, while commands the CLI queues itself do not;
//   - the interrupt marker ends its turn as interrupted;
//   - a slash command shows as typed;
//   - a failed API request fails its turn instead of showing as a reply;
//   - the compaction summary is not a prompt, and history before the
//     compaction stays;
//   - a background task waking the CLI starts a turn without a prompt;
//   - a title the user chose wins; a generated one is ignored.
func TestReplayMatchesLiveConversation(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	lines := []string{
		`{"type":"user","uuid":"u1","parentUuid":null,"timestamp":"2026-08-21T10:00:00Z","cwd":"/work","message":{"role":"user","content":"Old question"}}`,
		`{"type":"assistant","uuid":"a0","parentUuid":"u1","timestamp":"2026-08-21T10:00:01Z","message":{"id":"m0","role":"assistant","content":[{"type":"text","text":"Abandoned answer"}]}}`,
		// The user rewound to before u1 and asked again.
		`{"type":"user","uuid":"u2","parentUuid":null,"timestamp":"2026-08-21T10:00:02Z","cwd":"/work","message":{"role":"user","content":"Fix it"}}`,
		`{"type":"assistant","uuid":"a1","parentUuid":"u2","timestamp":"2026-08-21T10:00:03Z","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}`,
		`{"type":"assistant","uuid":"a2","parentUuid":"a1","timestamp":"2026-08-21T10:00:03Z","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"pwd"}}]}}`,
		`{"type":"user","uuid":"r1","parentUuid":"a1","timestamp":"2026-08-21T10:00:04Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"files"}]}}`,
		`{"type":"user","uuid":"r2","parentUuid":"a2","timestamp":"2026-08-21T10:00:04Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"/work"}]}}`,
		`{"type":"assistant","uuid":"p1","parentUuid":"r2","timestamp":"2026-08-21T10:00:04Z","message":{"id":"mp","role":"assistant","content":[{"type":"tool_use","id":"tc","name":"TaskCreate","input":{"subject":"Write the test","description":"d"}}]}}`,
		`{"type":"user","uuid":"p2","parentUuid":"p1","timestamp":"2026-08-21T10:00:04Z","toolUseResult":{"task":{"id":"7","subject":"Write the test"}},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tc","content":"created"}]}}`,
		`{"type":"assistant","uuid":"p3","parentUuid":"p2","timestamp":"2026-08-21T10:00:04Z","message":{"id":"mq","role":"assistant","content":[{"type":"tool_use","id":"tu","name":"TaskUpdate","input":{"taskId":"7","status":"in_progress"}}]}}`,
		`{"type":"user","uuid":"p4","parentUuid":"p3","timestamp":"2026-08-21T10:00:04Z","toolUseResult":{"success":true,"taskId":"7"},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu","content":"updated"}]}}`,
		`{"type":"attachment","uuid":"s1","parentUuid":"p4","timestamp":"2026-08-21T10:00:05Z","attachment":{"type":"queued_command","commandMode":"prompt","origin":{"kind":"human"},"prompt":"also add a test"}}`,
		`{"type":"attachment","uuid":"n1","parentUuid":"s1","timestamp":"2026-08-21T10:00:05Z","attachment":{"type":"queued_command","commandMode":"task-notification","prompt":"<task-notification>done</task-notification>"}}`,
		`{"type":"user","uuid":"i1","parentUuid":"n1","timestamp":"2026-08-21T10:00:06Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}`,
		`{"type":"user","uuid":"c1","parentUuid":"i1","timestamp":"2026-08-21T10:00:07Z","message":{"role":"user","content":"<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args>sonnet</command-args>"}}`,
		`{"type":"user","uuid":"o1","parentUuid":"c1","timestamp":"2026-08-21T10:00:07Z","message":{"role":"user","content":"<local-command-stdout>Set model to Sonnet</local-command-stdout>"}}`,
		`{"type":"user","uuid":"u3","parentUuid":"o1","timestamp":"2026-08-21T10:00:08Z","message":{"role":"user","content":"Try again"}}`,
		`{"type":"assistant","uuid":"e1","parentUuid":"u3","timestamp":"2026-08-21T10:00:09Z","isApiErrorMessage":true,"message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"API Error: Overloaded"}]}}`,
		`{"type":"system","subtype":"compact_boundary","uuid":"b1","parentUuid":null,"logicalParentUuid":"e1","timestamp":"2026-08-21T10:00:10Z"}`,
		`{"type":"user","uuid":"cs","parentUuid":"b1","timestamp":"2026-08-21T10:00:10Z","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"role":"user","content":"This session is being continued..."}}`,
		`{"type":"user","uuid":"w1","parentUuid":"cs","timestamp":"2026-08-21T10:01:00Z","origin":{"kind":"task-notification"},"message":{"role":"user","content":"<task-notification>build finished</task-notification>"}}`,
		`{"type":"assistant","uuid":"a3","parentUuid":"w1","timestamp":"2026-08-21T10:01:01Z","message":{"id":"m3","role":"assistant","content":[{"type":"text","text":"The build passed."}]}}`,
		`{"type":"ai-title","aiTitle":"Generated title"}`,
		`{"type":"custom-title","customTitle":"Chosen title"}`,
	}
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	transcript, err := readTranscriptFile(path)
	if err != nil {
		t.Fatal(err)
	}

	var turns []string
	prompts := map[string][]string{}
	states := map[string]provider.RuntimeTurnState{}
	var failure, compactionTurn, title, text string
	var plan []provider.PlanEntry
	tools := 0
	for _, event := range replayEventsFromTranscript("thread", transcript) {
		switch {
		case event.Type == provider.RuntimeEventTurnStarted:
			turns = append(turns, event.TurnID)
		case event.Type == provider.RuntimeEventTurnCompleted:
			states[event.TurnID] = event.Payload.TurnState
			if event.TurnID == "u3" {
				failure = event.Payload.Message
			}
		case event.Payload.ItemType == provider.ItemKindUserMessage:
			prompts[event.TurnID] = append(prompts[event.TurnID], event.Payload.Detail)
		case event.Payload.ItemType == provider.ItemKindContextCompaction:
			compactionTurn = event.TurnID
		case event.Type == provider.RuntimeEventItemCompleted && event.Payload.ItemType == provider.ItemKindCommandExecution:
			tools++
		case event.Type == provider.RuntimeEventContentDelta:
			text += event.Payload.Delta
		case event.Type == provider.RuntimeEventThreadMetadataUpdate:
			title = event.Payload.Title
		case event.Type == provider.RuntimeEventTurnPlanUpdated:
			plan = event.Payload.PlanEntries
		}
	}
	if !slices.Equal(turns, []string{"u2", "c1", "u3", "w1"}) {
		t.Fatalf("turns = %q", turns)
	}
	want := map[string][]string{"u2": {"Fix it", "also add a test"}, "c1": {"/model sonnet"}, "u3": {"Try again"}}
	for turn, prompt := range want {
		if !slices.Equal(prompts[turn], prompt) {
			t.Errorf("turn %s prompts = %q, want %q", turn, prompts[turn], prompt)
		}
	}
	if len(prompts["w1"]) != 0 {
		t.Errorf("wake-up turn prompts = %q, want none", prompts["w1"])
	}
	if states["u2"] != provider.RuntimeTurnInterrupted || states["u3"] != provider.RuntimeTurnFailed || failure != "API Error: Overloaded" || states["w1"] != provider.RuntimeTurnCompleted {
		t.Errorf("turn states = %v, failure %q", states, failure)
	}
	if tools != 2 {
		t.Errorf("completed tools = %d, want both parallel calls", tools)
	}
	if text != "The build passed." {
		t.Errorf("assistant text = %q, want only the current conversation's", text)
	}
	if !slices.Equal(plan, []provider.PlanEntry{{Content: "Write the test", Status: provider.PlanEntryStatusInProgress}}) {
		t.Errorf("plan = %#v", plan)
	}
	if compactionTurn != "u3" {
		t.Errorf("compaction in turn %q, want u3", compactionTurn)
	}
	if title != "Chosen title" {
		t.Errorf("replayed title = %q", title)
	}
	if summaryTitle, cwd := transcriptSummary(path); summaryTitle != "Chosen title" || cwd != "/work" {
		t.Errorf("summary = %q, %q", summaryTitle, cwd)
	}
}

// A session is listed by its first real prompt when it has no title: CLI bookkeeping and interrupt markers are skipped, and a slash
// command shows as typed.
func TestTranscriptSummaryUsesTheFirstPrompt(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	lines := []string{
		`{"type":"user","uuid":"m","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>Caveat</local-command-caveat>"}}`,
		`{"type":"user","uuid":"i","message":{"role":"user","content":"[Request interrupted by user]"}}`,
		`{"type":"user","uuid":"c","cwd":"/work","message":{"role":"user","content":"<command-name>/review</command-name><command-args>main</command-args>"}}`,
	}
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if title, cwd := transcriptSummary(path); title != "/review main" || cwd != "/work" {
		t.Fatalf("summary = %q, %q", title, cwd)
	}
}
