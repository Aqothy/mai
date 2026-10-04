package codexapp

import (
	"context"
	"encoding/json"
	"reflect"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
)

// Exercise the adapter and the real ingestion/projection together. Checking
// only flattened adapter text misses differences in item boundaries on reload.
func TestReasoningLiveAndReloadTimelineAgree(t *testing.T) {
	const threadID = "reasoning-thread"
	const turnID = "reasoning-turn"
	live := newReasoningPipeline(t, threadID)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtimeEvents := make(chan provider.RuntimeEvent, 64)
	runDone := make(chan struct{})
	go func() {
		defer close(runDone)
		live.ingestion.Run(ctx, runtimeEvents)
	}()
	t.Cleanup(func() { cancel(); <-runDone })
	h := &Instance{
		emit:            func(event provider.RuntimeEvent) { runtimeEvents <- event },
		sessionsByLocal: map[string]*sessionState{},
		localByNative:   map[string]string{},
	}
	h.bindSessionLocked(newSessionState(threadID, threadID, "/tmp"))
	if err := h.emitTurnStarted(threadID, turnID); err != nil {
		t.Fatal(err)
	}
	first := appItem{Type: "reasoning", ID: "thought-1", Summary: []string{"**Planning**\n\nOne café 👩🏽‍💻", "**Checking**"}, ReasoningContent: []string{"Detail α", "Detail β"}}
	second := appItem{Type: "reasoning", ID: "thought-2", Summary: []string{"Recovered without deltas"}}
	tool := appItem{Type: "commandExecution", ID: "tool-1", Status: "completed", Command: "echo fixture"}
	third := appItem{Type: "reasoning", ID: "thought-3", Summary: []string{"**Corrected**", "Finish"}}
	reply := appItem{Type: "agentMessage", ID: "answer", Text: "DONE café 👩🏽‍💻"}
	notify := func(method string, values map[string]any) {
		t.Helper()
		values["threadId"], values["turnId"], values["itemId"] = threadID, turnID, first.ID
		raw, err := json.Marshal(values)
		if err != nil {
			t.Fatal(err)
		}
		h.handleNotification(method, raw)
	}
	notify("item/reasoning/summaryTextDelta", map[string]any{"summaryIndex": 0, "delta": "**Plan"})
	notify("item/reasoning/summaryTextDelta", map[string]any{"summaryIndex": 0, "delta": "ning**\n\nOne café 👩🏽‍💻"})
	live.waitForThought(t, 0, "**Planning**\n\nOne café 👩🏽‍💻", provider.ItemStatusInProgress)
	notify("item/reasoning/summaryPartAdded", map[string]any{"summaryIndex": 1})
	notify("item/reasoning/summaryTextDelta", map[string]any{"summaryIndex": 1, "delta": "**Checking**\n"})
	notify("item/reasoning/textDelta", map[string]any{"contentIndex": 0, "delta": "Detail α"})
	notify("item/reasoning/textDelta", map[string]any{"contentIndex": 1, "delta": "Detail β"})
	live.waitForThought(t, 0, "**Planning**\n\nOne café 👩🏽‍💻\n\n**Checking**\n\nDetail α\n\nDetail β", provider.ItemStatusInProgress)
	h.emitItem("item/completed", threadID, turnID, first, 0, 0)
	live.waitForThought(t, 0, reasoningText(first), provider.ItemStatusCompleted)
	// Adjacent reasoning items must remain separate after a history reload.
	h.emitItem("item/completed", threadID, turnID, second, 0, 0)
	live.waitForThought(t, 1, reasoningText(second), provider.ItemStatusCompleted)
	startedTool := tool
	startedTool.Status = "inProgress"
	h.emitItem("item/started", threadID, turnID, startedTool, 0, 0)
	h.emitItem("item/completed", threadID, turnID, tool, 0, 0)
	h.emitTextDelta(json.RawMessage(`{"threadId":"reasoning-thread","turnId":"reasoning-turn","itemId":"thought-3","summaryIndex":0,"delta":"**Draft**"}`), provider.RuntimeContentReasoningText, "summary")
	live.waitForThought(t, 2, "**Draft**", provider.ItemStatusInProgress)
	h.emitItem("item/completed", threadID, turnID, third, 0, 0)
	live.waitForThought(t, 2, reasoningText(third), provider.ItemStatusCompleted)
	h.emitItem("item/completed", threadID, turnID, reply, 0, 0)
	h.emitTurnCompleted(threadID, appTurn{ID: turnID, Status: "completed"})
	live.waitForCompletion(t)
	cancel()
	<-runDone

	reload := newReasoningPipeline(t, threadID)
	for _, event := range replayEvents(threadID, appThread{ID: threadID, Turns: []appTurn{{ID: turnID, Status: "completed", Items: []appItem{first, second, tool, third, reply}}}}) {
		reload.ingestion.Ingest(event)
	}
	want := []reasoningTimelineValue{
		{Kind: "reasoning", ID: "reasoning:" + threadID + ":" + turnID, Status: "completed", Text: reasoningText(first)},
		{Kind: "reasoning", ID: "reasoning:" + threadID + ":" + turnID + ":2", Status: "completed", Text: reasoningText(second)},
		{Kind: "command_execution", ID: tool.ID, Status: "completed"},
		{Kind: "reasoning", ID: "reasoning:" + threadID + ":" + turnID + ":3", Status: "completed", Text: reasoningText(third)},
		{Kind: "assistant", ID: "assistant:answer", Text: reply.Text},
	}
	for label, pipeline := range map[string]*reasoningPipeline{"live": live, "reload": reload} {
		if got := pipeline.values(t); !reflect.DeepEqual(got, want) {
			t.Errorf("%s timeline = %#v; want %#v", label, got, want)
		}
	}
}

type reasoningTimelineValue struct {
	Kind, ID, Status, Text string
}

type reasoningPipeline struct {
	engine    *orchestration.Engine
	ingestion *orchestration.ProviderRuntimeIngestion
	threadID  orchestration.ThreadID
}

func newReasoningPipeline(t *testing.T, id string) *reasoningPipeline {
	t.Helper()
	e := orchestration.NewEngine()
	t.Cleanup(e.Close)
	p := &reasoningPipeline{engine: e, ingestion: orchestration.NewProviderRuntimeIngestion(e), threadID: orchestration.ThreadID(id)}
	_, err := e.Dispatch(context.Background(), orchestration.Command{Type: orchestration.CommandThreadCreate, CommandID: "create", ThreadID: p.threadID, Title: "Multipart reasoning", ProviderInstanceID: "codex"})
	if err != nil {
		t.Fatal(err)
	}
	_, err = e.AppendEvent(context.Background(), orchestration.EventInput{Type: orchestration.EventThreadSessionStatusSet, ThreadID: p.threadID, Payload: orchestration.EventPayload{Session: &orchestration.SessionBinding{ThreadID: p.threadID, ProviderInstanceID: "codex", Status: orchestration.SessionStatusReady, UpdatedAt: time.Now()}}})
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func (p *reasoningPipeline) snapshot() orchestration.Thread {
	thread, _ := p.engine.Thread(p.threadID)
	return thread
}

func (p *reasoningPipeline) values(t *testing.T) []reasoningTimelineValue {
	t.Helper()
	var values []reasoningTimelineValue
	for _, entry := range p.snapshot().Timeline {
		if item := entry.Item; item != nil {
			value := reasoningTimelineValue{Kind: string(item.Kind), ID: item.ID, Status: string(item.Status)}
			if item.Kind == provider.ItemKindReasoning {
				var payload struct{ Text string }
				if err := json.Unmarshal(item.Payload, &payload); err != nil {
					t.Fatal(err)
				}
				value.Text = payload.Text
			}
			values = append(values, value)
		} else if message := entry.Message; message != nil {
			values = append(values, reasoningTimelineValue{Kind: string(message.Role), ID: string(message.ID), Text: message.Text})
		}
	}
	return values
}

func (p *reasoningPipeline) waitForThought(t *testing.T, index int, text string, status provider.ItemStatus) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		thoughtIndex := 0
		for _, value := range p.values(t) {
			if value.Kind != "reasoning" {
				continue
			}
			if thoughtIndex == index && value.Text == text && value.Status == string(status) {
				return
			}
			thoughtIndex++
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("thought %d did not reach %q/%s; got %#v", index, text, status, p.values(t))
}

func (p *reasoningPipeline) waitForCompletion(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if turn := p.snapshot().LatestTurn; turn != nil && string(turn.State) == "completed" {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("turn did not complete: %#v", p.snapshot().LatestTurn)
}
