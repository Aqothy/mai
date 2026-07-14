package daemon

// Multi-client sync tests use two real WebSocket clients exercising
// simultaneous actions, cross-client approvals/interrupts, reconnect
// mid-turn, a slow client that
// gets overflow-closed and recovers, and mobile-sized per-thread replay paging.
// Every client here follows the documented CLIENT_API.md sync contract.

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Aqothy/jsonrpc2"
	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
	"github.com/coder/websocket"
)

func newWSTestServer(t *testing.T, s *Server) string {
	t.Helper()
	server := httptest.NewServer(s.WebSocketHandler())
	t.Cleanup(server.Close)
	return "ws" + strings.TrimPrefix(server.URL, "http")
}

// recordingClient is a real WS JSON-RPC client that losslessly records every
// notification in arrival order, the way a thin UI replica would.
type recordingClient struct {
	conn *jsonrpc2.Connection

	mu           sync.Mutex
	threadEvents map[orchestration.ThreadID][]orchestration.Event
	shellItems   []orchestration.ThreadListStreamItem
}

func dialRecordingClient(t *testing.T, url string) *recordingClient {
	t.Helper()
	c := &recordingClient{threadEvents: make(map[orchestration.ThreadID][]orchestration.Event)}
	ws, _, err := websocket.Dial(context.Background(), url, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	// Snapshots/replay pages of long threads exceed the 32KiB library default.
	ws.SetReadLimit(-1)
	c.conn = jsonrpc2.NewWebSocketConnection(context.Background(), wsJSONRPC{conn: ws}, c)
	t.Cleanup(func() { _ = c.conn.Close() })
	return c
}

func (c *recordingClient) Handle(ctx context.Context, req *jsonrpc2.Request) (any, error) {
	if req.IsCall() {
		return nil, jsonrpc2.ErrNotHandled
	}
	switch req.Method {
	case RPCMethodOrchestrationSubscribeThread:
		var item orchestration.ThreadStreamItem
		if err := decodeRPCParams(req, &item); err != nil {
			return nil, err
		}
		if item.Kind == "event" && item.Event != nil {
			c.mu.Lock()
			threadID := item.Event.ThreadID()
			c.threadEvents[threadID] = append(c.threadEvents[threadID], *item.Event)
			c.mu.Unlock()
		}
	case RPCMethodOrchestrationSubscribeThreadList:
		var item orchestration.ThreadListStreamItem
		if err := decodeRPCParams(req, &item); err != nil {
			return nil, err
		}
		c.mu.Lock()
		c.shellItems = append(c.shellItems, item)
		c.mu.Unlock()
	}
	return nil, nil
}

func (c *recordingClient) callErr(method string, params any, result any) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return c.conn.Call(ctx, method, params).Await(ctx, result)
}

func (c *recordingClient) call(t *testing.T, method string, params any, result any) {
	t.Helper()
	if err := c.callErr(method, params, result); err != nil {
		t.Fatalf("%s: %v", method, err)
	}
}

func (c *recordingClient) dispatchErr(command orchestration.Command) (orchestration.DispatchResult, error) {
	var receipt orchestration.DispatchResult
	err := c.callErr(RPCMethodOrchestrationDispatchCommand, command, &receipt)
	return receipt, err
}

func (c *recordingClient) dispatch(t *testing.T, command orchestration.Command) orchestration.DispatchResult {
	t.Helper()
	receipt, err := c.dispatchErr(command)
	if err != nil {
		t.Fatalf("dispatch %s (%s): %v", command.Type, command.CommandID, err)
	}
	return receipt
}

func (c *recordingClient) subscribeThread(t *testing.T, threadID orchestration.ThreadID) orchestration.ThreadDetailSnapshot {
	t.Helper()
	var item orchestration.ThreadStreamItem
	c.call(t, RPCMethodOrchestrationSubscribeThread, orchestration.SubscribeThreadInput{ThreadID: threadID}, &item)
	if item.Kind != "snapshot" || item.Snapshot == nil {
		t.Fatalf("subscribeThread %s = %#v, want snapshot", threadID, item)
	}
	return *item.Snapshot
}

func (c *recordingClient) subscribeThreadList(t *testing.T) orchestration.ThreadListSnapshot {
	t.Helper()
	var snapshot orchestration.ThreadListSnapshot
	c.call(t, RPCMethodOrchestrationSubscribeThreadList, nil, &snapshot)
	return snapshot
}

func (c *recordingClient) threadLog(threadID orchestration.ThreadID) []orchestration.Event {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]orchestration.Event(nil), c.threadEvents[threadID]...)
}

func (c *recordingClient) shellLog() []orchestration.ThreadListStreamItem {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]orchestration.ThreadListStreamItem(nil), c.shellItems...)
}

func (c *recordingClient) waitThread(t *testing.T, threadID orchestration.ThreadID, desc string, match func([]orchestration.Event) bool) {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		if match(c.threadLog(threadID)) {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	log := c.threadLog(threadID)
	summary := make([]string, 0, 10)
	for _, event := range log[max(0, len(log)-10):] {
		summary = append(summary, fmt.Sprintf("%d:%s", event.Sequence, event.Type))
	}
	t.Fatalf("timed out waiting for %s on %s (saw %d events, tail: %s)", desc, threadID, len(log), strings.Join(summary, " "))
}

func hasEvent(events []orchestration.Event, match func(orchestration.Event) bool) bool {
	for _, event := range events {
		if match(event) {
			return true
		}
	}
	return false
}

// assistantMessageAfter matches the first coalesced assistant chunk flushed
// after the given sequence.
func assistantMessageAfter(afterSequence uint64) func([]orchestration.Event) bool {
	return func(events []orchestration.Event) bool {
		return hasEvent(events, func(event orchestration.Event) bool {
			return event.Sequence > afterSequence &&
				event.Type == orchestration.EventThreadMessageSent &&
				event.Payload.Role == orchestration.MessageRoleAssistant
		})
	}
}

func sessionStatusAfter(afterSequence uint64, status orchestration.SessionStatus) func([]orchestration.Event) bool {
	return func(events []orchestration.Event) bool {
		return hasEvent(events, func(event orchestration.Event) bool {
			return event.Sequence > afterSequence &&
				event.Type == orchestration.EventThreadSessionStatusSet &&
				event.Payload.Session != nil &&
				event.Payload.Session.Status == status
		})
	}
}

func interruptSettledAfter(afterSequence uint64) func([]orchestration.Event) bool {
	return func(events []orchestration.Event) bool {
		return hasEvent(events, func(event orchestration.Event) bool {
			if event.Sequence <= afterSequence {
				return false
			}
			if event.Type == orchestration.EventThreadTurnInterruptConfirmed {
				return true // interrupt won before provider dispatch; session stays ready
			}
			return event.Type == orchestration.EventThreadSessionStatusSet && event.Payload.Session != nil && event.Payload.Session.Status == orchestration.SessionStatusInterrupted
		})
	}
}

func eventJSON(t *testing.T, event orchestration.Event) string {
	t.Helper()
	raw, err := json.Marshal(event)
	if err != nil {
		t.Fatalf("marshal event: %v", err)
	}
	return string(raw)
}

// requireSameStream asserts two clients received the identical event stream
// for a thread: same order, same sequences, same payloads — and that the
// stream itself is duplicate-free (strictly ascending sequences).
func requireSameStream(t *testing.T, threadID orchestration.ThreadID, gotName string, got []orchestration.Event, wantName string, want []orchestration.Event) {
	t.Helper()
	for i := 1; i < len(got); i++ {
		if got[i].Sequence <= got[i-1].Sequence {
			t.Fatalf("%s stream for %s not strictly ascending at index %d: %d after %d", gotName, threadID, i, got[i].Sequence, got[i-1].Sequence)
		}
	}
	if len(got) != len(want) {
		t.Fatalf("%s saw %d events for %s, %s saw %d", gotName, len(got), threadID, wantName, len(want))
	}
	for i := range want {
		if got[i].Sequence != want[i].Sequence || eventJSON(t, got[i]) != eventJSON(t, want[i]) {
			t.Fatalf("%s and %s diverge at index %d for %s:\n%s: %s\n%s: %s",
				gotName, wantName, i, threadID, gotName, eventJSON(t, got[i]), wantName, eventJSON(t, want[i]))
		}
	}
}

// fence dispatches a meta update and waits until every client has seen it.
// Notifications per connection are FIFO, so once the fence arrives every
// earlier event for that thread has been delivered too.
func fence(t *testing.T, from *recordingClient, threadID orchestration.ThreadID, tag string, clients ...*recordingClient) {
	t.Helper()
	from.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadMetaUpdate, CommandID: orchestration.CommandID("cmd-fence-" + tag), ThreadID: threadID, Title: "fence-" + tag})
	for _, client := range clients {
		client.waitThread(t, threadID, "fence "+tag, func(events []orchestration.Event) bool {
			return hasEvent(events, func(event orchestration.Event) bool {
				return event.Type == orchestration.EventThreadMetaUpdated && event.Payload.Title == "fence-"+tag
			})
		})
	}
}

type dispatchOutcome struct {
	receipt orchestration.DispatchResult
	err     error
}

// TestRPCTwoClientsConvergeAcrossSimultaneousAndCrossClientActions covers
// simultaneous creates and prompts, a cross-client command retry
// (idempotency), an approval opened by one
// client's turn and answered by the other, a mid-turn steer from the other
// client, and an interrupt from the other client. Both clients must end with
// identical event streams and snapshots with no manual refresh.
func TestRPCTwoClientsConvergeAcrossSimultaneousAndCrossClientActions(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()
	if _, err := s.StartProvider(context.Background(), acpInstanceSpec("codex", "codex", helperCommand("scripted-sessions")), false); err != nil {
		t.Fatalf("provider start: %v", err)
	}
	url := newWSTestServer(t, s)
	a := dialRecordingClient(t, url)
	b := dialRecordingClient(t, url)
	a.subscribeThreadList(t)
	b.subscribeThreadList(t)

	threadOne := orchestration.ThreadID("thread-multi-1")
	threadTwo := orchestration.ThreadID("thread-multi-2")
	cwd := t.TempDir()
	createOne := orchestration.Command{Type: orchestration.CommandThreadCreate, CommandID: "cmd-multi-create-1", ThreadID: threadOne, Title: "Multi one", ProviderInstanceID: "codex", Cwd: cwd}
	createTwo := orchestration.Command{Type: orchestration.CommandThreadCreate, CommandID: "cmd-multi-create-2", ThreadID: threadTwo, Title: "Multi two", ProviderInstanceID: "codex", Cwd: cwd}

	// Simultaneous thread creation, one from each client.
	outcomes := make(chan dispatchOutcome, 2)
	go func() {
		receipt, err := a.dispatchErr(createOne)
		outcomes <- dispatchOutcome{receipt, err}
	}()
	go func() {
		receipt, err := b.dispatchErr(createTwo)
		outcomes <- dispatchOutcome{receipt, err}
	}()
	for i := 0; i < 2; i++ {
		if outcome := <-outcomes; outcome.err != nil {
			t.Fatalf("simultaneous create: %v", outcome.err)
		}
	}

	// Cross-client idempotency: B retries A's create with the same commandId;
	// the receipt must point at the original event and no duplicate may exist.
	retryReceipt := b.dispatch(t, createOne)
	var threadOneEvents []orchestration.Event
	a.call(t, RPCMethodOrchestrationReplayEvents, orchestration.ReplayEventsInput{ThreadID: threadOne}, &threadOneEvents)
	if len(threadOneEvents) != 1 || threadOneEvents[0].Type != orchestration.EventThreadCreated {
		t.Fatalf("thread one events after cross-client retry = %#v, want exactly one thread.created", threadOneEvents)
	}
	if retryReceipt.Sequence != threadOneEvents[0].Sequence {
		t.Fatalf("cross-client retry receipt sequence = %d, want original %d", retryReceipt.Sequence, threadOneEvents[0].Sequence)
	}

	for _, client := range []*recordingClient{a, b} {
		client.subscribeThread(t, threadOne)
		client.subscribeThread(t, threadTwo)
	}

	// Simultaneous prompts, one per client on different threads.
	promptOne := orchestration.Command{Type: orchestration.CommandThreadTurnStart, CommandID: "cmd-multi-turn-1", ThreadID: threadOne, Message: &orchestration.CommandMessage{MessageID: "msg-multi-1", Text: "stream 40 16"}}
	promptTwo := orchestration.Command{Type: orchestration.CommandThreadTurnStart, CommandID: "cmd-multi-turn-2", ThreadID: threadTwo, Message: &orchestration.CommandMessage{MessageID: "msg-multi-2", Text: "stream 40 16"}}
	go func() {
		receipt, err := a.dispatchErr(promptOne)
		outcomes <- dispatchOutcome{receipt, err}
	}()
	go func() {
		receipt, err := b.dispatchErr(promptTwo)
		outcomes <- dispatchOutcome{receipt, err}
	}()
	for i := 0; i < 2; i++ {
		if outcome := <-outcomes; outcome.err != nil {
			t.Fatalf("simultaneous prompt: %v", outcome.err)
		}
	}
	for _, client := range []*recordingClient{a, b} {
		client.waitThread(t, threadOne, "first assistant output", assistantMessageAfter(0))
		client.waitThread(t, threadTwo, "first assistant output", assistantMessageAfter(0))
	}

	// Cross-client approval: A's prompt opens an approval, B answers it.
	permissionReceipt := a.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadTurnStart, CommandID: "cmd-multi-perm", ThreadID: threadOne, Message: &orchestration.CommandMessage{MessageID: "msg-multi-perm", Text: "permission"}})
	var requestID orchestration.ApprovalID
	approvalOpened := func(events []orchestration.Event) bool {
		for _, event := range events {
			if event.Sequence > permissionReceipt.Sequence && event.Type == orchestration.EventThreadApprovalOpened && event.Payload.Approval != nil {
				requestID = orchestration.ApprovalID(event.Payload.Approval.RequestID)
				return true
			}
		}
		return false
	}
	a.waitThread(t, threadOne, "approval opened", approvalOpened)
	b.waitThread(t, threadOne, "approval opened", approvalOpened)
	b.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadApprovalRespond, CommandID: "cmd-multi-approve", ThreadID: threadOne, RequestID: requestID, Decision: provider.ApprovalDecisionAccept})
	for _, client := range []*recordingClient{a, b} {
		client.waitThread(t, threadOne, "approval resolved", func(events []orchestration.Event) bool {
			return hasEvent(events, func(event orchestration.Event) bool {
				return event.Type == orchestration.EventThreadApprovalResolved && event.Payload.Approval != nil && event.Payload.Approval.Decision == provider.ApprovalDecisionAccept
			})
		})
		client.waitThread(t, threadOne, "approved turn output", assistantMessageAfter(permissionReceipt.Sequence))
	}
	if !hasEvent(a.threadLog(threadOne), func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadMessageSent && event.Payload.Role == orchestration.MessageRoleAssistant && strings.Contains(event.Payload.Text, "perm:allow")
	}) {
		t.Fatal("approved turn never streamed the agent's post-approval output")
	}

	// Mid-turn steer from the other client: B starts a long stream on thread
	// two, A steers it with a follow-up prompt while it runs.
	b.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadTurnStart, CommandID: "cmd-multi-steer-base", ThreadID: threadTwo, Message: &orchestration.CommandMessage{MessageID: "msg-multi-steer-base", Text: "stream 200 16"}})
	steerReceipt := a.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadTurnStart, CommandID: "cmd-multi-steer", ThreadID: threadTwo, Message: &orchestration.CommandMessage{MessageID: "msg-multi-steer", Text: "stream 5 16"}})
	for _, client := range []*recordingClient{a, b} {
		client.waitThread(t, threadTwo, "steered turn settle", sessionStatusAfter(steerReceipt.Sequence, orchestration.SessionStatusReady))
	}

	// Interrupt from the other client: A parks a blocked prompt on thread one,
	// B interrupts it.
	blockReceipt := a.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadTurnStart, CommandID: "cmd-multi-block", ThreadID: threadOne, Message: &orchestration.CommandMessage{MessageID: "msg-multi-block", Text: "block"}})
	b.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadTurnInterrupt, CommandID: "cmd-multi-interrupt", ThreadID: threadOne})
	for _, client := range []*recordingClient{a, b} {
		client.waitThread(t, threadOne, "interrupted turn settle", interruptSettledAfter(blockReceipt.Sequence))
	}

	// Fence both threads, then require full convergence.
	fence(t, a, threadOne, "one", a, b)
	fence(t, b, threadTwo, "two", a, b)
	requireSameStream(t, threadOne, "clientA", a.threadLog(threadOne), "clientB", b.threadLog(threadOne))
	requireSameStream(t, threadTwo, "clientA", a.threadLog(threadTwo), "clientB", b.threadLog(threadTwo))

	for _, threadID := range []orchestration.ThreadID{threadOne, threadTwo} {
		snapshotA := a.subscribeThread(t, threadID)
		snapshotB := b.subscribeThread(t, threadID)
		rawA, _ := json.Marshal(snapshotA.Thread)
		rawB, _ := json.Marshal(snapshotB.Thread)
		if string(rawA) != string(rawB) {
			t.Fatalf("final snapshots for %s diverge:\nA: %s\nB: %s", threadID, rawA, rawB)
		}
	}
	for name, client := range map[string]*recordingClient{"clientA": a, "clientB": b} {
		seen := map[orchestration.ThreadID]bool{}
		for _, item := range client.shellLog() {
			if item.Thread != nil {
				seen[item.Thread.ID] = true
			}
		}
		if !seen[threadOne] || !seen[threadTwo] {
			t.Fatalf("%s shell stream missing thread upserts (saw %v)", name, seen)
		}
	}
}

// replayCatchUp reconnects per the sync contract: subscribe first (live
// events buffer via the recorder), then page replayEvents from the last
// applied sequence, then apply buffered live events past the watermark. It
// returns the merged, deduped event log a correct client would hold.
func replayCatchUp(t *testing.T, client *recordingClient, threadID orchestration.ThreadID, applied []orchestration.Event, pageLimit int) []orchestration.Event {
	t.Helper()
	watermark := uint64(0)
	if len(applied) > 0 {
		watermark = applied[len(applied)-1].Sequence
	}
	merged := append([]orchestration.Event(nil), applied...)
	client.subscribeThread(t, threadID)
	for {
		var page []orchestration.Event
		client.call(t, RPCMethodOrchestrationReplayEvents, orchestration.ReplayEventsInput{FromSequenceExclusive: watermark, ThreadID: threadID, Limit: pageLimit}, &page)
		for _, event := range page {
			if event.Sequence <= watermark {
				t.Fatalf("replay page returned sequence %d at or below watermark %d", event.Sequence, watermark)
			}
			merged = append(merged, event)
			watermark = event.Sequence
		}
		if len(page) < pageLimit {
			break
		}
	}
	return merged
}

// applyLive folds live-recorded events into a merged log, dropping everything
// at or below the current watermark (the dedupe rule).
func applyLive(merged []orchestration.Event, live []orchestration.Event) []orchestration.Event {
	watermark := uint64(0)
	if len(merged) > 0 {
		watermark = merged[len(merged)-1].Sequence
	}
	for _, event := range live {
		if event.Sequence > watermark {
			merged = append(merged, event)
			watermark = event.Sequence
		}
	}
	return merged
}

// TestRPCReconnectMidTurnCatchesUpWithoutGapsOrDuplicates hard-drops a client
// mid-stream, reconnects while the turn is still streaming, catches up via
// per-thread paged replayEvents plus
// the live stream, and must converge to exactly what a never-disconnected
// observer saw.
func TestRPCReconnectMidTurnCatchesUpWithoutGapsOrDuplicates(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()
	if _, err := s.StartProvider(context.Background(), acpInstanceSpec("codex", "codex", helperCommand("scripted-sessions")), false); err != nil {
		t.Fatalf("provider start: %v", err)
	}
	url := newWSTestServer(t, s)
	observer := dialRecordingClient(t, url)

	threadID := orchestration.ThreadID("thread-reconnect")
	observer.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadCreate, CommandID: "cmd-reconnect-create", ThreadID: threadID, Title: "Reconnect", ProviderInstanceID: "codex", Cwd: t.TempDir()})
	observer.subscribeThread(t, threadID)

	dropper := dialRecordingClient(t, url)
	dropperSnapshot := dropper.subscribeThread(t, threadID)

	// A long UNPACED turn of per-event tool-call updates (assistant text is
	// coalesced server-side, so a text burst reaches clients as few events);
	// the dropper disconnects partway through and must reconnect while it is
	// still running. Unpaced also regression-guards the SDK burst fix: the old
	// acp-go-sdk killed the provider connection at ~1100 back-to-back updates
	// (fixed 1024-slot queue).
	turnReceipt := observer.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadTurnStart, CommandID: "cmd-reconnect-turn", ThreadID: threadID, Message: &orchestration.CommandMessage{MessageID: "msg-reconnect", Text: "tools 1500"}})
	dropper.waitThread(t, threadID, "some streamed events before dropping", func(events []orchestration.Event) bool {
		return len(events) >= 200
	})
	preDropLog := dropper.threadLog(threadID)
	if err := dropper.conn.Close(); err != nil {
		t.Fatalf("hard-close dropper: %v", err)
	}
	// The catch-up only exercises the mid-turn path if the turn is still
	// running when the replacement connection subscribes.
	if sessionStatusAfter(turnReceipt.Sequence, orchestration.SessionStatusReady)(observer.threadLog(threadID)) {
		t.Fatal("turn already settled before reconnect; raise the tool-call count")
	}

	// Reconnect and catch up per the sync contract. preDropLog may contain
	// events the pre-drop snapshot already covered; apply the dedupe rule.
	applied := applyLive(nil, preDropLog)
	if len(applied) > 0 && applied[0].Sequence <= dropperSnapshot.SnapshotSequence {
		filtered := applied[:0]
		for _, event := range applied {
			if event.Sequence > dropperSnapshot.SnapshotSequence {
				filtered = append(filtered, event)
			}
		}
		applied = filtered
	}
	reconnected := dialRecordingClient(t, url)
	merged := replayCatchUp(t, reconnected, threadID, applied, 1000)

	// Wait for the turn to settle on both connections, then fence.
	observer.waitThread(t, threadID, "turn settle", sessionStatusAfter(turnReceipt.Sequence, orchestration.SessionStatusReady))
	reconnected.waitThread(t, threadID, "turn settle", sessionStatusAfter(turnReceipt.Sequence, orchestration.SessionStatusReady))

	// A follow-up turn proves the reconnected client stays live-consistent.
	followUpReceipt := observer.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadTurnStart, CommandID: "cmd-reconnect-followup", ThreadID: threadID, Message: &orchestration.CommandMessage{MessageID: "msg-reconnect-followup", Text: "stream 3 8"}})
	observer.waitThread(t, threadID, "follow-up settle", sessionStatusAfter(followUpReceipt.Sequence, orchestration.SessionStatusReady))
	reconnected.waitThread(t, threadID, "follow-up settle", sessionStatusAfter(followUpReceipt.Sequence, orchestration.SessionStatusReady))
	fence(t, observer, threadID, "reconnect", observer, reconnected)

	merged = applyLive(merged, reconnected.threadLog(threadID))

	// The observer subscribed before the turn started and never disconnected:
	// its log restricted to what the dropper should have (everything after the
	// dropper's snapshot) is the ground truth.
	want := make([]orchestration.Event, 0)
	for _, event := range observer.threadLog(threadID) {
		if event.Sequence > dropperSnapshot.SnapshotSequence {
			want = append(want, event)
		}
	}
	requireSameStream(t, threadID, "reconnected-merged", merged, "observer", want)
}

// TestRPCSlowClientOverflowClosesAndRecoversViaPagedReplay runs the
// overflow-close policy end-to-end: a subscribed client that stops reading is
// disconnected by the daemon once its outbound queue fills, healthy clients
// keep streaming unaffected, and the slow client recovers to full consistency
// with mobile-sized per-thread replay pages.
func TestRPCSlowClientOverflowClosesAndRecoversViaPagedReplay(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()
	if _, err := s.StartProvider(context.Background(), acpInstanceSpec("codex", "codex", helperCommand("scripted-sessions")), false); err != nil {
		t.Fatalf("provider start: %v", err)
	}
	url := newWSTestServer(t, s)
	observer := dialRecordingClient(t, url)

	threadID := orchestration.ThreadID("thread-overflow")
	observer.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadCreate, CommandID: "cmd-overflow-create", ThreadID: threadID, Title: "Overflow", ProviderInstanceID: "codex", Cwd: t.TempDir()})
	observer.subscribeThread(t, threadID)

	// The slow client subscribes at the raw WebSocket level and then never
	// reads again — a backgrounded/frozen client.
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	slow, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatalf("slow client dial: %v", err)
	}
	defer slow.Close(websocket.StatusNormalClosure, "")
	subscribe, err := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": RPCMethodOrchestrationSubscribeThread, "params": orchestration.SubscribeThreadInput{ThreadID: threadID}})
	if err != nil {
		t.Fatalf("marshal subscribe: %v", err)
	}
	if err := slow.Write(ctx, websocket.MessageText, subscribe); err != nil {
		t.Fatalf("slow client subscribe write: %v", err)
	}
	// Reading one frame confirms the subscription round-tripped (registration
	// happens before the snapshot response is written).
	if _, _, err := slow.Read(ctx); err != nil {
		t.Fatalf("slow client subscribe response read: %v", err)
	}

	// Flood: enough UNPACED per-event volume (tool-call updates — assistant
	// text is coalesced server-side) to exhaust the slow client's TCP buffers
	// plus the daemon's 1024-notification outbound queue (which cannot drain —
	// the slow client never reads and the writer stalls on its socket). The
	// unpaced agent burst is also the acceptance guard for the go-acp
	// migration: the old SDK deterministically closed the provider connection
	// at ~1100 back-to-back updates, so the observer receiving the full flood
	// proves the provider connection absorbs unpaced bursts.
	const floodChunks = 6000
	turnReceipt := observer.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadTurnStart, CommandID: "cmd-overflow-turn", ThreadID: threadID, Message: &orchestration.CommandMessage{MessageID: "msg-overflow", Text: fmt.Sprintf("tools %d", floodChunks)}})
	observer.waitThread(t, threadID, "flood turn settle", sessionStatusAfter(turnReceipt.Sequence, orchestration.SessionStatusReady))

	// The healthy observer must have received the entire flood.
	streamed := 0
	for _, event := range observer.threadLog(threadID) {
		if event.Type == orchestration.EventThreadItemUpserted && event.Payload.Item != nil {
			streamed++
		}
	}
	if streamed != floodChunks {
		t.Fatalf("observer saw %d tool-call item events, want %d", streamed, floodChunks)
	}

	// The daemon must have overflow-closed the slow client: draining its
	// socket now ends in a close, not in the full flood.
	drained := 0
	for {
		if _, _, err := slow.Read(ctx); err != nil {
			break
		}
		drained++
		if drained > 2*floodChunks {
			t.Fatal("slow client connection was never closed by the daemon")
		}
	}
	if drained >= floodChunks {
		t.Fatalf("slow client drained %d notifications, want an overflow-close before the full flood", drained)
	}

	// Recovery: fresh connection, snapshot, then mobile-sized replay pages
	// from zero must reproduce the observer's stream exactly.
	recovered := dialRecordingClient(t, url)
	recovered.subscribeThread(t, threadID)
	watermark := uint64(0)
	var replayed []orchestration.Event
	pages := 0
	for {
		var page []orchestration.Event
		recovered.call(t, RPCMethodOrchestrationReplayEvents, orchestration.ReplayEventsInput{FromSequenceExclusive: watermark, ThreadID: threadID, Limit: 500}, &page)
		for _, event := range page {
			if event.Sequence <= watermark {
				t.Fatalf("replay page %d returned sequence %d at or below watermark %d", pages, event.Sequence, watermark)
			}
			replayed = append(replayed, event)
			watermark = event.Sequence
		}
		if len(page) < 500 {
			break
		}
		pages++
	}
	if pages < 2 {
		t.Fatalf("replay paging exercised %d full pages, want several (flood should span many pages)", pages)
	}

	observerLog := observer.threadLog(threadID)
	if len(observerLog) == 0 {
		t.Fatal("observer log empty")
	}
	// The observer subscribed after thread.create, so its log starts past the
	// first replayed events; everything from its first sequence on must match.
	fromObserverStart := make([]orchestration.Event, 0, len(replayed))
	for _, event := range replayed {
		if event.Sequence >= observerLog[0].Sequence {
			fromObserverStart = append(fromObserverStart, event)
		}
	}
	requireSameStream(t, threadID, "replayed", fromObserverStart, "observer", observerLog)
	if replayed[0].Type != orchestration.EventThreadCreated {
		t.Fatalf("replay from zero starts with %s, want thread.created", replayed[0].Type)
	}
}
