package orchestration

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// A chat's prompt opens a session, runs a turn, and the turn and its entries
// show in the thread's snapshot.
func TestPromptRunsATurn(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	h := newHarness(t, claude)
	created := h.createThread("claude", "Hello there")
	snapshot := h.settledTurns(created.Thread, 1)
	if len(snapshot.Turns) != 1 || joined(texts(snapshot.Turns[0])) != "user_message: Hello there | assistant_message: answer to Hello there" {
		t.Fatalf("turns = %#v", snapshot.Turns)
	}
	if snapshot.Thread.Title != "Hello there" || snapshot.Thread.Status != StatusIdle || len(snapshot.Queue) != 0 {
		t.Fatalf("summary = %#v, queue = %#v", snapshot.Thread, snapshot.Queue)
	}
	if messages := claude.messages(); len(messages) != 1 || messages[0].in.Text != "Hello there" || messages[0].in.Delivery != string(created.Delivery) {
		t.Fatalf("provider got %#v, want the prompt once as written, carrying its delivery", messages)
	}
}

// Deliveries queue behind a running turn and go, in order, one turn each.
func TestQueuedDeliveriesRunInOrder(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	release := make(chan struct{})
	claude.onSend = func(f *fakeInstance, session string, in provider.SendInput) (provider.SendAck, error) {
		f.startTurn(session, in.Delivery, in)
		go func() {
			if strings.Contains(in.Text, "first") {
				<-release
			}
			f.settle(session, in.Delivery, provider.TurnCompleted)
		}()
		return provider.SendAck{Turn: in.Delivery}, nil
	}
	h := newHarness(t, claude)
	created := h.createThread("claude", "first")
	h.eventually("the first turn to start", func() bool { return len(claude.messages()) == 1 })
	h.do(Deliver{Thread: created.Thread, Body: MessageBody{Text: "second"}})
	h.do(Deliver{Thread: created.Thread, Body: MessageBody{Text: "third"}})
	if snapshot := h.snapshot(created.Thread); len(snapshot.Queue) != 2 || snapshot.Queue[0].Text != "second" {
		t.Fatalf("queue = %#v, want second then third waiting", snapshot.Queue)
	}
	close(release)
	h.settledTurns(created.Thread, 3)
	var sent []string
	for _, message := range claude.messages() {
		sent = append(sent, message.in.Text)
	}
	if !slices.Equal(sent, []string{"first", "second", "third"}) {
		t.Fatalf("sent %v, want each once in order", sent)
	}
}

// A steer joins the running turn where the provider can steer.
func TestSteerJoinsTheRunningTurn(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	release := make(chan struct{})
	claude.onSend = func(f *fakeInstance, session string, in provider.SendInput) (provider.SendAck, error) {
		if in.Steer {
			return provider.SendAck{Turn: "turn-1"}, nil
		}
		f.startTurn(session, "turn-1", in)
		go func() {
			<-release
			f.settle(session, "turn-1", provider.TurnCompleted)
		}()
		return provider.SendAck{Turn: "turn-1"}, nil
	}
	h := newHarness(t, claude)
	created := h.createThread("claude", "work")
	h.eventually("the turn to start", func() bool { return len(claude.messages()) == 1 })
	steer := h.do(Deliver{Thread: created.Thread, Body: MessageBody{Text: "also this"}, Mode: ModeSteer})
	h.eventually("the steer to arrive", func() bool { return len(claude.messages()) == 2 })
	if message := claude.messages()[1]; !message.in.Steer || message.in.Text != "also this" {
		t.Fatalf("steer = %#v", message)
	}
	close(release)
	snapshot := h.settledTurns(created.Thread, 1)
	if len(snapshot.Turns) != 1 {
		t.Fatalf("turns = %#v, want the steer in the one turn", snapshot.Turns)
	}
	delivered, ok, err := h.engine.db.delivery(context.Background(), steer.Delivery)
	if err != nil || !ok || delivered.State != DeliveryDelivered || delivered.Turn != snapshot.Turns[0].ID {
		t.Fatalf("steer delivery = %#v, %v, %v; want delivered into the turn", delivered, ok, err)
	}
}

// A person's steer to an agent that can't steer stops its turn and goes
// next, as Zed sends over an ACP agent's turn; nothing is held.
func TestASteerAnAgentCantTakeStopsTheTurnAndGoesNext(t *testing.T) {
	acp := newFakeInstance("acp", "ACP")
	acp.info.Capabilities.Steer = false
	acp.onSend = func(f *fakeInstance, session string, in provider.SendInput) (provider.SendAck, error) {
		if lastLine(in.Text) == "long task" {
			f.startTurn(session, in.Delivery, in)
			return provider.SendAck{Turn: in.Delivery}, nil
		}
		return f.answer(session, in, "answer to "+lastLine(in.Text))
	}
	h := newHarness(t, acp)
	created := h.createThread("acp", "long task")
	h.eventually("the turn to start", func() bool { return len(acp.messages()) == 1 })
	h.do(Deliver{Thread: created.Thread, Body: MessageBody{Text: "do this instead"}, Mode: ModeSteer})
	snapshot := h.settledTurns(created.Thread, 2)
	if states := []provider.TurnState{snapshot.Turns[0].State, snapshot.Turns[1].State}; !slices.Equal(states, []provider.TurnState{provider.TurnInterrupted, provider.TurnCompleted}) {
		t.Fatalf("turn states = %v, want the long task stopped and the steer answered", states)
	}
	if messages := acp.messages(); len(messages) != 2 || messages[1].in.Steer || lastLine(messages[1].in.Text) != "do this instead" {
		t.Fatalf("messages = %#v, want the steer sent as the next turn", messages)
	}
	if thread := h.snapshot(created.Thread).Thread; thread.Hold != HoldNone {
		t.Fatalf("hold = %q, want none", thread.Hold)
	}
}

// A chat opens from the cache after a restart with its provider offline.
func TestChatOpensFromCacheWithProviderOffline(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	h := newHarness(t, claude)
	created := h.createThread("claude", "remember this")
	h.settledTurns(created.Thread, 1)
	h.providers.unavailable["claude"] = true
	h.restart()
	snapshot := h.snapshot(created.Thread)
	if len(snapshot.Turns) != 1 || joined(texts(snapshot.Turns[0])) != "user_message: remember this | assistant_message: answer to remember this" {
		t.Fatalf("turns after restart = %#v", snapshot.Turns)
	}
}

// A chat whose newest turn alone is over the snapshot's entry budget opens on
// that turn, the older ones a page away.
func TestChatOpensOnATurnLargerThanTheSnapshotBudget(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	h := newHarness(t, claude)
	created := h.createThread("claude", "small")
	h.settledTurns(created.Thread, 1)
	claude.onSend = func(f *fakeInstance, session string, in provider.SendInput) (provider.SendAck, error) {
		f.startTurn(session, in.Delivery, in)
		go func() {
			for index := range snapshotEntries {
				f.entry(session, provider.Entry{Ref: fmt.Sprintf("%s/%d", in.Delivery, index), Turn: in.Delivery, Kind: provider.ItemKindAssistantMessage, Status: provider.ItemStatusCompleted, Text: "line"})
			}
			f.settle(session, in.Delivery, provider.TurnCompleted)
		}()
		return provider.SendAck{Turn: in.Delivery}, nil
	}
	large := h.do(Deliver{Thread: created.Thread, Body: MessageBody{Text: "large"}})
	h.eventually("the large turn to settle", func() bool {
		turns := h.snapshot(created.Thread).Turns
		latest := turns[len(turns)-1]
		return latest.ID != "" && slices.ContainsFunc(latest.Entries, func(entry EntryView) bool { return entry.Delivery == string(large.Delivery) }) && latest.State.Settled()
	})
	h.restart()
	snapshot := h.snapshot(created.Thread)
	if len(snapshot.Turns) != 1 || len(snapshot.Turns[0].Entries) != snapshotEntries+1 || snapshot.Older != snapshot.Turns[0].ID {
		t.Fatalf("snapshot = %d turns, older %q; want the large turn whole with the small one before it", len(snapshot.Turns), snapshot.Older)
	}
	older, _, err := h.engine.Turns(context.Background(), created.Thread, snapshot.Older, 0)
	if err != nil || len(older) != 1 || joined(texts(older[0])) != "user_message: small | assistant_message: answer to small" {
		t.Fatalf("older page = %#v, %v", older, err)
	}
}

// A delivery sending when the daemon died is delivered exactly once: one the
// session took is recorded delivered, one it didn't goes again.
func TestSendingDeliveriesConvergeAfterACrash(t *testing.T) {
	for _, tc := range []struct {
		name  string
		taken bool
	}{{"taken", true}, {"lost", false}} {
		t.Run(tc.name, func(t *testing.T) {
			claude := newFakeInstance("claude", "Claude")
			taken := tc.taken
			crashed := make(chan struct{})
			var once bool
			claude.onSend = func(f *fakeInstance, session string, in provider.SendInput) (provider.SendAck, error) {
				if !once {
					once = true
					if taken {
						f.mu.Lock()
						f.sessions[session].delivered[in.Delivery] = true
						f.sessions[session].turns = append(f.sessions[session].turns, provider.HistoryTurn{Ref: in.Delivery, State: provider.TurnRunning,
							Entries: provider.UserMessageEntries(in.Delivery+"/user", in.Delivery, in.Text, nil, in.Delivery, time.Time{})})
						f.mu.Unlock()
					}
					close(crashed)
					// The daemon dies before the acknowledgement.
					select {}
				}
				return f.answer(session, in, "answer to "+lastLine(in.Text))
			}
			h := newHarness(t, claude)
			created := h.createThread("claude", "do it once")
			<-crashed
			h.restart()
			if taken {
				h.eventually("the delivery to be recorded delivered", func() bool {
					delivery, ok, _ := h.engine.db.delivery(context.Background(), created.Delivery)
					return ok && delivery.State == DeliveryDelivered
				})
				snapshot := h.snapshot(created.Thread)
				h.eventually("the turn to settle from history", func() bool {
					snapshot = h.snapshot(created.Thread)
					return len(snapshot.Turns) == 1 && snapshot.Turns[0].State.Settled()
				})
				if len(claude.messages()) != 1 {
					t.Fatalf("provider got %d messages, want 1", len(claude.messages()))
				}
				return
			}
			h.settledTurns(created.Thread, 1)
			if messages := claude.messages(); len(messages) != 2 || messages[1].in.Delivery != string(created.Delivery) {
				t.Fatalf("messages = %#v, want the lost delivery sent again once", messages)
			}
		})
	}
}

// The engine never waits on a provider: with one provider's Open blocked, a
// turn on another runs to the end.
func TestEngineNeverWaitsOnAProvider(t *testing.T) {
	slow, fast := newFakeInstance("slow", "Slow"), newFakeInstance("fast", "Fast")
	slow.openGate = make(chan struct{})
	h := newHarness(t, slow, fast)
	h.createThread("slow", "takes forever")
	other := h.createThread("fast", "quick")
	h.settledTurns(other.Thread, 1)
	close(slow.openGate)
}

// A spawned child's result comes back to its parent exactly once: as a new
// turn when the parent is idle.
func TestSpawnedChildRepliesToItsParent(t *testing.T) {
	claude, codex := newFakeInstance("claude", "Claude"), newFakeInstance("codex", "Codex")
	h := newHarness(t, claude, codex)
	parent := h.createThread("claude", "plan the work")
	h.settledTurns(parent.Thread, 1)
	agent := Agent(parent.Thread, parent.Participant)
	spawned, err := h.doAs(agent, Spawn{Parent: parent.Thread, Brief: "Fix the login bug", Agent: NewParticipant{Instance: "codex"}})
	if err != nil {
		t.Fatalf("Spawn: %v", err)
	}
	child := h.settledTurns(spawned.Thread, 1)
	if child.Thread.Origin.Kind != OriginSpawn || child.Thread.Origin.Parent != parent.Thread {
		t.Fatalf("child origin = %#v", child.Thread.Origin)
	}
	if got := joined(texts(child.Turns[0])); !strings.Contains(got, "envelope message: Fix the login bug") {
		t.Fatalf("child turn = %s, want the brief as a message", got)
	}
	snapshot := h.settledTurns(parent.Thread, 2)
	wake := snapshot.Turns[1]
	if got := joined(texts(wake)); !strings.Contains(got, "envelope reply: answer to Fix the login bug") {
		t.Fatalf("parent's wake = %s, want the child's answer as a reply", got)
	}
	h.rerunRules(spawned.Thread)
	if again := h.snapshot(parent.Thread); len(again.Turns) != 2 || len(again.Queue) != 0 {
		t.Fatalf("parent has %d turns and %d queued, want the reply once", len(again.Turns), len(again.Queue))
	}
}

// A wait that returns the child's answer takes it: no wake follows.
func TestWaitTakesTheReply(t *testing.T) {
	claude, codex := newFakeInstance("claude", "Claude"), newFakeInstance("codex", "Codex")
	// The child waits for the parent's wait: an answer that comes first goes to
	// the running parent as a steer, leaving the wait nothing to take.
	codex.openGate = make(chan struct{})
	parentRelease := make(chan struct{})
	claude.onSend = func(f *fakeInstance, session string, in provider.SendInput) (provider.SendAck, error) {
		f.startTurn(session, in.Delivery, in)
		go func() {
			<-parentRelease
			f.settle(session, in.Delivery, provider.TurnCompleted)
		}()
		return provider.SendAck{Turn: in.Delivery}, nil
	}
	h := newHarness(t, claude, codex)
	parent := h.createThread("claude", "delegate and wait")
	h.eventually("the parent's turn to run", func() bool { return len(claude.messages()) == 1 })
	agent := Agent(parent.Thread, parent.Participant)
	spawned, err := h.doAs(agent, Spawn{Parent: parent.Thread, Brief: "Count the files", Agent: NewParticipant{Instance: "codex"}})
	if err != nil {
		t.Fatalf("Spawn: %v", err)
	}
	var result WaitResult
	waited := make(chan struct{})
	go func() {
		defer close(waited)
		result, err = h.engine.Wait(context.Background(), agent, []ThreadID{spawned.Thread}, false, 5*time.Second)
	}()
	h.eventually("the parent's wait", func() bool {
		waiting, err := call(context.Background(), h.engine, func(*step) (bool, error) { return h.engine.waiting(parent.Thread), nil })
		return err == nil && waiting
	})
	close(codex.openGate)
	<-waited
	if err != nil || result.TimedOut || len(result.Threads) != 1 || result.Threads[0].Reply == nil || result.Threads[0].Reply.Text != "answer to Count the files" {
		t.Fatalf("wait = %#v, %v; want the child's answer", result, err)
	}
	close(parentRelease)
	h.settledTurns(parent.Thread, 1)
	h.rerunRules(spawned.Thread)
	if again := h.snapshot(parent.Thread); len(again.Turns) != 1 || len(again.Queue) != 0 || len(claude.messages()) != 1 {
		t.Fatalf("parent turns = %d, messages = %d; want no wake after the wait took the reply (%#v)", len(again.Turns), len(claude.messages()), again.Queue)
	}
}

// A turn cut off by a restart holds what was queued behind it, as a failure
// does: the person decides whether it still goes.
func TestATurnCutOffByARestartHoldsTheQueue(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	claude.onSend = func(f *fakeInstance, session string, in provider.SendInput) (provider.SendAck, error) {
		f.startTurn(session, in.Delivery, in)
		if !strings.Contains(in.Text, "first") {
			go f.settle(session, in.Delivery, provider.TurnCompleted)
		}
		return provider.SendAck{Turn: in.Delivery}, nil
	}
	h := newHarness(t, claude)
	created := h.createThread("claude", "first")
	h.eventually("the first turn to start", func() bool { return len(claude.messages()) == 1 })
	h.do(Deliver{Thread: created.Thread, Body: MessageBody{Text: "second"}})
	h.restart()
	snapshot := h.snapshot(created.Thread)
	if snapshot.Thread.Hold != HoldFailed || snapshot.Turns[0].State != provider.TurnInterrupted || len(claude.messages()) != 1 {
		t.Fatalf("after the restart hold = %q, first turn %s, %d sent; want held, interrupted, only the first", snapshot.Thread.Hold, snapshot.Turns[0].State, len(claude.messages()))
	}
	h.do(Continue{Thread: created.Thread})
	h.settledTurns(created.Thread, 2)
	if got := claude.messages()[1].in.Text; got != "second" {
		t.Fatalf("after Continue the agent got %q", got)
	}
}

// A message that wasn't delivered holds the ones behind it, so they never
// overtake it; Retry sends it first.
func TestARefusedMessageHoldsTheQueue(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	release := make(chan struct{})
	var rejected atomic.Bool
	claude.onSend = func(f *fakeInstance, session string, in provider.SendInput) (provider.SendAck, error) {
		if in.Text == "bad" && rejected.CompareAndSwap(false, true) {
			<-release
			return provider.SendAck{}, errors.New("the agent rejected it")
		}
		return f.answer(session, in, "answer to "+lastLine(in.Text))
	}
	h := newHarness(t, claude)
	created := h.createThread("claude", "first")
	h.settledTurns(created.Thread, 1)
	bad := h.do(Deliver{Thread: created.Thread, Body: MessageBody{Text: "bad"}}).Delivery
	h.do(Deliver{Thread: created.Thread, Body: MessageBody{Text: "after"}})
	close(release)
	h.eventually("the refusal", func() bool {
		snapshot := h.snapshot(created.Thread)
		return len(snapshot.Queue) == 2 && snapshot.Queue[0].State == DeliveryRefused
	})
	if snapshot := h.snapshot(created.Thread); snapshot.Thread.Hold != HoldFailed || len(claude.messages()) != 2 {
		t.Fatalf("hold = %q with %d sent, want the queue held behind the refusal", snapshot.Thread.Hold, len(claude.messages()))
	}
	h.do(RetryDelivery{Delivery: bad})
	h.settledTurns(created.Thread, 3)
	var sent []string
	for _, message := range claude.messages() {
		sent = append(sent, message.in.Text)
	}
	if !slices.Equal(sent, []string{"first", "bad", "bad", "after"}) {
		t.Fatalf("sent %q, want the refused message again before the next", sent)
	}
}

// A spawned agent whose brief can't be delivered shows its parent a held
// child, not an idle one, so the parent's wait sees it needs someone.
func TestAChildWhoseBriefWasRefusedIsHeld(t *testing.T) {
	claude, broken := newFakeInstance("claude", "Claude"), newFakeInstance("broken", "Broken")
	broken.onSend = func(*fakeInstance, string, provider.SendInput) (provider.SendAck, error) {
		return provider.SendAck{}, errors.New("the agent is signed out")
	}
	h := newHarness(t, claude, broken)
	parent := h.createThread("claude", "Orchestrate")
	h.settledTurns(parent.Thread, 1)
	child, err := h.doAs(Agent(parent.Thread, parent.Participant), Spawn{Parent: parent.Thread, Brief: "do it", Agent: NewParticipant{Instance: "broken"}})
	if err != nil {
		t.Fatal(err)
	}
	h.eventually("the refused brief", func() bool {
		snapshot := h.snapshot(child.Thread)
		return len(snapshot.Queue) == 1 && snapshot.Queue[0].State == DeliveryRefused
	})
	if summary := h.snapshot(child.Thread).Thread; summary.Status != StatusHeld || !summary.Attention.NeedsInput {
		t.Fatalf("child status %q, needs input %v; want held, needing someone", summary.Status, summary.Attention.NeedsInput)
	}
}

// A chat is titled by its first message until its provider names it; after
// that, the last name given wins, the person's or the provider's.
func TestTheLastNameGivenWins(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	h := newHarness(t, claude)
	chat := h.createThread("claude", "Fix the flaky login test")
	h.settledTurns(chat.Thread, 1)
	title := func() string { return h.snapshot(chat.Thread).Thread.Title }
	if got := title(); got != "Fix the flaky login test" {
		t.Fatalf("title before the provider names it = %q", got)
	}
	claude.send("claude-session-1", provider.TitleChanged{Title: "Login test flake"})
	h.eventually("the provider's name", func() bool { return title() == "Login test flake" })
	renamed := "Auth flake"
	h.do(UpdateThread{Thread: chat.Thread, Title: &renamed})
	if got := title(); got != renamed {
		t.Fatalf("title after a rename = %q", got)
	}
	claude.send("claude-session-1", provider.TitleChanged{Title: "Renamed in the CLI"})
	h.eventually("the CLI's later name", func() bool { return title() == "Renamed in the CLI" })
}

// Nothing runs once its session's process is gone. A tool still running ends
// interrupted when its session closes or maiD restarts: one a settled turn
// left running (a background task) as one of a turn cut off, though the
// session's own record still has both running.
func TestEntriesInProgressEndWithTheirSession(t *testing.T) {
	for _, restart := range []bool{false, true} {
		t.Run(map[bool]string{false: "closed", true: "restart"}[restart], func(t *testing.T) {
			claude := newFakeInstance("claude", "Claude")
			h := newHarness(t, claude)
			chat := h.createThread("claude", "one")
			h.settledTurns(chat.Thread, 1)
			first := claude.messages()[0]
			tool := func(turn string) provider.Entry {
				return provider.Entry{Ref: turn + "/tool/t1", Turn: turn, Kind: provider.ItemKindToolCall, Status: provider.ItemStatusInProgress}
			}
			claude.entry(first.session, tool(first.in.Delivery))
			claude.onSend = func(f *fakeInstance, session string, in provider.SendInput) (provider.SendAck, error) {
				f.startTurn(session, in.Delivery, in)
				go f.entry(session, tool(in.Delivery))
				return provider.SendAck{Turn: in.Delivery}, nil
			}
			h.do(Deliver{Thread: chat.Thread, Body: MessageBody{Text: "two"}})
			statuses := func() []provider.ItemStatus {
				var out []provider.ItemStatus
				for _, turn := range h.snapshot(chat.Thread).Turns {
					for _, entry := range turn.Entries {
						if entry.Kind == provider.ItemKindToolCall {
							out = append(out, entry.Status)
						}
					}
				}
				return out
			}
			running := []provider.ItemStatus{provider.ItemStatusInProgress, provider.ItemStatusInProgress}
			h.eventually("both tools to run", func() bool { return slices.Equal(statuses(), running) })
			if restart {
				h.restart()
			} else {
				claude.send(first.session, provider.SessionClosed{})
			}
			stopped := []provider.ItemStatus{provider.ItemStatusInterrupted, provider.ItemStatusInterrupted}
			h.eventually("both tools to end interrupted", func() bool { return slices.Equal(statuses(), stopped) })
		})
	}
}

// A session delete its provider can't do is refused before the chat on the
// session is touched: it keeps its live session, with the turn it runs.
func TestASessionDeleteTheProviderCantDoLeavesItsChatRunning(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	claude.onSend = func(f *fakeInstance, session string, in provider.SendInput) (provider.SendAck, error) {
		f.startTurn(session, in.Delivery, in)
		return provider.SendAck{Turn: in.Delivery}, nil
	}
	h := newHarness(t, claude)
	chat := h.createThread("claude", "Work")
	h.eventually("the turn to start", func() bool { return len(claude.messages()) == 1 })
	if err := h.engine.DeleteSession(context.Background(), h.device, "claude", claude.messages()[0].session); !errors.Is(err, provider.ErrUnsupported) {
		t.Fatalf("delete = %v, want unsupported", err)
	}
	snapshot := h.snapshot(chat.Thread)
	if len(snapshot.Turns) != 1 || snapshot.Turns[0].State != provider.TurnRunning || !snapshot.Participants[0].Live {
		t.Fatalf("after the refused delete: turns = %#v, live = %v; want the turn running on a live session", snapshot.Turns, snapshot.Participants[0].Live)
	}
}

// A chat deleted while its session opens leaves nothing live at the provider:
// the session is released as its Open returns.
func TestAChatDeletedWhileItsSessionOpensReleasesIt(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	claude.openGate = make(chan struct{})
	h := newHarness(t, claude)
	chat := h.createThread("claude", "Work")
	h.do(DeleteThread{Thread: chat.Thread})
	close(claude.openGate)
	h.eventually("the opened session to be released", func() bool {
		claude.mu.Lock()
		defer claude.mu.Unlock()
		return claude.opened == 1 && len(claude.released) == 1 && len(claude.live) == 0
	})
}

// Deleting the session of one agent of a chat deletes the chat, every agent's
// part of it: the session is released before it is deleted, and the other
// agents' sessions are released and stay with their providers.
func TestDeletingASessionDeletesTheWholeChatOnIt(t *testing.T) {
	claude, codex := newFakeInstance("claude", "Claude"), newFakeInstance("codex", "Codex")
	claude.info.Capabilities.Delete = true
	h := newHarness(t, claude, codex)
	chat := h.createThread("claude", "Plan the cache")
	h.settledTurns(chat.Thread, 1)
	h.do(AddParticipant{Thread: chat.Thread, NewParticipant: NewParticipant{Instance: "codex"}})
	h.do(Deliver{Thread: chat.Thread, Body: MessageBody{Text: "Implement it"}})
	h.settledTurns(chat.Thread, 2)
	session, other := claude.messages()[0].session, codex.messages()[0].session

	if err := h.engine.DeleteSession(context.Background(), h.device, "claude", session); err != nil {
		t.Fatal(err)
	}
	if list, err := h.sub.List(context.Background()); err != nil || len(list.Threads) != 0 {
		t.Fatalf("chats after the delete = %#v, %v; want none", list.Threads, err)
	}
	claude.mu.Lock()
	released, deleted, deletedLive := slices.Clone(claude.released), slices.Clone(claude.deleted), slices.Clone(claude.deletedLive)
	claude.mu.Unlock()
	if !slices.Equal(released, []string{session}) || !slices.Equal(deleted, []string{session}) || len(deletedLive) != 0 {
		t.Fatalf("claude: released %v, deleted %v (live as deleted: %v); want %s released, then deleted", released, deleted, deletedLive, session)
	}
	h.eventually("the other agent's session to be released", func() bool {
		codex.mu.Lock()
		defer codex.mu.Unlock()
		return slices.Equal(codex.released, []string{other})
	})
	codex.mu.Lock()
	kept := codex.sessions[other] != nil && len(codex.deleted) == 0
	codex.mu.Unlock()
	if !kept {
		t.Fatal("the other agent's session was deleted too")
	}
}

// Two deletes of one session at once both succeed: the second finds the
// session gone, which providers answer with success.
func TestDeletingASessionTwiceAtOnceSucceedsBoth(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	claude.info.Capabilities.Delete = true
	h := newHarness(t, claude)
	chat := h.createThread("claude", "Work")
	h.settledTurns(chat.Thread, 1)
	session := claude.messages()[0].session

	results := make(chan error, 2)
	for range 2 {
		go func() { results <- h.engine.DeleteSession(context.Background(), h.device, "claude", session) }()
	}
	for range 2 {
		if err := <-results; err != nil {
			t.Fatal(err)
		}
	}
	if list, err := h.sub.List(context.Background()); err != nil || len(list.Threads) != 0 {
		t.Fatalf("chats after the deletes = %#v, %v; want none", list.Threads, err)
	}
}

// A provider's delete that fails is the caller's answer. The chat is gone by
// then; the session is still the provider's.
func TestAFailedSessionDeleteIsReportedAfterItsChatIsDeleted(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	claude.info.Capabilities.Delete = true
	claude.deleteErr = errors.New("disk is read-only")
	h := newHarness(t, claude)
	chat := h.createThread("claude", "Work")
	h.settledTurns(chat.Thread, 1)
	session := claude.messages()[0].session

	if err := h.engine.DeleteSession(context.Background(), h.device, "claude", session); !errors.Is(err, claude.deleteErr) {
		t.Fatalf("delete = %v, want the provider's error", err)
	}
	if list, err := h.sub.List(context.Background()); err != nil || len(list.Threads) != 0 {
		t.Fatalf("chats after the delete = %#v, %v; want none", list.Threads, err)
	}
	claude.mu.Lock()
	defer claude.mu.Unlock()
	if claude.sessions[session] == nil {
		t.Fatal("the session is gone though its delete failed")
	}
}

// A turn a provider starts on its own and settles at once (an ACP agent's
// follow-up) still takes streamed text: it shows as it streams, and is
// written to the cache.
func TestTextStreamsOntoASettledTurn(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	h := newHarness(t, claude)
	chat := h.createThread("claude", "one")
	h.settledTurns(chat.Thread, 1)
	session := claude.messages()[0].session
	claude.send(session, provider.TurnStarted{Turn: "found-1", By: provider.TurnByProvider})
	claude.send(session, provider.TurnSettled{Turn: "found-1", State: provider.TurnCompleted})
	// The message and its first text in one step, as replayed orphans are:
	// the text reaches the message not yet written.
	h.providers.mu.Lock()
	generation := h.providers.generation
	h.providers.mu.Unlock()
	h.engine.post(func(s *step) {
		h.engine.providerEvent(s, "claude", generation, provider.Event{Session: session, Body: provider.EntryUpserted{Entry: provider.Entry{Ref: "found-1/m1", Turn: "found-1", Kind: provider.ItemKindAssistantMessage, Status: provider.ItemStatusCompleted, Text: "The build"}}})
		h.engine.providerEvent(s, "claude", generation, provider.Event{Session: session, Body: provider.TextAppended{Entry: "found-1/m1", Turn: "found-1", Stream: provider.StreamAssistant, Text: " finished"}})
	})
	claude.send(session, provider.TextAppended{Entry: "found-1/m1", Turn: "found-1", Stream: provider.StreamAssistant, Text: "."})
	text := func() string {
		turns := h.snapshot(chat.Thread).Turns
		return joined(texts(turns[len(turns)-1]))
	}
	h.eventually("the streamed text to show", func() bool { return text() == "assistant_message: The build finished." })
	h.eventually("the text to be written", func() bool {
		entries, err := h.engine.db.turnEntries(context.Background(), "claude", session, "found-1")
		return err == nil && len(entries) == 1 && entries[0].Text == "The build finished."
	})
}

// Text keeps reaching a turn an agent started on its own after a later turn
// overtook it.
func TestTextStreamsOntoAnOvertakenTurn(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	h := newHarness(t, claude)
	chat := h.createThread("claude", "one")
	h.settledTurns(chat.Thread, 1)
	session := claude.messages()[0].session
	claude.send(session, provider.TurnStarted{Turn: "found-1", By: provider.TurnByProvider})
	claude.send(session, provider.TurnSettled{Turn: "found-1", State: provider.TurnCompleted})
	claude.send(session, provider.EntryUpserted{Entry: provider.Entry{Ref: "found-1/m1", Turn: "found-1", Kind: provider.ItemKindAssistantMessage, Status: provider.ItemStatusCompleted, Text: "The build"}})
	h.do(Deliver{Thread: chat.Thread, Body: MessageBody{Text: "two"}})
	h.settledTurns(chat.Thread, 3)
	claude.send(session, provider.TextAppended{Entry: "found-1/m1", Turn: "found-1", Stream: provider.StreamAssistant, Text: " finished."})
	h.eventually("the text to be written", func() bool {
		entries, err := h.engine.db.turnEntries(context.Background(), "claude", session, "found-1")
		return err == nil && len(entries) == 1 && entries[0].Text == "The build finished."
	})
	if got := joined(texts(h.snapshot(chat.Thread).Turns[1])); got != "assistant_message: The build finished." {
		t.Fatalf("overtaken turn = %s", got)
	}
}
