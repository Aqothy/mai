package daemon

// Thread RPC tests drive chats the way the app does, over real WebSocket
// clients, against the fake ACP agent.

import (
	"context"
	"encoding/json"
	"fmt"
	"maps"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
	"github.com/coder/websocket"
)

// entryTexts are a turn's entries as kind: text.
func entryTexts(turn orchestration.TurnView) []string {
	var out []string
	for _, entry := range turn.Entries {
		out = append(out, string(entry.Kind)+": "+strings.TrimSpace(entry.Text))
	}
	return out
}

// A chat streams to every client watching it, shows in their thread lists,
// and reopens from what the daemon kept after a restart.
func TestChatStreamsToEveryClientAndReopensAfterRestart(t *testing.T) {
	dir := t.TempDir()
	s := newTestServerAt(t, dir)
	startFakeACPAgent(t, s, "agent")
	url := newWSTestServer(t, s)
	first, second := dialRecordingClient(t, url), dialRecordingClient(t, url)
	var list orchestration.ThreadListItem
	second.call(t, wire.MethodThreadSubscribeList, wire.EmptyParams{}, &list)

	created := first.createThread(t, "agent", t.TempDir())
	first.subscribe(t, created.Thread)
	second.subscribe(t, created.Thread)
	delivery := first.deliver(t, created.Thread, "hello").Delivery
	want := []string{"user_message: hello", "assistant_message: hi"}
	for _, client := range []*recordingClient{first, second} {
		if turn := client.waitSettled(t, created.Thread, delivery); turn.State != provider.TurnCompleted || !slices.Equal(entryTexts(turn), want) {
			t.Fatalf("settled turn = %s %q, want completed %q", turn.State, entryTexts(turn), want)
		}
	}
	second.waitFor(t, "the chat in the thread list", func() bool {
		return slices.ContainsFunc(second.listItems, func(item orchestration.ThreadListItem) bool {
			return item.Kind == orchestration.ListUpsert && item.Thread.ID == created.Thread && item.Thread.Title == "Untitled thread"
		})
	})

	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	restarted := newRecordingClient(t, newTestServerAt(t, dir))
	snapshot := restarted.subscribe(t, created.Thread)
	if len(snapshot.Turns) != 1 || !slices.Equal(entryTexts(snapshot.Turns[0]), want) || snapshot.Turns[0].State != provider.TurnCompleted {
		t.Fatalf("turns after restart = %#v, want the chat's turn", snapshot.Turns)
	}
}

// A permission request reaches every client; another one answers it with an
// action the request offered, and the agent gets that action.
func TestAnotherClientAnswersAPermissionRequest(t *testing.T) {
	s := newTestServer(t)
	startFakeACPAgent(t, s, "agent")
	url := newWSTestServer(t, s)
	asker, answerer := dialRecordingClient(t, url), dialRecordingClient(t, url)
	created := asker.createThread(t, "agent", t.TempDir())
	asker.subscribe(t, created.Thread)
	answerer.subscribe(t, created.Thread)
	delivery := asker.deliver(t, created.Thread, "permission").Delivery

	opened := answerer.waitEvent(t, "the permission request", func(event orchestration.ThreadEvent) bool {
		return event.Kind == orchestration.EventRequest
	}).Request
	allow := slices.IndexFunc(opened.Ask.Actions, func(action provider.RequestAction) bool { return action.Label == "Allow" })
	if allow < 0 {
		t.Fatalf("request actions = %#v, want Allow", opened.Ask.Actions)
	}
	if _, err := answerer.commandErr(wire.CommandParams{Respond: &orchestration.Respond{Thread: created.Thread, Request: opened.ID, Action: "not-offered"}}); err == nil {
		t.Fatal("an answer with an action the request didn't offer was taken")
	} else if code, reason := commandCode(err); code != invalidParamsCode || reason != orchestration.CodeInvalid {
		t.Fatalf("refusal = %d %q, want %d %q", code, reason, invalidParamsCode, orchestration.CodeInvalid)
	}
	answerer.command(t, wire.CommandParams{Respond: &orchestration.Respond{Thread: created.Thread, Request: opened.ID, Action: opened.Ask.Actions[allow].ID}})

	turn := asker.waitSettled(t, created.Thread, delivery)
	if texts := entryTexts(turn); !slices.Contains(texts, "assistant_message: perm:"+opened.Ask.Actions[allow].ID) {
		t.Fatalf("turn = %q, want the agent to get the chosen action", texts)
	}
	asker.waitEvent(t, "the request resolved", func(event orchestration.ThreadEvent) bool {
		return event.Kind == orchestration.EventResolved && event.Resolved.Request == opened.ID
	})
	_, err := asker.commandErr(wire.CommandParams{Respond: &orchestration.Respond{Thread: created.Thread, Request: opened.ID, Action: opened.Ask.Actions[allow].ID}})
	if code, reason := commandCode(err); code != commandRefusedCode || reason != orchestration.CodeNotFound {
		t.Fatalf("answering again = %v (%d %q), want refused %q", err, code, reason, orchestration.CodeNotFound)
	}
}

// A command is exactly one body; one the engine refuses says why.
func TestCommandsAreValidatedAtTheBoundary(t *testing.T) {
	s := newTestServer(t)
	client := newRecordingClient(t, s)
	title := "x"
	for name, params := range map[string]wire.CommandParams{
		"none": {},
		"two":  {UpdateThread: &orchestration.UpdateThread{Thread: "a", Title: &title}, Interrupt: &orchestration.Interrupt{Thread: "a"}},
	} {
		if code, _ := commandCode(func() error { _, err := client.commandErr(params); return err }()); code != invalidParamsCode {
			t.Fatalf("%s: code = %d, want invalid params", name, code)
		}
	}
	_, err := client.commandErr(wire.CommandParams{Deliver: &orchestration.Deliver{Thread: "missing", Body: orchestration.MessageBody{Text: "hi"}}})
	if code, reason := commandCode(err); code != commandRefusedCode || reason != orchestration.CodeNotFound {
		t.Fatalf("deliver to a missing chat = %v (%d %q), want refused %q", err, code, reason, orchestration.CodeNotFound)
	}
	_, err = client.commandErr(wire.CommandParams{CreateThread: &orchestration.CreateThread{Workspace: provider.Workspace{Cwd: t.TempDir()}, Participant: orchestration.NewParticipant{Instance: "unknown"}}})
	if code, reason := commandCode(err); code != commandRefusedCode || reason != orchestration.CodeAgentUnavailable {
		t.Fatalf("chat with an unknown agent = %v (%d %q), want refused %q", err, code, reason, orchestration.CodeAgentUnavailable)
	}
}

// A client gets a thread's events only while subscribed; a subscribe that
// failed leaves nothing behind.
func TestUnsubscribedThreadSendsNothing(t *testing.T) {
	s := newTestServer(t)
	startFakeACPAgent(t, s, "agent")
	client := newRecordingClient(t, s)
	if err := client.callErr(wire.MethodThreadSubscribe, wire.ThreadParams{Thread: "missing"}, nil); err == nil {
		t.Fatal("subscribing to a missing chat succeeded")
	}
	watched := client.createThread(t, "agent", t.TempDir()).Thread
	fence := client.createThread(t, "agent", t.TempDir()).Thread
	client.subscribe(t, watched)
	client.subscribe(t, fence)
	rename := func(thread orchestration.ThreadID, title string) {
		t.Helper()
		client.command(t, wire.CommandParams{UpdateThread: &orchestration.UpdateThread{Thread: thread, Title: &title}})
	}
	renamed := func(thread orchestration.ThreadID, title string) func(orchestration.ThreadEvent) bool {
		return func(event orchestration.ThreadEvent) bool {
			return event.Thread == thread && event.Kind == orchestration.EventThread && event.Summary.Title == title
		}
	}
	rename(watched, "while subscribed")
	client.waitEvent(t, "the rename while subscribed", renamed(watched, "while subscribed"))

	client.call(t, wire.MethodThreadUnsubscribe, wire.ThreadParams{Thread: watched}, nil)
	rename(watched, "after unsubscribe")
	// Events go out in order, so the fence's arrives after any of watched's.
	rename(fence, "fence")
	client.waitEvent(t, "the fence", renamed(fence, "fence"))
	client.mu.Lock()
	defer client.mu.Unlock()
	if slices.ContainsFunc(client.threadEvents, renamed(watched, "after unsubscribe")) {
		t.Fatal("an unsubscribed chat's event reached the client")
	}
}

// A client that subscribes mid-turn folds the snapshot and the events after
// it to exactly what the turn ends as: none lost, none twice.
func TestSubscribingMidTurnMissesNothing(t *testing.T) {
	s := newTestServer(t)
	startFakeACPAgent(t, s, "agent")
	url := newWSTestServer(t, s)
	driver, late := dialRecordingClient(t, url), dialRecordingClient(t, url)
	thread := driver.createThread(t, "agent", t.TempDir()).Thread
	driver.subscribe(t, thread)
	delivery := driver.deliver(t, thread, "stream 300 0 2").Delivery
	driver.waitEvent(t, "the stream to start", func(event orchestration.ThreadEvent) bool {
		return event.Kind == orchestration.EventText || event.Kind == orchestration.EventEntry && event.Entry.Kind == provider.ItemKindAssistantMessage
	})

	snapshot := late.subscribe(t, thread)
	final := driver.waitSettled(t, thread, delivery)
	late.waitEvent(t, "the turn to settle", func(event orchestration.ThreadEvent) bool {
		return event.Kind == orchestration.EventTurn && event.Turn.ID == final.ID && event.Turn.State.Settled()
	})
	texts := map[string]string{}
	for _, turn := range snapshot.Turns {
		for _, entry := range turn.Entries {
			texts[entry.Ref] = entry.Text
		}
	}
	late.mu.Lock()
	for _, event := range late.threadEvents {
		if event.Seq <= snapshot.Seq {
			t.Errorf("event %d (%s) is not after the snapshot's %d", event.Seq, event.Kind, snapshot.Seq)
		}
		switch event.Kind {
		case orchestration.EventEntry:
			texts[event.Entry.Ref] = event.Entry.Text
		case orchestration.EventText:
			texts[event.Text.Entry] += event.Text.Text
		}
	}
	late.mu.Unlock()
	for _, entry := range final.Entries {
		if texts[entry.Ref] != entry.Text {
			t.Fatalf("folded %s = %q, want %q", entry.Ref, texts[entry.Ref], entry.Text)
		}
	}
	if want := 300; strings.Count(final.Entries[len(final.Entries)-1].Text, "w") != want {
		t.Fatalf("final answer = %q, want %d chunks", final.Entries[len(final.Entries)-1].Text, want)
	}
}

// A client folding the queue's events, by position, has the queue's order
// after a message moves, as the snapshot does.
func TestQueueOrderReachesClients(t *testing.T) {
	s := newTestServer(t)
	startFakeACPAgent(t, s, "agent")
	client := newRecordingClient(t, s)
	thread := client.createThread(t, "agent", t.TempDir()).Thread
	client.subscribe(t, thread)
	gate := t.TempDir()
	client.deliver(t, thread, "block "+gate)
	waitForFile(t, gate+"/ready")
	first := client.deliver(t, thread, "first").Delivery
	second := client.deliver(t, thread, "second").Delivery
	client.command(t, wire.CommandParams{MoveDelivery: &orchestration.MoveDelivery{Delivery: second, Before: first}})

	order := func(queue []orchestration.DeliveryView) []orchestration.DeliveryID {
		slices.SortStableFunc(queue, func(a, b orchestration.DeliveryView) int {
			switch {
			case a.Position < b.Position:
				return -1
			case a.Position > b.Position:
				return 1
			}
			return a.CreatedAt.Compare(b.CreatedAt)
		})
		var ids []orchestration.DeliveryID
		for _, delivery := range queue {
			ids = append(ids, delivery.ID)
		}
		return ids
	}
	want := []orchestration.DeliveryID{second, first}
	var folded []orchestration.DeliveryID
	client.waitFor(t, "the move", func() bool {
		latest := map[orchestration.DeliveryID]orchestration.DeliveryView{}
		for _, event := range client.threadEvents {
			if event.Kind == orchestration.EventDelivery {
				latest[event.Delivery.ID] = *event.Delivery
			}
		}
		queued := slices.DeleteFunc(slices.Collect(maps.Values(latest)), func(delivery orchestration.DeliveryView) bool {
			return delivery.State != orchestration.DeliveryQueued
		})
		folded = order(queued)
		return slices.Equal(folded, want)
	})
	if snapshot := order(client.subscribe(t, thread).Queue); !slices.Equal(snapshot, want) {
		t.Fatalf("snapshot queue = %v, want %v", snapshot, want)
	}
}

// Images go up on their own, then a message names them by ID: snapshots and
// events carry only their metadata, so a chat full of images can't outgrow
// a client's frame limit, and each image is fetched by ID.
func TestAttachmentDataTravelsOutsideTheThread(t *testing.T) {
	s := newTestServer(t)
	startFakeACPAgent(t, s, "agent")
	client := newRecordingClient(t, s)
	thread := client.createThread(t, "agent", t.TempDir()).Thread
	client.subscribe(t, thread)

	image := strings.Repeat("A", 1<<20)
	var attachments []provider.Attachment
	for range 3 {
		var uploaded wire.AttachmentUploadResult
		client.call(t, wire.MethodAttachmentUpload, wire.AttachmentUploadParams{Data: image}, &uploaded)
		attachments = append(attachments, provider.Attachment{ID: uploaded.ID, Kind: provider.AttachmentImage, MimeType: "image/png"})
	}
	if attachments[0].ID != attachments[1].ID {
		t.Fatalf("the same image uploaded as %q and %q, want it stored once", attachments[0].ID, attachments[1].ID)
	}
	delivery := client.command(t, wire.CommandParams{Deliver: &orchestration.Deliver{Thread: thread, Body: orchestration.MessageBody{Text: "look", Attachments: attachments}}}).Delivery
	turn := client.waitSettled(t, thread, delivery)
	user := slices.IndexFunc(turn.Entries, func(entry orchestration.EntryView) bool { return entry.Kind == provider.ItemKindUserMessage })
	if user < 0 || len(turn.Entries[user].Attachments) != 3 || turn.Entries[user].Attachments[0].Data != "" {
		t.Fatalf("user entry = %+v, want three attachments without data", turn.Entries)
	}
	if encoded, _ := json.Marshal(client.subscribe(t, thread)); len(encoded) > 64<<10 {
		t.Fatalf("thread snapshot is %d bytes, want attachment data left out", len(encoded))
	}
	var fetched provider.Attachment
	client.call(t, wire.MethodAttachmentGet, wire.AttachmentParams{ID: turn.Entries[user].Attachments[1].ID}, &fetched)
	if fetched.Data != image {
		t.Fatalf("fetched attachment = %d bytes, want the image", len(fetched.Data))
	}
	_, err := client.commandErr(wire.CommandParams{Deliver: &orchestration.Deliver{Thread: thread, Body: orchestration.MessageBody{Text: "again", Attachments: []provider.Attachment{{ID: strings.Repeat("0", 64), Kind: provider.AttachmentImage}}}}})
	if code, reason := commandCode(err); code != invalidParamsCode || reason != orchestration.CodeInvalid {
		t.Fatalf("a message naming an image never uploaded = %v, want refused invalid", err)
	}
}

// What an agent reports about its session reaches clients live and in a
// later client's snapshot: slash commands, the title it set, its usage, and
// a setting changed from the app.
func TestAgentMetadataReachesClients(t *testing.T) {
	s := newTestServer(t)
	startFakeACPAgent(t, s, "agent")
	client := newRecordingClient(t, s)
	created := client.createThread(t, "agent", t.TempDir())
	client.subscribe(t, created.Thread)
	client.waitSettled(t, created.Thread, client.deliver(t, created.Thread, "metadata").Delivery)
	client.waitEvent(t, "the agent's title", func(event orchestration.ThreadEvent) bool {
		return event.Kind == orchestration.EventThread && event.Summary.Title == "Agent set title"
	})

	client.command(t, wire.CommandParams{UpdateParticipant: &orchestration.UpdateParticipant{Participant: created.Participant, Setting: provider.ConfigOptionSelection{OptionID: "model", Value: "test-model-2"}}})
	client.waitEvent(t, "the model change", func(event orchestration.ThreadEvent) bool {
		return event.Kind == orchestration.EventParticipant && event.Participant.Model == "test-model-2"
	})

	snapshot := newRecordingClient(t, s).subscribe(t, created.Thread)
	if snapshot.Thread.Title != "Agent set title" || len(snapshot.Participants) != 1 {
		t.Fatalf("snapshot = %+v", snapshot.Thread)
	}
	agent := snapshot.Participants[0]
	if len(agent.Commands) != 1 || agent.Commands[0].Name != "compact" {
		t.Fatalf("commands = %+v, want the agent's compact", agent.Commands)
	}
	if agent.Usage == nil || agent.Usage.UsedTokens != 1200 || agent.Usage.MaxTokens != 200000 || agent.Usage.Cost != 0.42 || agent.Usage.Currency != "USD" {
		t.Fatalf("usage = %+v, want 1200 of 200000 for 0.42 USD", agent.Usage)
	}
	if agent.Model != "test-model-2" || !agent.Live {
		t.Fatalf("agent = %+v, want live on test-model-2", agent.ParticipantSummary)
	}
}

// A native session the agent kept opens as a chat once, showing what the
// agent replays of it; an agent that can't reopen sessions refuses it.
func TestImportedSessionShowsItsHistory(t *testing.T) {
	s := newTestServer(t)
	history := t.TempDir()
	if err := os.WriteFile(filepath.Join(history, "external-session.json"), []byte(`["earlier prompt"]`), 0o644); err != nil {
		t.Fatal(err)
	}
	startFakeACPAgent(t, s, "agent", "-history", history)
	startFakeACPAgent(t, s, "list-only", "-list-only")
	client := newRecordingClient(t, s)
	cwd := t.TempDir()
	importing := orchestration.CreateThread{Title: "Imported", Workspace: provider.Workspace{Cwd: cwd}, Participant: orchestration.NewParticipant{Instance: "agent", Session: "external-session"}}
	imported := client.command(t, wire.CommandParams{CreateThread: &importing})
	if again := client.command(t, wire.CommandParams{CreateThread: &importing}); again.Thread != imported.Thread {
		t.Fatalf("importing again made %q, want the chat %q", again.Thread, imported.Thread)
	}

	want := []string{"user_message: earlier prompt", "assistant_message: replayed"}
	var shown []string
	waitUntil(t, "the agent's replay", func() bool {
		snapshot := client.subscribe(t, imported.Thread)
		shown = nil
		for _, turn := range snapshot.Turns {
			shown = append(shown, entryTexts(turn)...)
		}
		return slices.Equal(shown, want)
	})

	importing.Participant.Instance = "list-only"
	_, err := client.commandErr(wire.CommandParams{CreateThread: &importing})
	if code, reason := commandCode(err); code != invalidParamsCode || reason != orchestration.CodeInvalid {
		t.Fatalf("importing into an agent that can't reopen sessions = %v, want refused invalid", err)
	}
}

// A fork of an agent that can't fork natively is previewed as a summary of
// the chat; the person's message carrying it is the fork's first, sent as
// written and nothing added.
func TestForkOfAnAgentThatCantForkSendsThePreviewedSummary(t *testing.T) {
	s := newTestServer(t)
	history := t.TempDir()
	startFakeACPAgent(t, s, "agent", "-history", history)
	client := newRecordingClient(t, s)
	source := client.createThread(t, "agent", t.TempDir())
	client.subscribe(t, source.Thread)
	client.waitSettled(t, source.Thread, client.deliver(t, source.Thread, "first").Delivery)

	var preview wire.ForkPreview
	client.call(t, wire.MethodThreadForkPreview, wire.ThreadForkPreviewParams{Thread: source.Thread}, &preview)
	if preview.Native || !strings.Contains(preview.Summary, "User:\nfirst") || !strings.Contains(preview.Summary, "hi") {
		t.Fatalf("preview = %#v, want the chat as a summary", preview)
	}
	if _, err := client.commandErr(wire.CommandParams{ForkThread: &orchestration.ForkThread{Thread: source.Thread, Prompt: orchestration.MessageBody{Text: "x"}}}); err == nil {
		t.Fatal("a native fork of an agent that can't fork was made")
	}
	prompt := "edited\n\n" + preview.Summary
	fork := client.command(t, wire.CommandParams{ForkThread: &orchestration.ForkThread{
		Thread: source.Thread, Agent: &orchestration.NewParticipant{Instance: "agent"}, Prompt: orchestration.MessageBody{Text: prompt},
	}})
	client.subscribe(t, fork.Thread)
	if turn := client.waitSettled(t, fork.Thread, fork.Delivery); turn.State != provider.TurnCompleted {
		t.Fatalf("fork turn = %s, want completed", turn.State)
	}

	files, err := filepath.Glob(filepath.Join(history, "*.json"))
	if err != nil {
		t.Fatal(err)
	}
	var sessions [][]string
	for _, file := range files {
		data, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		var prompts []string
		if err := json.Unmarshal(data, &prompts); err != nil {
			t.Fatal(err)
		}
		sessions = append(sessions, prompts)
	}
	slices.SortFunc(sessions, func(a, b []string) int { return strings.Compare(a[0], b[0]) })
	if want := [][]string{{prompt}, {"first"}}; !reflect.DeepEqual(sessions, want) {
		t.Fatalf("the agent's sessions got %q, want %q", sessions, want)
	}
}

// A client that stops reading is closed once its queue overflows, without
// holding up a client that keeps up; it recovers from one snapshot.
func TestSlowClientIsClosedAndRecoversFromASnapshot(t *testing.T) {
	s := newTestServer(t)
	startFakeACPAgent(t, s, "agent")
	url := newWSTestServer(t, s)
	observer := dialRecordingClient(t, url)
	thread := observer.createThread(t, "agent", t.TempDir()).Thread
	observer.subscribe(t, thread)
	connected := func() map[string]*rpcClient {
		s.rpcMu.Lock()
		defer s.rpcMu.Unlock()
		clients := make(map[string]*rpcClient, len(s.rpcClients))
		for id, client := range s.rpcClients {
			clients[id] = client
		}
		return clients
	}
	before := connected()

	// The slow client subscribes over the raw socket and never reads again:
	// a frozen app.
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	slow, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer func() { _ = slow.CloseNow() }()
	slow.SetReadLimit(-1)
	subscribe, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": wire.MethodThreadSubscribe, "params": wire.ThreadParams{Thread: thread}})
	if err := slow.Write(ctx, websocket.MessageText, subscribe); err != nil {
		t.Fatalf("subscribe: %v", err)
	}
	if _, _, err := slow.Read(ctx); err != nil {
		t.Fatalf("subscribe response: %v", err)
	}
	var slowClient *rpcClient
	for id, client := range connected() {
		if before[id] == nil {
			slowClient = client
		}
	}
	if slowClient == nil {
		t.Fatal("the slow client isn't registered")
	}

	// Unpaced tool entries, more than the socket buffers and the outbound
	// queue hold.
	const tools = 6000
	delivery := observer.deliver(t, thread, fmt.Sprintf("tools %d", tools)).Delivery
	waitUntil(t, "the slow client closed", slowClient.closed.Load)
	drained := 0
	for {
		if _, _, err := slow.Read(ctx); err != nil {
			if websocket.CloseStatus(err) == -1 {
				t.Fatalf("slow client read ended without a close frame: %v", err)
			}
			break
		}
		drained++
	}
	if drained >= tools {
		t.Fatalf("slow client drained %d notifications, want it closed before the flood ended", drained)
	}

	observer.waitSettled(t, thread, delivery)
	seen := map[string]bool{}
	observer.mu.Lock()
	for _, event := range observer.threadEvents {
		if event.Kind == orchestration.EventEntry && event.Entry.Kind != provider.ItemKindUserMessage {
			seen[event.Entry.Ref] = true
		}
	}
	observer.mu.Unlock()
	if len(seen) != tools {
		t.Fatalf("observer saw %d tool entries, want %d", len(seen), tools)
	}
	snapshot := dialRecordingClient(t, url).subscribe(t, thread)
	if latest := snapshot.Turns[len(snapshot.Turns)-1]; len(latest.Entries) != tools+1 || !latest.State.Settled() {
		t.Fatalf("recovered turn = %d entries, %s; want the whole settled turn", len(latest.Entries), latest.State)
	}
}

// A client whose link goes silent stops answering pings and is dropped, while
// one that keeps reading stays.
func TestClientThatStopsAnsweringPingsIsDropped(t *testing.T) {
	s := newTestServer(t)
	s.pingInterval = 50 * time.Millisecond
	url := newWSTestServer(t, s)
	connected := func() int {
		s.rpcMu.Lock()
		defer s.rpcMu.Unlock()
		return len(s.rpcClients)
	}
	live := dialRecordingClient(t, url)
	silent, _, err := websocket.Dial(context.Background(), url, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer func() { _ = silent.CloseNow() }()
	waitUntil(t, "both clients registered", func() bool { return connected() == 2 })
	waitUntil(t, "the silent client dropped", func() bool { return connected() == 1 })
	var providers []provider.InstanceInfo
	live.call(t, wire.MethodProviderList, nil, &providers)
	if got := connected(); got != 1 {
		t.Fatalf("connected clients = %d after the live client's call, want 1", got)
	}
}

// One call hanging on a registry fetch, as a slow provider start would,
// doesn't hold up other calls or terminal input on the same connection.
func TestSlowCallDoesNotBlockConnection(t *testing.T) {
	useQuietTestShell(t)
	fetching, release := make(chan struct{}, 1), make(chan struct{})
	registry := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		fetching <- struct{}{}
		<-release
		_, _ = w.Write([]byte(testACPRegistry))
	}))
	defer registry.Close()
	defer close(release)
	s := newTestServer(t)
	s.acpRegistry = &acpRegistry{url: registry.URL, client: registry.Client(), dataDir: t.TempDir(), npm: "npm"}
	client := newRecordingClient(t, s)

	slow := make(chan error, 1)
	go func() { slow <- client.callErr(wire.MethodACPRegistryList, nil, nil) }()
	<-fetching
	var list []provider.InstanceInfo
	client.call(t, wire.MethodProviderList, nil, &list)
	created := createTestTerminal(t, client)
	client.writeTerminal(t, created.Terminal.TerminalID, created.RunID, "printf 'NOT-BLOCKED-%d\\n' $((6*7))\n")
	client.waitForOutput(t, "NOT-BLOCKED-42")
	select {
	case err := <-slow:
		t.Fatalf("registry list returned before its fetch was released: %v", err)
	default:
	}
}

func TestRunWebSocketDoesNotStartAfterServerClosed(t *testing.T) {
	s := newTestServer(t)
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	done := make(chan error, 1)
	go func() { done <- s.RunWebSocket("127.0.0.1:0") }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("RunWebSocket after Close: %v", err)
		}
	case <-time.After(5 * time.Second):
		s.mu.Lock()
		httpServer := s.httpServer
		s.mu.Unlock()
		if httpServer != nil {
			_ = httpServer.Close()
		}
		t.Fatalf("RunWebSocket started listening after Close completed (and returned %v once closed)", <-done)
	}
}
