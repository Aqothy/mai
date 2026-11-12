package orchestration

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// kept is what the engine keeps of a native session: whether it has a row
// for it, its cached entries, and its mirrored frames.
func (h *harness) kept(instance provider.InstanceID, session string) (row bool, entries, frames int) {
	h.t.Helper()
	mirrored, err := h.engine.Mirror(instance).Load(context.Background(), session)
	if err != nil {
		h.t.Fatal(err)
	}
	var rows int
	if err := h.engine.db.sql.QueryRow(`SELECT COUNT(*) FROM sessions WHERE instance_id = ? AND native_session = ?`, string(instance), session).Scan(&rows); err != nil {
		h.t.Fatal(err)
	}
	if err := h.engine.db.sql.QueryRow(`SELECT COUNT(*) FROM session_entries WHERE instance_id = ? AND native_session = ?`, string(instance), session).Scan(&entries); err != nil {
		h.t.Fatal(err)
	}
	return rows == 1, entries, len(mirrored)
}

var testFrame = []json.RawMessage{json.RawMessage(`{"frame":1}`)}

// moveOn has the chat's agent leave its session for a new one, which it
// returns: the provider can't resume the session for the chat's next message,
// whose turn runs in a new one. The provider has the session again after.
func moveOn(h *harness, agent *fakeInstance, chat CommandResult, from string) string {
	h.t.Helper()
	turns := len(h.snapshot(chat.Thread).Turns)
	// Kept under another name meanwhile: the fake numbers a new session by
	// how many it has.
	const aside = "set aside"
	agent.mu.Lock()
	agent.sessions[aside] = agent.sessions[from]
	delete(agent.sessions, from)
	delete(agent.live, from)
	agent.mu.Unlock()
	agent.send(from, provider.SessionClosed{})
	h.do(Deliver{Thread: chat.Thread, Body: MessageBody{Text: "go on"}})
	h.settledTurns(chat.Thread, turns+1)
	agent.mu.Lock()
	defer agent.mu.Unlock()
	agent.sessions[from] = agent.sessions[aside]
	delete(agent.sessions, aside)
	received := agent.received[len(agent.received)-1]
	if received.session == from {
		h.t.Fatalf("the message went to session %q, want a new one", from)
	}
	return received.session
}

// engineRead reads engine state as a step.
func engineRead[T any](h *harness, read func() T) T {
	h.t.Helper()
	value, err := call(context.Background(), h.engine, func(*step) (T, error) { return read(), nil })
	if err != nil {
		h.t.Fatal(err)
	}
	return value
}

func importSession(h *harness, instance provider.InstanceID, session string) CreateThread {
	return CreateThread{Workspace: provider.Workspace{Cwd: h.dir}, Participant: NewParticipant{Instance: instance}, Session: session}
}

// Deleting a chat deletes what was kept of every session it was on: also of
// one its agent left, whose turns the chat showed until then.
func TestDeletingAChatDeletesEverySessionItWasOn(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	h := newHarness(t, claude)
	chat := h.createThread("claude", "one")
	h.settledTurns(chat.Thread, 1)
	first := claude.messages()[0].session
	h.engine.Mirror("claude").Append(first, testFrame)
	second := moveOn(h, claude, chat, first)
	for _, session := range []string{first, second} {
		if row, entries, _ := h.kept("claude", session); !row || entries == 0 {
			t.Fatalf("before the delete, session %q: row %v, %d entries; want the chat's turns in it kept", session, row, entries)
		}
	}
	if _, _, frames := h.kept("claude", first); frames != 1 {
		t.Fatalf("before the delete, the left session has %d frames, want the one mirrored", frames)
	}

	h.do(DeleteThread{Thread: chat.Thread})
	for _, session := range []string{first, second} {
		if row, entries, frames := h.kept("claude", session); row || entries != 0 || frames != 0 {
			t.Fatalf("after the delete, session %q: row %v, %d entries, %d frames; want nothing kept", session, row, entries, frames)
		}
	}
}

// A native session is in one chat. Importing one a chat's agent is on, or one
// it left (whose turns the chat still shows), is refused; it can be imported
// once that chat is deleted.
func TestImportingASessionOfAChatIsRefused(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	h := newHarness(t, claude)
	chat := h.createThread("claude", "one")
	h.settledTurns(chat.Thread, 1)
	first := claude.messages()[0].session
	second := moveOn(h, claude, chat, first)

	for name, session := range map[string]string{"the session the chat is on": second, "the session the chat left": first} {
		var refusal *CommandError
		if _, err := h.doAs(h.device, importSession(h, "claude", session)); !errors.As(err, &refusal) || refusal.Code != CodeInvalid {
			t.Errorf("importing %s: %v, want it refused as invalid", name, err)
		}
	}
	if threads := engineRead(h, func() int { return len(h.engine.threads) }); threads != 1 {
		t.Fatalf("%d chats after the refused imports, want the one", threads)
	}
	h.do(DeleteThread{Thread: chat.Thread})
	again := h.do(importSession(h, "claude", first))
	if turns := h.settledTurns(again.Thread, 1).Turns; len(turns) != 1 || len(turns[0].Entries) == 0 {
		t.Fatalf("the imported chat's turns = %#v, want the session's one turn, read from the provider", turns)
	}
}

// An import reads the session before the chat first opens it: a live
// session's record is what runs in maiD, so what it held before would never
// show in a chat that got a message before anyone looked at it.
func TestAnImportedChatMessagedBeforeItWasReadShowsTheSessionsTurns(t *testing.T) {
	agent := newFakeInstance("agent", "Agent")
	h := newHarness(t, agent)
	chat := h.createThread("agent", "one")
	h.settledTurns(chat.Thread, 1)
	session := agent.messages()[0].session
	h.do(DeleteThread{Thread: chat.Thread})

	imported := h.do(importSession(h, "agent", session))
	h.do(Deliver{Thread: imported.Thread, Body: MessageBody{Text: "two"}})
	h.eventually("the agent's answer", func() bool {
		agent.mu.Lock()
		defer agent.mu.Unlock()
		return len(agent.sessions[session].turns) == 2
	})
	var shown []string
	for _, turn := range h.settledTurns(imported.Thread, 2).Turns {
		for _, entry := range turn.Entries {
			if entry.Kind == provider.ItemKindUserMessage {
				shown = append(shown, entry.Text)
			}
		}
	}
	if !slices.Equal(shown, []string{"one", "two"}) {
		t.Fatalf("the imported chat shows the messages %q, want the session's earlier one and the new one", shown)
	}
}

// An import is the session as it is: a message is sent to the chat it made.
func TestAnImportTakesNoMessage(t *testing.T) {
	agent := newFakeInstance("agent", "Agent")
	h := newHarness(t, agent)
	chat := h.createThread("agent", "one")
	h.settledTurns(chat.Thread, 1)
	session := agent.messages()[0].session
	h.do(DeleteThread{Thread: chat.Thread})

	create := importSession(h, "agent", session)
	create.Prompt = &MessageBody{Text: "two"}
	var refusal *CommandError
	if _, err := h.doAs(h.device, create); !errors.As(err, &refusal) || refusal.Code != CodeInvalid {
		t.Fatalf("importing with a message: %v, want it refused as invalid", err)
	}
	if threads := engineRead(h, func() int { return len(h.engine.threads) }); threads != 0 {
		t.Fatalf("%d chats after the refused import, want none", threads)
	}
}

// A chat deleted while its agent is slow has calls for its session still to
// run: the Send that hasn't returned, and the Release behind it. An import of
// the session meanwhile opens it after them, not before a Release that would
// close what the import opened.
func TestAnImportFollowsTheCallsOfTheSessionsDeletedChat(t *testing.T) {
	agent := newFakeInstance("agent", "Agent")
	h := newHarness(t, agent)
	chat := h.createThread("agent", "one")
	h.settledTurns(chat.Thread, 1)
	session := agent.messages()[0].session

	held, letGo := make(chan struct{}), make(chan struct{})
	agent.mu.Lock()
	agent.onSend = func(f *fakeInstance, session string, in provider.SendInput) (provider.SendAck, error) {
		if lastLine(in.Text) == "slow" {
			close(held)
			<-letGo
			return provider.SendAck{}, errors.New("cancelled")
		}
		// As the adapters do (acp/turn.go, codexapp/session.go).
		f.mu.Lock()
		live := f.live[session]
		f.mu.Unlock()
		if !live {
			return provider.SendAck{}, errors.New("session " + session + " is not open")
		}
		return f.answer(session, in, "answer to "+lastLine(in.Text))
	}
	agent.mu.Unlock()
	h.do(Deliver{Thread: chat.Thread, Body: MessageBody{Text: "slow"}})
	<-held
	h.do(DeleteThread{Thread: chat.Thread})

	imported := h.do(importSession(h, "agent", session))
	h.do(Deliver{Thread: imported.Thread, Body: MessageBody{Text: "two"}})
	// An Open that doesn't wait for the deleted chat's calls runs at once.
	for range 20 {
		agent.mu.Lock()
		opened := agent.opened
		agent.mu.Unlock()
		if opened != 1 {
			t.Fatal("the import opened the session while the deleted chat's calls for it were still to run")
		}
		time.Sleep(5 * time.Millisecond)
	}
	close(letGo)
	h.eventually("the second message to be answered", func() bool {
		snapshot := h.snapshot(imported.Thread)
		for _, delivery := range snapshot.Queue {
			if delivery.State == DeliveryRefused {
				t.Fatalf("the imported chat's message was refused: %s", delivery.Reason)
			}
		}
		answered := 0
		for _, turn := range snapshot.Turns {
			if turn.State.Settled() {
				answered++
			}
		}
		return answered >= 2
	})
	agent.mu.Lock()
	released, live := len(agent.released), agent.live[session]
	agent.mu.Unlock()
	if released != 1 || !live {
		t.Fatalf("the session was released %d times and is live: %v; want the deleted chat's one release, then the import's open", released, live)
	}
	h.eventually("the worker to be the imported chat's alone", func() bool {
		return engineRead(h, func() int { return len(h.engine.closing) }) == 0
	})
}

// A new session's first frames can reach the mirror before the engine hears
// of the session: they are kept, and are its chat's once it has one. What
// was mirrored of a session no chat took goes when the agent's opens end, or
// with the daemon.
func TestFramesOfANewSessionAreKeptForItsChat(t *testing.T) {
	agent := newFakeInstance("agent", "Agent")
	agent.openGate = make(chan struct{})
	h := newHarness(t, agent)
	chat := h.createThread("agent", "one")
	h.engine.Mirror("agent").Append("agent-session-1", testFrame)
	h.engine.Mirror("agent").Append("nobodys", testFrame)
	frames := func(session string) int {
		_, _, frames := h.kept("agent", session)
		return frames
	}
	if frames("agent-session-1") != 1 {
		t.Fatal("the new session's first frame wasn't kept while it opened")
	}
	close(agent.openGate)
	h.settledTurns(chat.Thread, 1)
	if session := agent.messages()[0].session; session != "agent-session-1" || frames(session) != 1 {
		t.Fatalf("the chat's session %q has %d frames, want the one mirrored before the chat took it", session, frames(session))
	}
	if frames("nobodys") != 0 {
		t.Fatal("frames of a session no chat took are still kept after the agent's opens ended")
	}

	h.engine.Mirror("agent").Append("nobodys", testFrame)
	h.restart()
	if row, _, kept := h.kept("agent", "nobodys"); row || kept != 0 {
		t.Fatalf("after a restart, the session no chat took: row %v, %d frames; want nothing kept", row, kept)
	}
	if frames("agent-session-1") != 1 {
		t.Fatal("the chat's frames didn't survive the restart")
	}
}

// An imported session's record is the provider's. What was mirrored of it
// while no chat had it (an agent's last frames of a session whose chat was
// deleted) is only the end of it, and an adapter that finds frames reads no
// more: the import starts without them.
func TestAnImportDropsWhatWasMirroredWhileNoChatHadTheSession(t *testing.T) {
	agent := newFakeInstance("agent", "Agent")
	h := newHarness(t, agent)
	chat := h.createThread("agent", "one")
	h.settledTurns(chat.Thread, 1)
	session := agent.messages()[0].session
	h.do(DeleteThread{Thread: chat.Thread})
	h.engine.Mirror("agent").Append(session, testFrame)
	if _, _, frames := h.kept("agent", session); frames != 1 {
		t.Fatalf("the frame written after the chat was deleted: %d kept, want it there until something drops it", frames)
	}

	h.do(importSession(h, "agent", session))
	if _, _, frames := h.kept("agent", session); frames != 0 {
		t.Fatalf("the imported chat's session has %d frames written while no chat had it, want none", frames)
	}
}
