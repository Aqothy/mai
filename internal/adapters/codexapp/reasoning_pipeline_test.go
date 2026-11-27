package codexapp

import (
	"encoding/json"
	"reflect"
	"slices"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
	"github.com/Aqothy/maiD/internal/provider/providertest"
)

// What streams live folds to the entries History maps from the same items:
// reasoning streamed in parts, reasoning that streamed nothing, a draft
// corrected by its completed item, and adjacent reasoning items kept apart.
func TestLiveAndHistoryAgree(t *testing.T) {
	const thread, turn = "reasoning-thread", "reasoning-turn"
	events := providertest.NewRecorder()
	h := &Instance{host: provider.Host{Emit: events.Emit}, sessions: map[string]*sessionState{}}
	clientID := "delivery-1"
	user := appItem{Type: "userMessage", ID: "user-1", ClientID: &clientID, Content: []appUserInput{{Type: "text", Text: "Think it through"}}}
	first := appItem{Type: "reasoning", ID: "thought-1", Summary: []string{"**Planning**\n\nOne café 👩🏽‍💻", "**Checking**"}, ReasoningContent: []string{"Detail α", "Detail β"}}
	second := appItem{Type: "reasoning", ID: "thought-2", Summary: []string{"Recovered without deltas"}}
	tool := appItem{Type: "commandExecution", ID: "tool-1", Status: "completed", Command: "echo fixture"}
	third := appItem{Type: "reasoning", ID: "thought-3", Summary: []string{"**Corrected**", "Finish"}}
	reply := appItem{Type: "agentMessage", ID: "answer", Text: "DONE café 👩🏽‍💻"}
	delta := func(item, part string, index int, text string, stream provider.StreamKind) {
		t.Helper()
		values := map[string]any{"threadId": thread, "turnId": turn, "itemId": item, "delta": text, "summaryIndex": index, "contentIndex": index}
		raw, err := json.Marshal(values)
		if err != nil {
			t.Fatal(err)
		}
		h.textDelta(raw, stream, part)
	}

	h.turnStarted(thread, turn)
	h.item(true, thread, turn, user, 0, 0)
	delta(first.ID, "summary", 0, "**Plan", provider.StreamReasoning)
	delta(first.ID, "summary", 0, "ning**\n\nOne café 👩🏽‍💻", provider.StreamReasoning)
	delta(first.ID, "summary", 1, "**Checking**\n", provider.StreamReasoning)
	delta(first.ID, "content", 0, "Detail α", provider.StreamReasoning)
	delta(first.ID, "content", 1, "Detail β", provider.StreamReasoning)
	if live := events.LiveTurns(thread); live[0].Entries[1].Text != "**Planning**\n\nOne café 👩🏽‍💻\n\n**Checking**\n\nDetail α\n\nDetail β" {
		t.Fatalf("streamed reasoning = %q", live[0].Entries[1].Text)
	}
	h.item(true, thread, turn, first, 0, 0)
	h.item(true, thread, turn, second, 0, 0)
	started := tool
	started.Status = "inProgress"
	h.item(false, thread, turn, started, 0, 0)
	h.item(true, thread, turn, tool, 0, 0)
	delta(third.ID, "summary", 0, "**Draft**", provider.StreamReasoning)
	h.item(true, thread, turn, third, 0, 0)
	h.item(true, thread, turn, reply, 0, 0)
	h.turnCompleted(thread, appTurn{ID: turn, Status: "completed"})

	replayed, _ := historyTurns([]appTurn{{ID: turn, Status: "completed", Items: []appItem{user, first, second, tool, third, reply}}}, time.Time{})
	live, want := comparable(events.LiveTurns(thread)), comparable(replayed)
	if !reflect.DeepEqual(live, want) {
		t.Fatalf("live = %#v\nhistory = %#v", live, want)
	}
	var refs []string
	for _, entry := range want[0].Entries {
		refs = append(refs, entry.Ref+" "+string(entry.Kind))
	}
	if !slices.Equal(refs, []string{"user-1 user_message", "thought-1 reasoning", "thought-2 reasoning", "tool-1 command_execution", "thought-3 reasoning", "answer assistant_message"}) {
		t.Fatalf("entries = %q", refs)
	}
	if want[0].Entries[0].Delivery != clientID {
		t.Fatalf("user entry = %#v, want the delivery it carried", want[0].Entries[0])
	}
}

// comparable drops the times, which live are the stream's and in history the
// items'.
func comparable(turns []provider.HistoryTurn) []provider.HistoryTurn {
	out := slices.Clone(turns)
	for index := range out {
		out[index].StartedAt = time.Time{}
		out[index].Entries = slices.Clone(out[index].Entries)
		for entry := range out[index].Entries {
			out[index].Entries[entry].At = time.Time{}
		}
	}
	return out
}
