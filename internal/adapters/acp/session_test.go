package acp

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
	"github.com/Aqothy/maiD/internal/provider/providertest"
)

var workspace = provider.Workspace{Cwd: "/tmp"}

func testContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	t.Cleanup(cancel)
	return ctx
}

func openSession(t *testing.T, h testInstance, in provider.OpenInput) provider.Opened {
	t.Helper()
	in.Workspace = workspace
	opened, err := h.Open(testContext(t), in)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	return opened
}

func send(t *testing.T, h testInstance, session, delivery, text string) {
	t.Helper()
	ack, err := h.Send(testContext(t), session, provider.SendInput{Delivery: delivery, Text: text})
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	if ack.Turn != delivery {
		t.Fatalf("ack turn = %q, want the delivery %q", ack.Turn, delivery)
	}
}

func readHistory(t *testing.T, h testInstance, session string, after provider.Marker) provider.HistoryPage {
	t.Helper()
	page, err := h.History(testContext(t), session, workspace, after)
	if err != nil {
		t.Fatalf("History: %v", err)
	}
	return page
}

// toolUpdate is an update of the turn's one tool call, t1.
func toolUpdate(kind, status string, extra map[string]any) map[string]any {
	update := map[string]any{"sessionUpdate": kind, "toolCallId": "t1", "status": status}
	for key, value := range extra {
		update[key] = value
	}
	return update
}

func thought(text string) map[string]any {
	return map[string]any{"sessionUpdate": "agent_thought_chunk", "content": map[string]any{"type": "text", "text": text}}
}

// entrySummary is what the display shows of an entry.
type entrySummary struct {
	Ref, Kind, Status, Text, Output string
}

func summarize(turn provider.HistoryTurn) []entrySummary {
	var entries []entrySummary
	for _, entry := range turn.Entries {
		summary := entrySummary{Ref: entry.Ref, Kind: string(entry.Kind), Status: string(entry.Status), Text: entry.Text}
		if entry.Tool != nil {
			summary.Output = entry.Tool.Output
		}
		entries = append(entries, summary)
	}
	return entries
}

// A turn streamed live and the same turn read back from the session's
// history are the same entries, ref for ref.
func TestLiveEntriesEqualHistory(t *testing.T) {
	agent := &fakeWireAgent{onPrompt: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
		a.sendUpdate(params.SessionID, thought("Let me look."))
		a.sendUpdate(params.SessionID, agentMessageUpdate("", "Hello"))
		a.sendUpdate(params.SessionID, agentMessageUpdate("", " world"))
		a.sendUpdate(params.SessionID, toolUpdate("tool_call", "pending", map[string]any{"title": "ls", "kind": "execute"}))
		a.sendUpdate(params.SessionID, toolUpdate("tool_call_update", "completed", map[string]any{"content": []any{map[string]any{"type": "content", "content": map[string]any{"type": "text", "text": "a.txt"}}}}))
		a.sendUpdate(params.SessionID, agentMessageUpdate("", "Done."))
		a.respond(id, map[string]any{"stopReason": "end_turn"})
	}}
	h := newWireTestHandle(t, agent)
	opened := openSession(t, h, provider.OpenInput{})
	send(t, h, opened.Session, "d1", "List the files")
	h.events.WaitFor(t, "the turn to settle", providertest.Settled("d1"))

	live := h.events.LiveTurns(opened.Session)
	page := readHistory(t, h, opened.Session, "")
	if !reflect.DeepEqual(page.Turns, live) {
		t.Fatalf("history turns = %#v\nlive turns = %#v", page.Turns, live)
	}
	want := []entrySummary{
		{Ref: "d1/user", Kind: "user_message", Status: "completed", Text: "List the files"},
		{Ref: "d1/m1", Kind: "reasoning", Status: "completed", Text: "Let me look."},
		{Ref: "d1/m2", Kind: "assistant_message", Status: "completed", Text: "Hello world"},
		{Ref: "d1/tool/t1", Kind: "command_execution", Status: "completed", Output: "a.txt"},
		{Ref: "d1/m3", Kind: "assistant_message", Status: "completed", Text: "Done."},
	}
	if len(page.Turns) != 1 || page.Turns[0].State != provider.TurnCompleted || !reflect.DeepEqual(summarize(page.Turns[0]), want) {
		t.Fatalf("history = %#v, want one completed turn with %#v", page.Turns, want)
	}
	if page.Next != "d1" || page.Reset {
		t.Fatalf("page next = %q reset = %v, want next d1", page.Next, page.Reset)
	}
}

// A resumed session continues its frames: its history has the turns from
// before and after, and a marker returns only the newer ones.
func TestResumedSessionKeepsHistoryAcrossReopen(t *testing.T) {
	var resumes atomic.Int32
	agent := &fakeWireAgent{
		capabilities: map[string]any{"sessionCapabilities": map[string]any{"resume": map[string]any{}, "close": map[string]any{}}},
		onResumeSession: func(a *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
			resumes.Add(1)
			a.respond(id, map[string]any{})
		},
		onPrompt: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			a.sendUpdate(params.SessionID, agentMessageUpdate("", "answer to "+params.Prompt[0].Text))
			a.respond(id, map[string]any{"stopReason": "end_turn"})
		},
	}
	h := newWireTestHandle(t, agent)
	opened := openSession(t, h, provider.OpenInput{})
	send(t, h, opened.Session, "d1", "one")
	h.events.WaitFor(t, "the first turn to settle", providertest.Settled("d1"))
	if err := h.Release(testContext(t), opened.Session); err != nil {
		t.Fatalf("Release: %v", err)
	}
	reopened := openSession(t, h, provider.OpenInput{Session: opened.Session})
	if reopened.Session != opened.Session || resumes.Load() != 1 {
		t.Fatalf("reopened %q with %d resumes, want %q resumed once", reopened.Session, resumes.Load(), opened.Session)
	}
	send(t, h, opened.Session, "d2", "two")
	h.events.WaitFor(t, "the second turn to settle", providertest.Settled("d2"))

	page := readHistory(t, h, opened.Session, "")
	if len(page.Turns) != 2 || page.Turns[0].Ref != "d1" || page.Turns[1].Ref != "d2" || page.Turns[1].Entries[1].Text != "answer to two" {
		t.Fatalf("history = %#v, want turns d1 and d2", page.Turns)
	}
	if newer := readHistory(t, h, opened.Session, "d1"); len(newer.Turns) != 1 || newer.Turns[0].Ref != "d2" || newer.Next != "d2" {
		t.Fatalf("history after d1 = %#v, want only d2", newer)
	}
	if unknown := readHistory(t, h, opened.Session, "gone"); !unknown.Reset || len(unknown.Turns) != 2 {
		t.Fatalf("history after an unknown marker = %#v, want a reset with every turn", unknown)
	}
}

// A session maiD never ran is loaded once for its history, which becomes its
// first frames; opening it later drops the agent's second replay, so nothing
// shows twice.
func TestUnseenSessionLoadsItsHistoryOnce(t *testing.T) {
	var loads, closes atomic.Int32
	agent := &fakeWireAgent{
		capabilities: map[string]any{"loadSession": true, "sessionCapabilities": map[string]any{"close": map[string]any{}}},
		onLoadSession: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			loads.Add(1)
			a.sendUpdate(params.SessionID, map[string]any{"sessionUpdate": "user_message_chunk", "content": map[string]any{"type": "text", "text": "old prompt"}})
			a.sendUpdate(params.SessionID, thought("old thought"))
			a.sendUpdate(params.SessionID, agentMessageUpdate("", "old answer"))
			a.respond(id, map[string]any{})
		},
		onCloseSession: func(a *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
			closes.Add(1)
			a.respond(id, map[string]any{})
		},
		onPrompt: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			a.sendUpdate(params.SessionID, agentMessageUpdate("", "new answer"))
			a.respond(id, map[string]any{"stopReason": "end_turn"})
		},
	}
	h := newWireTestHandle(t, agent)
	page := readHistory(t, h, "ext", "")
	want := []entrySummary{
		{Ref: "found-1/user", Kind: "user_message", Status: "completed", Text: "old prompt"},
		{Ref: "found-1/m1", Kind: "reasoning", Status: "completed", Text: "old thought\n\n"},
		{Ref: "found-1/m2", Kind: "assistant_message", Status: "completed", Text: "old answer"},
	}
	if len(page.Turns) != 1 || page.Turns[0].State != provider.TurnCompleted || !reflect.DeepEqual(summarize(page.Turns[0]), want) {
		t.Fatalf("history = %#v, want the replayed turn %#v", page.Turns, want)
	}
	if loads.Load() != 1 || closes.Load() != 1 {
		t.Fatalf("loads = %d closes = %d, want the session loaded and closed once", loads.Load(), closes.Load())
	}
	readHistory(t, h, "ext", "")
	if loads.Load() != 1 {
		t.Fatalf("loads = %d after a second history read, want 1", loads.Load())
	}

	openSession(t, h, provider.OpenInput{Session: "ext"})
	send(t, h, "ext", "d1", "next")
	h.events.WaitFor(t, "the new turn to settle", providertest.Settled("d1"))
	page = readHistory(t, h, "ext", "")
	if len(page.Turns) != 2 || page.Turns[0].Ref != "found-1" || page.Turns[1].Ref != "d1" || len(page.Turns[0].Entries) != 3 {
		t.Fatalf("history = %#v, want the replayed turn once, then d1", page.Turns)
	}
}

// After an interrupt only tool updates still count, and the turn ends
// interrupted.
func TestInterruptEndsTurnAndDropsLaterText(t *testing.T) {
	cancelled := make(chan struct{})
	agent := &fakeWireAgent{
		onPrompt: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			a.sendUpdate(params.SessionID, agentMessageUpdate("", "working"))
			a.sendUpdate(params.SessionID, toolUpdate("tool_call", "in_progress", map[string]any{"title": "edit", "kind": "edit"}))
			<-cancelled
			a.sendUpdate(params.SessionID, agentMessageUpdate("", "late text"))
			a.sendUpdate(params.SessionID, toolUpdate("tool_call_update", "completed", nil))
			a.respond(id, map[string]any{"stopReason": "cancelled"})
		},
		onCancel: func(*fakeWireAgent, wireSessionParams) { close(cancelled) },
	}
	h := newWireTestHandle(t, agent)
	opened := openSession(t, h, provider.OpenInput{})
	send(t, h, opened.Session, "d1", "go")
	h.events.WaitFor(t, "the tool to start", func(event provider.Event) bool {
		upserted, ok := event.Body.(provider.EntryUpserted)
		return ok && upserted.Entry.Ref == "d1/tool/t1"
	})
	if err := h.Interrupt(testContext(t), opened.Session, "d1"); err != nil {
		t.Fatalf("Interrupt: %v", err)
	}
	settled := h.events.WaitFor(t, "the turn to settle", providertest.Settled("d1")).Body.(provider.TurnSettled)
	if settled.State != provider.TurnInterrupted {
		t.Fatalf("turn state = %q, want interrupted", settled.State)
	}
	turn := readHistory(t, h, opened.Session, "").Turns[0]
	for _, entry := range turn.Entries {
		if entry.Text == "late text" || entry.Kind == provider.ItemKindAssistantMessage && entry.Text != "working" {
			t.Fatalf("entry %#v kept text sent after the cancel", entry)
		}
	}
	if tool := turn.Entries[len(turn.Entries)-1]; tool.Ref != "d1/tool/t1" || tool.Status != provider.ItemStatusCompleted {
		t.Fatalf("tool = %#v, want its completion after the cancel kept", tool)
	}
}

// Release ends the session's running turn as interrupted, as the stream that
// would have ended it is gone.
func TestReleaseSettlesTheRunningTurn(t *testing.T) {
	agent := &fakeWireAgent{onPrompt: func(*fakeWireAgent, json.RawMessage, wireSessionParams) {}}
	h := newWireTestHandle(t, agent)
	opened := openSession(t, h, provider.OpenInput{})
	send(t, h, opened.Session, "d1", "go")
	if err := h.Release(testContext(t), opened.Session); err != nil {
		t.Fatalf("Release: %v", err)
	}
	settled := h.events.WaitFor(t, "the turn to settle", providertest.Settled("d1")).Body.(provider.TurnSettled)
	if settled.State != provider.TurnInterrupted {
		t.Fatalf("turn state = %q, want interrupted", settled.State)
	}
	if _, err := h.Send(testContext(t), opened.Session, provider.SendInput{Delivery: "d2", Text: "again"}); err == nil {
		t.Fatal("Send to a released session succeeded")
	}
}

// An agent that dies mid-turn fails the turn and reports the session closed.
func TestAgentExitFailsTurnAndClosesSession(t *testing.T) {
	agent := &fakeWireAgent{}
	agent.onPrompt = func(a *fakeWireAgent, _ json.RawMessage, _ wireSessionParams) { a.closeTransport() }
	h := newWireTestHandle(t, agent)
	opened := openSession(t, h, provider.OpenInput{})
	send(t, h, opened.Session, "d1", "go")
	settled := h.events.WaitFor(t, "the turn to settle", providertest.Settled("d1")).Body.(provider.TurnSettled)
	if settled.State != provider.TurnFailed || settled.Error == "" {
		t.Fatalf("settled = %#v, want failed with the reason", settled)
	}
	h.events.WaitFor(t, "the session to close", func(event provider.Event) bool {
		_, ok := event.Body.(provider.SessionClosed)
		return ok && event.Session == opened.Session
	})
}

// A delivery is proved once the agent answered after its prompt; a prompt
// that is the session's last frame may not have reached the agent.
func TestDeliveredFromMirror(t *testing.T) {
	agent := &fakeWireAgent{}
	h := newWireTestHandle(t, agent)
	opened := openSession(t, h, provider.OpenInput{})
	send(t, h, opened.Session, "d1", "go")
	h.events.WaitFor(t, "the turn to settle", providertest.Settled("d1"))
	h.mirror.Append("other", []json.RawMessage{encodeFrame(frame{Prompt: &promptFrame{Turn: "d2", Text: "lost?"}})})
	for _, tc := range []struct {
		session, delivery string
		want              provider.Tri
	}{
		{opened.Session, "d1", provider.TriYes},
		{opened.Session, "never-sent", provider.TriNo},
		{"other", "d2", provider.TriUnknown},
	} {
		got, err := h.Delivered(testContext(t), tc.session, provider.DeliveryProbe{Delivery: tc.delivery})
		if err != nil || got != tc.want {
			t.Errorf("Delivered(%s, %s) = %v, %v; want %v", tc.session, tc.delivery, got, err, tc.want)
		}
	}
}

// A session the agent no longer has is replaced by a new one, which Open
// names.
func TestOpenStartsNewSessionWhenTheAgentLostIt(t *testing.T) {
	agent := &fakeWireAgent{
		capabilities: map[string]any{"sessionCapabilities": map[string]any{"resume": map[string]any{}}},
		onResumeSession: func(a *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
			a.respondError(id, -32002, "Resource not found")
		},
		onNewSession: func(a *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
			a.respond(id, map[string]any{"sessionId": "fresh"})
		},
	}
	h := newWireTestHandle(t, agent)
	if opened := openSession(t, h, provider.OpenInput{Session: "lost"}); opened.Session != "fresh" {
		t.Fatalf("opened %q, want the new session", opened.Session)
	}
}

// A permission request opens on the running turn, about its tool's entry,
// and the user's answer reaches the agent.
func TestPermissionRequestIsAnsweredOnItsTurn(t *testing.T) {
	answers := make(chan wireMsg, 1)
	agent := &fakeWireAgent{responses: answers}
	agent.onPrompt = func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
		a.sendUpdate(params.SessionID, toolUpdate("tool_call", "pending", map[string]any{"title": "rm -rf build", "kind": "execute"}))
		a.write(map[string]any{"jsonrpc": "2.0", "id": "perm-1", "method": "session/request_permission", "params": map[string]any{
			"sessionId": params.SessionID,
			"toolCall":  map[string]any{"toolCallId": "t1", "title": "rm -rf build"},
			"options":   []any{map[string]any{"optionId": "allow", "name": "Allow", "kind": "allow_once"}, map[string]any{"optionId": "deny", "name": "Deny", "kind": "reject_once"}},
		}})
		<-a.answered
		a.respond(id, map[string]any{"stopReason": "end_turn"})
	}
	agent.answered = make(chan struct{})
	h := newWireTestHandle(t, agent)
	opened := openSession(t, h, provider.OpenInput{})
	send(t, h, opened.Session, "d1", "clean up")
	request := h.events.WaitFor(t, "the request", func(event provider.Event) bool {
		_, ok := event.Body.(provider.RequestOpened)
		return ok
	}).Body.(provider.RequestOpened)
	if request.Turn != "d1" || request.Entry != "d1/tool/t1" || len(request.Ask.Actions) != 2 || request.Ask.Actions[0].ID != "allow" || request.Ask.Message != "rm -rf build" {
		t.Fatalf("request = %#v, want it on turn d1 about d1/tool/t1 with the agent's options", request)
	}
	if err := h.Respond(testContext(t), opened.Session, request.Request, provider.RequestAnswer{Action: request.Ask.Actions[0]}); err != nil {
		t.Fatalf("Respond: %v", err)
	}
	answer := waitFor(t, answers, "the agent never got the answer")
	close(agent.answered)
	var result struct {
		Outcome struct {
			Outcome  string `json:"outcome"`
			OptionID string `json:"optionId"`
		} `json:"outcome"`
	}
	if err := json.Unmarshal(answer.Result, &result); err != nil || result.Outcome.Outcome != "selected" || result.Outcome.OptionID != "allow" {
		t.Fatalf("answer = %s, want allow selected", answer.Result)
	}
	resolved := h.events.WaitFor(t, "the request to resolve", func(event provider.Event) bool {
		_, ok := event.Body.(provider.RequestResolved)
		return ok
	}).Body.(provider.RequestResolved)
	if resolved.Request != request.Request || resolved.Action != "allow" {
		t.Fatalf("resolved = %#v, want %q answered allow", resolved, request.Request)
	}
}

// The agent stops waiting for a permission once its tool call ends, so the
// request ends unanswered.
func TestPermissionEndsWithItsToolCall(t *testing.T) {
	answers := make(chan wireMsg, 1)
	agent := &fakeWireAgent{responses: answers}
	agent.onPrompt = func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
		a.sendUpdate(params.SessionID, toolUpdate("tool_call", "pending", map[string]any{"title": "write", "kind": "edit"}))
		a.write(map[string]any{"jsonrpc": "2.0", "id": "perm-1", "method": "session/request_permission", "params": map[string]any{
			"sessionId": params.SessionID, "toolCall": map[string]any{"toolCallId": "t1"},
			"options": []any{map[string]any{"optionId": "allow", "name": "Allow", "kind": "allow_once"}},
		}})
		<-a.answered
		a.respond(id, map[string]any{"stopReason": "end_turn"})
	}
	agent.answered = make(chan struct{})
	h := newWireTestHandle(t, agent)
	opened := openSession(t, h, provider.OpenInput{})
	send(t, h, opened.Session, "d1", "write it")
	h.events.WaitFor(t, "the request", func(event provider.Event) bool {
		_, ok := event.Body.(provider.RequestOpened)
		return ok
	})
	agent.sendUpdate(opened.Session, toolUpdate("tool_call_update", "failed", nil))
	answer := waitFor(t, answers, "the agent never got an answer")
	close(agent.answered)
	if string(answer.Result) == "" || !jsonContains(answer.Result, `"cancelled"`) {
		t.Fatalf("answer = %s, want cancelled", answer.Result)
	}
	resolved := h.events.WaitFor(t, "the request to resolve", func(event provider.Event) bool {
		_, ok := event.Body.(provider.RequestResolved)
		return ok
	}).Body.(provider.RequestResolved)
	if resolved.Action != "" {
		t.Fatalf("resolved = %#v, want it ended unanswered", resolved)
	}
}

// Commands the agent advertises reach the daemon as an event and in the
// state Open returns.
func TestAvailableCommandsAreReported(t *testing.T) {
	agent := &fakeWireAgent{onNewSession: func(a *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
		a.respond(id, map[string]any{"sessionId": "sess"})
		a.sendUpdate("sess", map[string]any{"sessionUpdate": "available_commands_update", "availableCommands": []any{map[string]any{"name": "review", "description": "Review changes", "input": map[string]any{"hint": "what to review"}}}})
	}}
	h := newWireTestHandle(t, agent)
	opened := openSession(t, h, provider.OpenInput{})
	changed := h.events.WaitFor(t, "the commands", func(event provider.Event) bool {
		changed, ok := event.Body.(provider.ConfigChanged)
		return ok && changed.Commands != nil
	}).Body.(provider.ConfigChanged)
	if len(changed.Commands) != 1 || changed.Commands[0].Name != "review" || !changed.Commands[0].HasInput {
		t.Fatalf("commands = %#v, want review with input", changed.Commands)
	}
	if reopened := openSession(t, h, provider.OpenInput{Session: opened.Session}); len(reopened.Commands) != 1 {
		t.Fatalf("opened commands = %#v, want review", reopened.Commands)
	}
}

func jsonContains(raw json.RawMessage, part string) bool {
	return strings.Contains(string(raw), part)
}

// A session's settings go model first, whatever order the client chose
// them in, since a model can change which other options exist; one the
// agent refuses is a warning, and the session still opens.
func TestSettingsApplyModelFirstAndRefusalsWarn(t *testing.T) {
	recorder := &callRecorder{}
	model, reasoning := "model-a", "low"
	agent := &fakeWireAgent{
		onNewSession: func(a *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
			a.respond(id, map[string]any{"sessionId": "sess", "configOptions": wireModelAndReasoningOptions(model, reasoning)})
		},
		onSetConfigOption: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			recorder.recordConfig(params)
			switch params.ConfigID {
			case "z-model":
				model = params.stringValue()
			case "a-reasoning":
				reasoning = params.stringValue()
			default:
				a.respondError(id, -32602, "unknown option")
				return
			}
			a.respond(id, map[string]any{"configOptions": wireModelAndReasoningOptions(model, reasoning)})
		},
	}
	h := newWireTestHandle(t, agent)
	opened := openSession(t, h, provider.OpenInput{Settings: []provider.ConfigOptionSelection{
		{OptionID: "a-reasoning", Value: "high"},
		{OptionID: "gone", Value: "x"},
		{OptionID: "z-model", Value: "model-b"},
	}})
	var order []string
	for _, call := range recorder.configCalls() {
		order = append(order, call.ConfigID+"="+call.stringValue())
	}
	if want := []string{"z-model=model-b", "a-reasoning=high", "gone=x"}; !reflect.DeepEqual(order, want) {
		t.Fatalf("set_config_option calls = %v, want %v", order, want)
	}
	h.events.WaitFor(t, "the refused setting's warning", func(event provider.Event) bool {
		warning, ok := event.Body.(provider.Warning)
		return ok && event.Session == opened.Session && strings.Contains(warning.Message, `"gone"`)
	})
}
