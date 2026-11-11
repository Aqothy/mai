package orchestration

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

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

// moveOn has the chat's agent leave its session for a new one, as /clear
// does, and run a turn of its own there.
func moveOn(h *harness, agent *fakeInstance, chat CommandResult, from, to string) {
	h.t.Helper()
	turns := len(h.snapshot(chat.Thread).Turns)
	agent.mu.Lock()
	agent.sessions[to] = &fakeSession{delivered: make(map[string]bool)}
	agent.live[to] = true
	agent.mu.Unlock()
	agent.send(from, provider.SessionReplaced{New: to})
	agent.send(to, provider.TurnStarted{Turn: "wake:1", By: provider.TurnByProvider})
	agent.send(to, provider.EntryUpserted{Entry: provider.Entry{Ref: "wake:1/m1", Turn: "wake:1", Kind: provider.ItemKindAssistantMessage, Status: provider.ItemStatusCompleted, Text: "Cleared."}})
	agent.send(to, provider.TurnSettled{Turn: "wake:1", State: provider.TurnCompleted})
	h.settledTurns(chat.Thread, turns+1)
}

func importSession(h *harness, instance provider.InstanceID, session string) CreateThread {
	return CreateThread{Workspace: provider.Workspace{Cwd: h.dir}, Participant: NewParticipant{Instance: instance, Session: session}}
}

// Deleting a chat deletes what was kept of every session it was on: also of
// one its agent left, whose turns the chat showed until then.
func TestDeletingAChatDeletesEverySessionItWasOn(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	h := newHarness(t, claude)
	chat := h.createThread("claude", "one")
	h.settledTurns(chat.Thread, 1)
	first, second := claude.messages()[0].session, "claude-session-9"
	h.engine.Mirror("claude").Append(first, testFrame)
	moveOn(h, claude, chat, first, second)
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

// A session a chat's agent left is still that chat's, with its earlier
// turns: importing it opens the chat. It becomes a chat of its own only once
// that one is deleted.
func TestImportingASessionAChatLeftOpensThatChat(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	h := newHarness(t, claude)
	chat := h.createThread("claude", "one")
	h.settledTurns(chat.Thread, 1)
	first := claude.messages()[0].session
	moveOn(h, claude, chat, first, "claude-session-9")
	importIt := CreateThread{Workspace: provider.Workspace{Cwd: h.dir}, Participant: NewParticipant{Instance: "claude", Session: first}}

	if imported := h.do(importIt); imported.Thread != chat.Thread || imported.Participant != chat.Participant {
		t.Fatalf("importing the session the chat left = %+v, want the chat %s and its agent %s", imported, chat.Thread, chat.Participant)
	}
	h.do(DeleteThread{Thread: chat.Thread})
	again := h.do(importIt)
	if again.Thread == chat.Thread {
		t.Fatal("importing the session after its chat was deleted opened the deleted chat")
	}
	if turns := h.settledTurns(again.Thread, 1).Turns; len(turns) != 1 || len(turns[0].Entries) == 0 {
		t.Fatalf("the imported chat's turns = %#v, want the session's one turn, read from the provider", turns)
	}
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

// Importing a session that is a chat's opens that chat, and a prompt sent
// with the import is delivered there, to the agent whose session it is.
func TestAPromptSentWithAnImportOfAChatsSessionIsDelivered(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	h := newHarness(t, claude)
	chat := h.createThread("claude", "one")
	h.settledTurns(chat.Thread, 1)
	first := claude.messages()[0].session
	withPrompt := func(text string) CreateThread {
		create := importSession(h, "claude", first)
		create.Prompt = &MessageBody{Text: text}
		return create
	}

	if on := h.do(withPrompt("two")); on.Thread != chat.Thread || on.Delivery == "" {
		t.Fatalf("importing the chat's session with a prompt = %+v, want the chat %s and the prompt's delivery", on, chat.Thread)
	}
	h.settledTurns(chat.Thread, 2)
	moveOn(h, claude, chat, first, "claude-session-9")
	if left := h.do(withPrompt("three")); left.Thread != chat.Thread || left.Delivery == "" {
		t.Fatalf("importing the session the chat left with a prompt = %+v, want the chat %s and the prompt's delivery", left, chat.Thread)
	}
	h.settledTurns(chat.Thread, 4)
	got := claude.messages()
	if last := got[len(got)-1]; len(got) != 3 || !strings.HasSuffix(last.in.Text, "three") || last.session != "claude-session-9" {
		t.Fatalf("the agent got %d messages, the last %q on %q; want the three prompts, the last on the session it is on now", len(got), last.in.Text, last.session)
	}
}

// The agent an import names is the one whose session it is, also among
// several agents of one provider in a chat.
func TestImportingASessionNamesTheAgentThatWasOnIt(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	h := newHarness(t, claude)
	chat := h.createThread("claude", "one")
	h.settledTurns(chat.Thread, 1)
	second := h.do(AddParticipant{Thread: chat.Thread, NewParticipant: NewParticipant{Instance: "claude"}})
	h.do(Deliver{Thread: chat.Thread, Body: MessageBody{Text: "two"}})
	h.settledTurns(chat.Thread, 2)
	its := claude.messages()[1].session
	moveOn(h, claude, chat, its, "claude-session-9")

	if imported := h.do(importSession(h, "claude", its)); imported.Thread != chat.Thread || imported.Participant != second.Participant {
		t.Fatalf("importing the session the second agent left = %+v, want the chat %s and that agent %s (the first is %s)", imported, chat.Thread, second.Participant, chat.Participant)
	}
}

// A native session is one agent's, in one chat, for as long as that chat
// lives. Naming it as another chat's agent's session would move what is kept
// of it to that chat, and deleting that chat would take the first one's turns.
func TestASessionAChatLeftCantBecomeAnotherChats(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	h := newHarness(t, claude)
	one := h.createThread("claude", "one")
	h.settledTurns(one.Thread, 1)
	left := claude.messages()[0].session
	moveOn(h, claude, one, left, "claude-session-9")
	two := h.createThread("claude", "two")
	h.settledTurns(two.Thread, 1)
	_, before, _ := h.kept("claude", left)

	var refusal *CommandError
	if _, err := h.doAs(h.device, AddParticipant{Thread: two.Thread, NewParticipant: NewParticipant{Instance: "claude", Session: left}}); !errors.As(err, &refusal) || refusal.Code != CodeInvalid {
		t.Errorf("adding the session chat one left as an agent of chat two: %v, want it refused as invalid", err)
	}
	h.do(DeleteThread{Thread: two.Thread})
	if _, entries, _ := h.kept("claude", left); entries != before {
		t.Fatalf("after deleting chat two, chat one's session has %d entries, had %d", entries, before)
	}
}

// Every command that takes an agent with a session refuses one that is
// another chat's, and the daemon goes on.
func TestASessionOfAChatIsRefusedToAnotherChat(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	h := newHarness(t, claude)
	one := h.createThread("claude", "one")
	h.settledTurns(one.Thread, 1)
	two := h.createThread("claude", "two")
	h.settledTurns(two.Thread, 1)
	taken := NewParticipant{Instance: "claude", Session: claude.messages()[0].session}

	for name, command := range map[string]CommandBody{
		"adding it as an agent":     AddParticipant{Thread: two.Thread, NewParticipant: taken},
		"forking to an agent on it": ForkThread{Thread: two.Thread, Agent: &taken, Prompt: MessageBody{Text: "go on"}},
		"spawning an agent on it":   Spawn{Parent: two.Thread, Brief: "look into it", Agent: taken},
	} {
		var refusal *CommandError
		if _, err := h.doAs(h.device, command); !errors.As(err, &refusal) || refusal.Code != CodeInvalid {
			t.Errorf("%s: %v, want it refused as invalid", name, err)
		}
	}
	if again := h.createThread("claude", "three"); again.Thread == "" {
		t.Fatal("the engine stopped")
	}
}
