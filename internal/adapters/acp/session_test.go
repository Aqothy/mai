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

// Output the agent sends outside a prompt (a session's first output, or
// claude-agent-acp's follow-up when a background task ends) is a turn of its
// own, settled as it starts since no frame would end it, its requests too.
// Its messages stream as complete, since nothing would complete them.
func TestOutputOutsideAPromptIsASettledTurnOfItsOwn(t *testing.T) {
	answers := make(chan wireMsg, 1)
	agent := &fakeWireAgent{responses: answers, onPrompt: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
		a.sendUpdate(params.SessionID, agentMessageUpdate("", "On it."))
		a.respond(id, map[string]any{"stopReason": "end_turn"})
	}}
	h := newWireTestHandle(t, agent)
	session := openSession(t, h, provider.OpenInput{}).Session
	text := func(want string) func(provider.Event) bool {
		return func(event provider.Event) bool {
			upserted, ok := event.Body.(provider.EntryUpserted)
			return ok && upserted.Entry.Text == want
		}
	}

	agent.sendUpdate(session, agentMessageUpdate("", "Ready."))
	h.events.WaitFor(t, "the first output's turn to settle", providertest.Settled("found-1"))
	h.events.WaitFor(t, "the first output", text("Ready."))
	send(t, h, session, "d1", "Build it")
	h.events.WaitFor(t, "the prompt to settle", providertest.Settled("d1"))
	settledAt := len(h.events.Snapshot())
	agent.sendUpdate(session, toolUpdate("tool_call", "pending", map[string]any{"title": "build", "kind": "execute"}))
	agent.write(map[string]any{"jsonrpc": "2.0", "id": "perm-1", "method": "session/request_permission", "params": map[string]any{
		"sessionId": session,
		"toolCall":  map[string]any{"toolCallId": "t1", "title": "build"},
		"options":   []any{map[string]any{"optionId": "allow", "name": "Allow", "kind": "allow_once"}},
	}})
	request := h.events.WaitFor(t, "the follow-up's request", func(event provider.Event) bool {
		_, ok := event.Body.(provider.RequestOpened)
		return ok
	}).Body.(provider.RequestOpened)
	if request.Turn != "found-2" || request.Entry != "found-2/tool/t1" {
		t.Fatalf("request = %#v, want it on turn found-2 about found-2/tool/t1", request)
	}
	if err := h.Respond(testContext(t), session, request.Request, provider.RequestAnswer{Action: request.Ask.Actions[0]}); err != nil {
		t.Fatalf("Respond: %v", err)
	}
	waitFor(t, answers, "the agent never got the answer")
	agent.sendUpdate(session, toolUpdate("tool_call_update", "completed", nil))
	agent.sendUpdate(session, agentMessageUpdate("", "The build"))
	agent.sendUpdate(session, agentMessageUpdate("", " finished."))
	h.events.WaitFor(t, "the follow-up's text", func(event provider.Event) bool {
		appended, ok := event.Body.(provider.TextAppended)
		return ok && appended.Text == " finished."
	})
	for _, event := range h.events.Snapshot()[settledAt:] {
		if upserted, ok := event.Body.(provider.EntryUpserted); ok && upserted.Entry.Kind == provider.ItemKindAssistantMessage && upserted.Entry.Status != provider.ItemStatusCompleted {
			t.Fatalf("follow-up message %#v, want it complete as it streams", upserted.Entry)
		}
	}
	send(t, h, session, "d2", "Thanks")
	h.events.WaitFor(t, "the next prompt to settle", providertest.Settled("d2"))

	live := h.events.LiveTurns(session)
	page := readHistory(t, h, session, "")
	if !reflect.DeepEqual(page.Turns, live) {
		t.Fatalf("history turns = %#v\nlive turns = %#v", page.Turns, live)
	}
	want := [][]entrySummary{
		{{Ref: "found-1/m1", Kind: "assistant_message", Status: "completed", Text: "Ready."}},
		{
			{Ref: "d1/user", Kind: "user_message", Status: "completed", Text: "Build it"},
			{Ref: "d1/m1", Kind: "assistant_message", Status: "completed", Text: "On it."},
		},
		{
			{Ref: "found-2/tool/t1", Kind: "command_execution", Status: "completed"},
			{Ref: "found-2/m1", Kind: "assistant_message", Status: "completed", Text: "The build finished."},
		},
		{
			{Ref: "d2/user", Kind: "user_message", Status: "completed", Text: "Thanks"},
			{Ref: "d2/m1", Kind: "assistant_message", Status: "completed", Text: "On it."},
		},
	}
	var got [][]entrySummary
	for _, turn := range page.Turns {
		if turn.State != provider.TurnCompleted {
			t.Fatalf("turn %s is %s, want completed", turn.Ref, turn.State)
		}
		got = append(got, summarize(turn))
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("turns = %#v\nwant %#v", got, want)
	}
}

// An Interrupt can record its cancel after the prompt's answer; the cancel
// is moot then, and the agent's later output still counts.
func TestCancelAfterTheAnswerDropsNoLaterOutput(t *testing.T) {
	update, _ := json.Marshal(agentMessageUpdate("", "The build finished."))
	_, turns := history([]json.RawMessage{
		encodeFrame(frame{Prompt: &promptFrame{Turn: "d1", Text: "Build it"}}),
		encodeFrame(frame{Stop: &stopFrame{Turn: "d1", State: provider.TurnCompleted}}),
		encodeFrame(frame{Cancel: "d1"}),
		encodeFrame(frame{Update: update}),
	})
	if len(turns) != 2 || turns[0].State != provider.TurnCompleted {
		t.Fatalf("turns = %#v, want d1 completed and the agent's own turn", turns)
	}
	if entries := turns[1].Entries; len(entries) != 1 || entries[0].Text != "The build finished." {
		t.Fatalf("entries = %#v, want the output after the cancel", entries)
	}
}

// A tool call id is unique in an ACP session, so a tool call that ends
// after the next prompt began ends its own card, not a new one, and leaves
// that prompt's message whole.
func TestToolCallEndingAfterTheNextPromptEndsItsCard(t *testing.T) {
	update := func(u map[string]any) frame {
		raw, _ := json.Marshal(u)
		return frame{Update: raw}
	}
	var frames []json.RawMessage
	for _, f := range []frame{
		{Prompt: &promptFrame{Turn: "d1", Text: "Build it"}},
		update(toolUpdate("tool_call", "in_progress", map[string]any{"title": "build", "kind": "execute"})),
		{Stop: &stopFrame{Turn: "d1", State: provider.TurnCompleted}},
		{Prompt: &promptFrame{Turn: "d2", Text: "Thanks"}},
		update(agentMessageUpdate("", "You're")),
		update(toolUpdate("tool_call_update", "completed", nil)),
		update(agentMessageUpdate("", " welcome.")),
		{Stop: &stopFrame{Turn: "d2", State: provider.TurnCompleted}},
	} {
		frames = append(frames, encodeFrame(f))
	}
	_, turns := history(frames)
	var got [][]entrySummary
	for _, turn := range turns {
		got = append(got, summarize(turn))
	}
	want := [][]entrySummary{
		{{Ref: "d1/user", Kind: "user_message", Status: "completed", Text: "Build it"}, {Ref: "d1/tool/t1", Kind: "command_execution", Status: "completed"}},
		{{Ref: "d2/user", Kind: "user_message", Status: "completed", Text: "Thanks"}, {Ref: "d2/m1", Kind: "assistant_message", Status: "completed", Text: "You're welcome."}},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("turns = %#v\nwant %#v", got, want)
	}
}

// A tool call still running after its prompt's answer keeps its turn: a
// request about it opens there, and outlives the next prompt, whose end only
// ends its own requests.
func TestRequestAboutAnEarlierTurnsToolOutlivesTheNextPrompt(t *testing.T) {
	answers := make(chan wireMsg, 1)
	agent := &fakeWireAgent{responses: answers, onPrompt: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
		if params.Prompt[0].Text == "Build it" {
			a.sendUpdate(params.SessionID, toolUpdate("tool_call", "in_progress", map[string]any{"title": "build", "kind": "execute"}))
		}
		a.respond(id, map[string]any{"stopReason": "end_turn"})
	}}
	h := newWireTestHandle(t, agent)
	session := openSession(t, h, provider.OpenInput{}).Session
	send(t, h, session, "d1", "Build it")
	h.events.WaitFor(t, "the prompt to settle", providertest.Settled("d1"))
	agent.write(map[string]any{"jsonrpc": "2.0", "id": "perm-1", "method": "session/request_permission", "params": map[string]any{
		"sessionId": session,
		"toolCall":  map[string]any{"toolCallId": "t1", "title": "build"},
		"options":   []any{map[string]any{"optionId": "allow", "name": "Allow", "kind": "allow_once"}},
	}})
	request := h.events.WaitFor(t, "the request", func(event provider.Event) bool {
		_, ok := event.Body.(provider.RequestOpened)
		return ok
	}).Body.(provider.RequestOpened)
	if request.Turn != "d1" || request.Entry != "d1/tool/t1" {
		t.Fatalf("request = %#v, want it on turn d1 about d1/tool/t1", request)
	}
	send(t, h, session, "d2", "Thanks")
	h.events.WaitFor(t, "the next prompt to settle", providertest.Settled("d2"))
	if err := h.Respond(testContext(t), session, request.Request, provider.RequestAnswer{Action: request.Ask.Actions[0]}); err != nil {
		t.Fatalf("Respond after the next prompt: %v", err)
	}
	var result struct {
		Outcome struct {
			Outcome string `json:"outcome"`
		} `json:"outcome"`
	}
	if answer := waitFor(t, answers, "the agent never got the answer"); json.Unmarshal(answer.Result, &result) != nil || result.Outcome.Outcome != "selected" {
		t.Fatalf("answer = %s, want the person's choice", answer.Result)
	}
}

// A request about an earlier turn's tool ends with the session.
func TestReleaseEndsARequestAboutAnEarlierTurnsTool(t *testing.T) {
	answers := make(chan wireMsg, 1)
	agent := &fakeWireAgent{responses: answers, onPrompt: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
		a.sendUpdate(params.SessionID, toolUpdate("tool_call", "in_progress", map[string]any{"title": "build", "kind": "execute"}))
		a.respond(id, map[string]any{"stopReason": "end_turn"})
	}}
	h := newWireTestHandle(t, agent)
	session := openSession(t, h, provider.OpenInput{}).Session
	send(t, h, session, "d1", "Build it")
	h.events.WaitFor(t, "the prompt to settle", providertest.Settled("d1"))
	agent.write(map[string]any{"jsonrpc": "2.0", "id": "perm-1", "method": "session/request_permission", "params": map[string]any{
		"sessionId": session,
		"toolCall":  map[string]any{"toolCallId": "t1", "title": "build"},
		"options":   []any{map[string]any{"optionId": "allow", "name": "Allow", "kind": "allow_once"}},
	}})
	h.events.WaitFor(t, "the request", func(event provider.Event) bool {
		_, ok := event.Body.(provider.RequestOpened)
		return ok
	})
	if err := h.Release(testContext(t), session); err != nil {
		t.Fatalf("Release: %v", err)
	}
	var result struct {
		Outcome struct {
			Outcome string `json:"outcome"`
		} `json:"outcome"`
	}
	if answer := waitFor(t, answers, "the agent never got an answer"); json.Unmarshal(answer.Result, &result) != nil || result.Outcome.Outcome != "cancelled" {
		t.Fatalf("answer = %s, want cancelled", answer.Result)
	}
}

// A replay's end ends its last turn, so the agent's output after a load is
// a turn of its own.
func TestOutputAfterAReplayIsATurnOfItsOwn(t *testing.T) {
	update := func(u map[string]any) frame {
		raw, _ := json.Marshal(u)
		return frame{Update: raw}
	}
	var frames []json.RawMessage
	for _, f := range []frame{
		update(map[string]any{"sessionUpdate": "user_message_chunk", "content": map[string]any{"type": "text", "text": "Build it"}}),
		update(agentMessageUpdate("", "On it.")),
		{Stop: &stopFrame{Turn: "found-1", State: provider.TurnCompleted}},
		update(agentMessageUpdate("", "The build finished.")),
	} {
		frames = append(frames, encodeFrame(f))
	}
	_, turns := history(frames)
	var got [][]entrySummary
	for _, turn := range turns {
		got = append(got, summarize(turn))
	}
	want := [][]entrySummary{
		{{Ref: "found-1/user", Kind: "user_message", Status: "completed", Text: "Build it"}, {Ref: "found-1/m1", Kind: "assistant_message", Status: "completed", Text: "On it."}},
		{{Ref: "found-2/m1", Kind: "assistant_message", Status: "completed", Text: "The build finished."}},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("turns = %#v\nwant %#v", got, want)
	}
}

// What the mirror leaves running (a prompt nothing answered, a tool call a
// follow-up began) ran in a process that is gone: resuming ends it
// interrupted, the agent's output after is a turn of its own, and the prompt
// isn't taken as delivered.
func TestResumeEndsAPromptLeftUnanswered(t *testing.T) {
	agent := &fakeWireAgent{
		capabilities: map[string]any{"sessionCapabilities": map[string]any{"resume": map[string]any{}}},
		onResumeSession: func(a *fakeWireAgent, id json.RawMessage, _ wireSessionParams) {
			a.respond(id, map[string]any{})
		},
	}
	h := newWireTestHandle(t, agent)
	tool, _ := json.Marshal(toolUpdate("tool_call", "in_progress", map[string]any{"title": "build", "kind": "execute"}))
	background, _ := json.Marshal(toolUpdate("tool_call", "in_progress", map[string]any{"toolCallId": "t0", "title": "watch", "kind": "execute"}))
	h.mirror.Append("cut", []json.RawMessage{
		encodeFrame(frame{Update: background}),
		encodeFrame(frame{Prompt: &promptFrame{Turn: "d1", Text: "Build it"}}),
		encodeFrame(frame{Update: tool}),
	})
	h.mirror.Append("unsent", []json.RawMessage{encodeFrame(frame{Prompt: &promptFrame{Turn: "d2", Text: "Lost?"}})})
	openSession(t, h, provider.OpenInput{Session: "cut"})
	openSession(t, h, provider.OpenInput{Session: "unsent"})
	// The end resuming gives a prompt is maiD's, no sign the agent had it.
	if delivered, err := h.Delivered(testContext(t), "unsent", provider.DeliveryProbe{Delivery: "d2"}); err != nil || delivered != provider.TriUnknown {
		t.Fatalf("Delivered = %v, %v; want unknown", delivered, err)
	}
	agent.sendUpdate("cut", agentMessageUpdate("", "Back."))
	h.events.WaitFor(t, "the output after the resume", func(event provider.Event) bool {
		upserted, ok := event.Body.(provider.EntryUpserted)
		return ok && upserted.Entry.Ref == "found-2/m1"
	})
	turns := readHistory(t, h, "cut", "").Turns
	if len(turns) != 3 || turns[0].Entries[0].Status != provider.ItemStatusInterrupted || turns[1].State != provider.TurnInterrupted || turns[1].Entries[1].Status != provider.ItemStatusInterrupted || turns[2].Ref != "found-2" {
		t.Fatalf("turns = %#v, want found-1's tool, d1 and d1's tool interrupted, then the agent's own turn", turns)
	}
}

// Only a session/load replay's thoughts lack the live stream's separators:
// a live thought outside a prompt keeps its text as sent.
func TestOnlyReplayedThoughtsGetSeparators(t *testing.T) {
	update := func(u map[string]any, replay bool) frame {
		raw, _ := json.Marshal(u)
		return frame{Update: raw, Replay: replay}
	}
	userChunk := map[string]any{"sessionUpdate": "user_message_chunk", "content": map[string]any{"type": "text", "text": "Build it"}}
	var frames []json.RawMessage
	for _, f := range []frame{
		update(userChunk, true),
		update(thought("replayed"), true),
		{Stop: &stopFrame{Turn: "found-1", State: provider.TurnCompleted}},
		update(userChunk, false),
		update(thought("live"), false),
	} {
		frames = append(frames, encodeFrame(f))
	}
	_, turns := history(frames)
	var got []string
	for _, turn := range turns {
		for _, entry := range turn.Entries {
			if entry.Kind == provider.ItemKindReasoning {
				got = append(got, entry.Text)
			}
		}
	}
	if !reflect.DeepEqual(got, []string{"replayed\n\n", "live"}) {
		t.Fatalf("thoughts = %q, want the replayed one separated and the live one as sent", got)
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
// first frames, what it left running ended; opening it later drops the
// agent's second replay, so nothing shows twice.
func TestUnseenSessionLoadsItsHistoryOnce(t *testing.T) {
	var loads, closes atomic.Int32
	agent := &fakeWireAgent{
		capabilities: map[string]any{"loadSession": true, "sessionCapabilities": map[string]any{"close": map[string]any{}}},
		onLoadSession: func(a *fakeWireAgent, id json.RawMessage, params wireSessionParams) {
			loads.Add(1)
			a.sendUpdate(params.SessionID, map[string]any{"sessionUpdate": "user_message_chunk", "content": map[string]any{"type": "text", "text": "old prompt"}})
			a.sendUpdate(params.SessionID, thought("old thought"))
			a.sendUpdate(params.SessionID, agentMessageUpdate("", "old answer"))
			a.sendUpdate(params.SessionID, toolUpdate("tool_call", "in_progress", map[string]any{"title": "build", "kind": "execute"}))
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
		{Ref: "found-1/tool/t1", Kind: "command_execution", Status: "interrupted"},
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
	// The agent's output after the replay continues the mirror's turns.
	agent.sendUpdate("ext", agentMessageUpdate("", "unprompted"))
	h.events.WaitFor(t, "the output after the load", func(event provider.Event) bool {
		upserted, ok := event.Body.(provider.EntryUpserted)
		return ok && upserted.Entry.Ref == "found-2/m1"
	})
	send(t, h, "ext", "d1", "next")
	h.events.WaitFor(t, "the new turn to settle", providertest.Settled("d1"))
	page = readHistory(t, h, "ext", "")
	if len(page.Turns) != 3 || page.Turns[0].Ref != "found-1" || page.Turns[1].Ref != "found-2" || page.Turns[2].Ref != "d1" || len(page.Turns[0].Entries) != 4 {
		t.Fatalf("history = %#v, want the replayed turn once, the agent's own, then d1", page.Turns)
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
	// Output after the agent answered the cancel is the agent's own again.
	agent.sendUpdate(opened.Session, agentMessageUpdate("", "Stopped."))
	h.events.WaitFor(t, "the output after the answer", func(event provider.Event) bool {
		upserted, ok := event.Body.(provider.EntryUpserted)
		return ok && upserted.Entry.Text == "Stopped."
	})
	var texts [][]string
	for _, turn := range readHistory(t, h, opened.Session, "").Turns {
		var messages []string
		for _, entry := range turn.Entries {
			if entry.Kind == provider.ItemKindAssistantMessage {
				messages = append(messages, entry.Text)
			}
		}
		texts = append(texts, messages)
	}
	if !reflect.DeepEqual(texts, [][]string{{"working"}, {"Stopped."}}) {
		t.Fatalf("messages = %q, want the text before the cancel, and after its answer in a turn of its own, not between", texts)
	}
	turn := readHistory(t, h, opened.Session, "").Turns[0]
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
	// The agent died before it read the prompt, as far as maiD knows.
	if delivered, err := h.Delivered(testContext(t), opened.Session, provider.DeliveryProbe{Delivery: "d1"}); err != nil || delivered != provider.TriUnknown {
		t.Fatalf("Delivered = %v, %v; want unknown", delivered, err)
	}
}

// A delivery is proved once the agent answered its prompt; until then it may
// not have reached the agent.
func TestDeliveredFromMirror(t *testing.T) {
	agent := &fakeWireAgent{}
	h := newWireTestHandle(t, agent)
	opened := openSession(t, h, provider.OpenInput{})
	send(t, h, opened.Session, "d1", "go")
	h.events.WaitFor(t, "the turn to settle", providertest.Settled("d1"))
	h.mirror.Append("other", []json.RawMessage{encodeFrame(frame{Prompt: &promptFrame{Turn: "d2", Text: "lost?"}})})
	// The agent's own output can race a prompt it hasn't read.
	output, _ := json.Marshal(agentMessageUpdate("", "The build finished."))
	h.mirror.Append("raced", []json.RawMessage{encodeFrame(frame{Prompt: &promptFrame{Turn: "d3", Text: "read?"}}), encodeFrame(frame{Update: output})})
	// Only the prompt's own answer proves it.
	h.mirror.Append("another", []json.RawMessage{encodeFrame(frame{Prompt: &promptFrame{Turn: "d4", Text: "read?"}}), encodeFrame(frame{Stop: &stopFrame{Turn: "found-1", State: provider.TurnCompleted}})})
	for _, tc := range []struct {
		session, delivery string
		want              provider.Tri
	}{
		{opened.Session, "d1", provider.TriYes},
		{opened.Session, "never-sent", provider.TriNo},
		{"other", "d2", provider.TriUnknown},
		{"raced", "d3", provider.TriUnknown},
		{"another", "d4", provider.TriUnknown},
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
