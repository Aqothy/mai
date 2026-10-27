package orchestration

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

func handoffOf(t *testing.T, text string) *provider.Envelope {
	t.Helper()
	envelopes, _ := provider.SplitMessage(text)
	for _, envelope := range envelopes {
		if envelope.Kind == provider.EnvelopeHandoff {
			return &envelope
		}
	}
	return nil
}

// Plan with Claude, implement with Codex, return to Claude: Codex gets the
// conversation so far; Claude, back in its own session, gets only Codex's
// turns.
func TestSwitchingAgentsHandsOverOnlyWhatWasMissed(t *testing.T) {
	claude, codex := newFakeInstance("claude", "Claude"), newFakeInstance("codex", "Codex")
	h := newHarness(t, claude, codex)
	chat := h.createThread("claude", "Plan the cache")
	h.settledTurns(chat.Thread, 1)
	added := h.do(AddParticipant{Thread: chat.Thread, NewParticipant: NewParticipant{Instance: "codex"}})
	h.do(Deliver{Thread: chat.Thread, Body: MessageBody{Text: "Implement it"}})
	h.settledTurns(chat.Thread, 2)
	first := codex.messages()
	if len(first) != 1 {
		t.Fatalf("codex got %d messages", len(first))
	}
	handoff := handoffOf(t, first[0].in.Text)
	if handoff == nil || handoff.Covers != "1 turn" || !strings.Contains(handoff.Body, "Plan the cache") || !strings.Contains(handoff.Body, "answer to Plan the cache") {
		t.Fatalf("codex's first message = %q, want a handoff of Claude's turn", first[0].in.Text)
	}
	h.do(Deliver{Thread: chat.Thread, To: chat.Participant, Body: MessageBody{Text: "Review it"}})
	snapshot := h.settledTurns(chat.Thread, 3)
	back := claude.messages()
	if len(back) != 2 || back[1].session != back[0].session {
		t.Fatalf("claude messages = %#v, want its own session resumed", back)
	}
	handoff = handoffOf(t, back[1].in.Text)
	if handoff == nil || handoff.Covers != "1 turn" || !strings.Contains(handoff.Body, "Implement it") || strings.Contains(handoff.Body, "Plan the cache") {
		t.Fatalf("claude's return = %q, want a handoff of Codex's turn only", back[1].in.Text)
	}
	participants := []ParticipantID{snapshot.Turns[0].Participant, snapshot.Turns[1].Participant, snapshot.Turns[2].Participant}
	if participants[0] != chat.Participant || participants[1] != added.Participant || participants[2] != chat.Participant {
		t.Fatalf("turn participants = %v, want claude, codex, claude", participants)
	}
	// After a restart, the attributed order is the same.
	h.restart()
	again := h.snapshot(chat.Thread)
	for index, turn := range again.Turns {
		if turn.Participant != participants[index] {
			t.Fatalf("after restart turn %d is %s's, want %s's", index, turn.Participant, participants[index])
		}
	}
}

// Two agents messaging each other are held at the hop limit; Continue sends
// the held message as the person's.
func TestAgentsTalkingBackAndForthAreHeldAtTheHopLimit(t *testing.T) {
	claude, codex := newFakeInstance("claude", "Claude"), newFakeInstance("codex", "Codex")
	h := newHarness(t, claude, codex)
	chat := h.createThread("claude", "Start")
	h.settledTurns(chat.Thread, 1)
	h.do(UpdateThread{Thread: chat.Thread, Policy: &TreePolicy{MaxDepth: 2, MaxRunning: 4, HopLimit: 2}})
	codexParticipant := h.do(AddParticipant{Thread: chat.Thread, NewParticipant: NewParticipant{Instance: "codex"}}).Participant
	// Each agent, when messaged, messages the other back.
	bounce := func(to func() ParticipantID) func(f *fakeInstance, session string, in provider.SendInput) (provider.SendAck, error) {
		return func(f *fakeInstance, session string, in provider.SendInput) (provider.SendAck, error) {
			f.startTurn(session, in.Delivery, in)
			go func() {
				f.settle(session, in.Delivery, provider.TurnCompleted)
			}()
			return provider.SendAck{Turn: in.Delivery}, nil
		}
	}
	claude.onSend = bounce(nil)
	codex.onSend = bounce(nil)
	send := func(from, to ParticipantID) {
		if _, err := h.doAs(Agent(chat.Thread, from), Deliver{Thread: chat.Thread, To: to, Body: MessageBody{Text: "your turn"}, WantsReply: true}); err != nil {
			t.Fatalf("Deliver: %v", err)
		}
	}
	// Turns: person (0 hops) → message (1) → reply wake (1) → message (2) → … past 2.
	send(chat.Participant, codexParticipant)
	h.settledTurns(chat.Thread, 3)
	send(chat.Participant, codexParticipant)
	h.settledTurns(chat.Thread, 5)
	send(chat.Participant, codexParticipant)
	h.eventually("the hop hold", func() bool { return h.snapshot(chat.Thread).Thread.Hold == HoldHops })
	snapshot := h.snapshot(chat.Thread)
	if snapshot.Thread.Status != StatusHeld || !snapshot.Thread.Attention.NeedsInput {
		t.Fatalf("summary = %#v, want held and needing the user", snapshot.Thread)
	}
	if _, err := h.doAs(Agent(chat.Thread, chat.Participant), Continue{Thread: chat.Thread}); err == nil {
		t.Fatal("an agent released a hop hold")
	}
	h.do(Continue{Thread: chat.Thread})
	h.settledTurns(chat.Thread, 6)
}

// A parent recovers a child it stopped by sending to it; a person's stop is
// the person's to release.
func TestHoldsAreReleasedOnlyByWhoMay(t *testing.T) {
	claude, codex := newFakeInstance("claude", "Claude"), newFakeInstance("codex", "Codex")
	release := make(chan struct{})
	codex.onSend = func(f *fakeInstance, session string, in provider.SendInput) (provider.SendAck, error) {
		f.startTurn(session, in.Delivery, in)
		go func() {
			select {
			case <-release:
				f.settle(session, in.Delivery, provider.TurnCompleted)
			case <-time.After(3 * time.Second):
			}
		}()
		return provider.SendAck{Turn: in.Delivery}, nil
	}
	h := newHarness(t, claude, codex)
	parent := h.createThread("claude", "Orchestrate")
	h.settledTurns(parent.Thread, 1)
	agent := Agent(parent.Thread, parent.Participant)
	child, err := h.doAs(agent, Spawn{Parent: parent.Thread, Brief: "Long job", Agent: NewParticipant{Instance: "codex"}})
	if err != nil {
		t.Fatal(err)
	}
	h.eventually("the child to run", func() bool { return len(codex.messages()) == 1 })
	if _, err := h.doAs(agent, Deliver{Thread: child.Thread, Body: MessageBody{Text: "queued behind"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := h.doAs(agent, Stop{Thread: child.Thread}); err != nil {
		t.Fatalf("Stop: %v", err)
	}
	h.eventually("the agent's hold", func() bool { return h.snapshot(child.Thread).Thread.Hold == HoldStoppedAgent })
	if _, err := h.doAs(agent, Deliver{Thread: child.Thread, Body: MessageBody{Text: "carry on"}}); err != nil {
		t.Fatal(err)
	}
	h.eventually("the child to resume", func() bool { return len(codex.messages()) == 2 })
	close(release)
	h.settledTurns(child.Thread, 3)

	// A person's stop holds against the agent.
	h.do(Deliver{Thread: child.Thread, Body: MessageBody{Text: "one more"}})
	h.do(Stop{Thread: child.Thread})
	if _, err := h.doAs(agent, Continue{Thread: child.Thread}); err == nil {
		t.Fatal("an agent released a person's stop")
	}
}

// A native fork copies the conversation through a turn; deleting the source
// keeps the fork, which only loses its link.
func TestForkThroughATurnAndDeleteTheSource(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	h := newHarness(t, claude)
	source := h.createThread("claude", "one")
	h.settledTurns(source.Thread, 1)
	h.do(Deliver{Thread: source.Thread, Body: MessageBody{Text: "two"}})
	turns := h.settledTurns(source.Thread, 2).Turns
	fork := h.do(ForkThread{Thread: source.Thread, Through: turns[0].ID, Prompt: MessageBody{Text: "three"}})
	forked := h.settledTurns(fork.Thread, 2)
	if forked.Turns[0].StartedBy != StartedByFound || !forked.Turns[0].StartedAt.Equal(turns[0].StartedAt) {
		t.Fatalf("fork turns = %#v, want the first turn found at its source time", forked.Turns)
	}
	if got := joined(texts(forked.Turns[0])); got != "user_message: one | assistant_message: answer to one" {
		t.Fatalf("fork turn = %s", got)
	}
	if got := joined(texts(forked.Turns[1])); got != "user_message: three | assistant_message: answer to three" {
		t.Fatalf("fork's first turn = %s", got)
	}
	if forked.Thread.Origin.ForkedFrom == nil || forked.Thread.Origin.ForkedFrom.Thread != source.Thread {
		t.Fatalf("fork origin = %#v", forked.Thread.Origin)
	}
	if messages := claude.messages(); messages[len(messages)-1].session == messages[0].session || handoffOf(t, messages[len(messages)-1].in.Text) != nil {
		t.Fatalf("the fork's turn went to %q with %q; want its own session, with nothing handed over", messages[len(messages)-1].session, messages[len(messages)-1].in.Text)
	}
	h.do(DeleteThread{Thread: source.Thread})
	if snapshot := h.snapshot(fork.Thread); snapshot.Thread.Origin.ForkedFrom != nil || len(snapshot.Turns) != 2 {
		t.Fatalf("after deleting the source the fork = %#v", snapshot)
	}
	if _, err := h.sub.Thread(context.Background(), source.Thread); err == nil {
		t.Fatal("the deleted source still opens")
	}
}

// A chat is unread once a turn settles after a person last read it, on any
// device; reading it, or marking it unread, is one command every device
// sees, and it survives a restart.
func TestReadStateIsTheDaemons(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	h := newHarness(t, claude)
	chat := h.createThread("claude", "one")
	unread := func() bool { return h.snapshot(chat.Thread).Thread.Attention.Unread }
	h.settledTurns(chat.Thread, 1)
	if !unread() {
		t.Fatal("a settled turn nobody read isn't unread")
	}
	read, notRead := true, false
	h.do(UpdateThread{Thread: chat.Thread, Read: &read})
	if unread() {
		t.Fatal("read, the chat is still unread")
	}
	h.do(UpdateThread{Thread: chat.Thread, Read: &notRead})
	h.restart()
	if !unread() {
		t.Fatal("marked unread, the chat isn't unread after a restart")
	}
	h.do(UpdateThread{Thread: chat.Thread, Read: &read})
	h.do(Deliver{Thread: chat.Thread, Body: MessageBody{Text: "two"}})
	h.settledTurns(chat.Thread, 2)
	if !unread() {
		t.Fatal("a turn settled after the read isn't unread")
	}
}

// Continuing a chat in another agent starts from a summary the person sees
// and edits first: the preview offers it, the fork sends what they wrote, as
// written, and the chat's own agent isn't forked. A fork of the chat's own
// agent that can fork natively is offered without one.
func TestContinuingInAnotherAgentSendsTheEditedSummary(t *testing.T) {
	claude, codex := newFakeInstance("claude", "Claude"), newFakeInstance("codex", "Codex")
	h := newHarness(t, claude, codex)
	source := h.createThread("claude", "one")
	h.settledTurns(source.Thread, 1)
	ctx := context.Background()
	if own, err := h.engine.ForkPreview(ctx, source.Thread, "", ""); err != nil || !own.Native || own.Summary != "" {
		t.Fatalf("preview of a native fork = %#v, %v; want native, without a summary", own, err)
	}
	preview, err := h.engine.ForkPreview(ctx, source.Thread, "", "codex")
	if err != nil || preview.Native || !strings.Contains(preview.Summary, "User:\none") || !strings.Contains(preview.Summary, "answer to one") {
		t.Fatalf("preview into codex = %#v, %v; want the conversation as a summary", preview, err)
	}
	edited := preview.Summary + "Carry on: two"
	fork := h.do(ForkThread{Thread: source.Thread, Agent: &NewParticipant{Instance: "codex"}, Prompt: MessageBody{Text: edited}})
	forked := h.settledTurns(fork.Thread, 1)
	if got := codex.messages()[0].in.Text; got != edited {
		t.Fatalf("codex read %q, want what the person sent", got)
	}
	if len(forked.Turns) != 1 || forked.Thread.Origin.ForkedFrom == nil || forked.Thread.Origin.ForkedFrom.Thread != source.Thread {
		t.Fatalf("fork = %d turns, origin %#v; want its one turn, linked to its source", len(forked.Turns), forked.Thread.Origin)
	}
	claude.mu.Lock()
	claudeSessions := len(claude.sessions)
	claude.mu.Unlock()
	if claudeSessions != 1 {
		t.Fatalf("claude has %d sessions, want only the source's", claudeSessions)
	}
}

// A chat or a fork exists once its first message does: a refused one makes
// neither, nor a native fork.
func TestARefusedFirstMessageMakesNoChat(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	h := newHarness(t, claude)
	source := h.createThread("claude", "one")
	h.settledTurns(source.Thread, 1)
	missing := MessageBody{Attachments: []provider.Attachment{{Kind: provider.AttachmentImage, ID: strings.Repeat("0", 64)}}}
	var refusal *CommandError
	if _, err := h.doAs(h.device, CreateThread{Workspace: provider.Workspace{Cwd: h.dir}, Participant: NewParticipant{Instance: "claude"}, Prompt: &missing}); !errors.As(err, &refusal) || refusal.Code != CodeInvalid {
		t.Fatalf("create with a missing image = %v, want invalid", err)
	}
	if _, err := h.doAs(h.device, ForkThread{Thread: source.Thread, Prompt: missing}); !errors.As(err, &refusal) || refusal.Code != CodeInvalid {
		t.Fatalf("fork with a missing image = %v, want invalid", err)
	}
	if _, err := h.doAs(h.device, ForkThread{Thread: source.Thread}); !errors.As(err, &refusal) || refusal.Code != CodeInvalid {
		t.Fatalf("fork without a message = %v, want invalid", err)
	}
	list, err := h.sub.List(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	claude.mu.Lock()
	sessions := len(claude.sessions)
	claude.mu.Unlock()
	if len(list.Threads) != 1 || sessions != 1 {
		t.Fatalf("after refusals there are %d chats and %d native sessions, want only the source's", len(list.Threads), sessions)
	}
}

// A provider's own subagent becomes a child thread whose turns are its own.
func TestProviderSubagentIsAChildThread(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	claude.onSend = func(f *fakeInstance, session string, in provider.SendInput) (provider.SendAck, error) {
		f.startTurn(session, in.Delivery, in)
		go func() {
			f.entry(session, provider.Entry{Ref: "tool-1", Turn: in.Delivery, Kind: provider.ItemKindToolCall, Status: provider.ItemStatusInProgress, Tool: &provider.ToolCall{Name: "Agent"}})
			f.send(session, provider.SubagentSeen{Parent: session, Item: "tool-1", Session: session + "/agent-a1", Name: "Explorer"})
			f.send(session+"/agent-a1", provider.TurnStarted{Turn: "sub-1", By: provider.TurnByProvider})
			f.send(session+"/agent-a1", provider.EntryUpserted{Entry: provider.Entry{Ref: "sub-1/m", Turn: "sub-1", Kind: provider.ItemKindAssistantMessage, Text: "found it"}})
			f.send(session+"/agent-a1", provider.TurnSettled{Turn: "sub-1", State: provider.TurnCompleted})
			f.settle(session, in.Delivery, provider.TurnCompleted)
		}()
		return provider.SendAck{Turn: in.Delivery}, nil
	}
	h := newHarness(t, claude)
	parent := h.createThread("claude", "explore")
	snapshot := h.settledTurns(parent.Thread, 1)
	h.eventually("the subagent", func() bool {
		snapshot = h.snapshot(parent.Thread)
		return len(snapshot.Children) == 1
	})
	child := snapshot.Children[0]
	if child.Origin.Kind != OriginNative || child.Origin.At != "tool-1" || child.Title != "Explorer" || child.Origin.AcceptsInput {
		t.Fatalf("child = %#v", child)
	}
	childSnapshot := h.settledTurns(child.ID, 1)
	if got := joined(texts(childSnapshot.Turns[0])); got != "assistant_message: found it" {
		t.Fatalf("child turn = %s", got)
	}
	if _, err := h.engine.Do(context.Background(), Command{Actor: h.device, Body: Deliver{Thread: child.ID, Body: MessageBody{Text: "hi"}}}); err == nil {
		t.Fatal("a subagent that takes no input took a message")
	}
}

// An adapter whose mapping changed rebuilds a cached session from its
// native history on the next open, before the chat shows, keeping what maiD
// itself recorded.
// Entries the provider keeps no record of (Local) are maiD's, and survive.
// A turn the provider ran that the new mapping names differently is that
// turn, not an empty one beside it.
func TestCacheRebuildsWhenTheMappingChanges(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	claude.onSend = func(f *fakeInstance, session string, in provider.SendInput) (provider.SendAck, error) {
		turn := in.Delivery
		f.startTurn(session, turn, in)
		go func() {
			f.send(session, provider.EntryUpserted{Entry: provider.Entry{Ref: "report:" + turn, Turn: turn, Kind: provider.ItemKindAssistantMessage, Status: provider.ItemStatusCompleted, Text: "kept by maiD", Local: true}})
			f.entry(session, provider.Entry{Ref: turn + "/a", Turn: turn, Kind: provider.ItemKindAssistantMessage, Status: provider.ItemStatusCompleted, Text: "answer"})
			f.settle(session, turn, provider.TurnCompleted)
			// The CLI then runs a turn of its own.
			f.mu.Lock()
			f.sessions[session].turns = append(f.sessions[session].turns, provider.HistoryTurn{Ref: "woke", State: provider.TurnRunning})
			f.mu.Unlock()
			f.send(session, provider.TurnStarted{Turn: "woke", By: provider.TurnByProvider})
			f.entry(session, provider.Entry{Ref: "woke/a", Turn: "woke", Kind: provider.ItemKindAssistantMessage, Status: provider.ItemStatusCompleted, Text: "on its own"})
			f.settle(session, "woke", provider.TurnCompleted)
		}()
		return provider.SendAck{Turn: turn}, nil
	}
	h := newHarness(t, claude)
	chat := h.createThread("claude", "hello")
	h.settledTurns(chat.Thread, 2)
	// The adapter now maps the answer differently, and names the CLI's
	// turn differently.
	claude.mu.Lock()
	for _, native := range claude.sessions {
		for index := range native.turns {
			if native.turns[index].Ref == "woke" {
				native.turns[index].Ref = "wake:woke/a"
			}
			for entry := range native.turns[index].Entries {
				native.turns[index].Entries[entry].Turn = native.turns[index].Ref
				if native.turns[index].Entries[entry].Text == "answer" {
					native.turns[index].Entries[entry].Text = "better answer"
				}
			}
		}
	}
	claude.info.Capabilities.HistoryVersion = 2
	claude.mu.Unlock()
	h.restart()
	// The chat opens rebuilt, not from the old cache first.
	snapshot := h.snapshot(chat.Thread)
	if got := joined(texts(snapshot.Turns[0])); !strings.Contains(got, "better answer") || !strings.Contains(got, "kept by maiD") {
		t.Fatalf("rebuilt turn = %q, want the new mapping and the Local entry kept", got)
	}
	if len(snapshot.Turns) != 2 || joined(texts(snapshot.Turns[1])) != "assistant_message: on its own" {
		var got []string
		for _, turn := range snapshot.Turns {
			got = append(got, joined(texts(turn)))
		}
		t.Fatalf("rebuilt turns = %q, want the answer's and the CLI's own", got)
	}
}

// A person's quotes reach the agent as plain text and show as cards, live
// and after a rebuild from the provider's session.
func TestQuotesReachTheAgentAsTextAndShowAsCards(t *testing.T) {
	claude := newFakeInstance("claude", "Claude")
	h := newHarness(t, claude)
	quote := provider.PromptAnnotation{ID: "q1", MessageID: "m1", Role: "assistant", Quote: "use a map", Note: "why?"}
	chat := h.do(CreateThread{
		Workspace: provider.Workspace{Cwd: h.dir}, Participant: NewParticipant{Instance: "claude"},
		Prompt: &MessageBody{Text: "Explain", Annotations: []provider.PromptAnnotation{quote}},
	})
	h.settledTurns(chat.Thread, 1)
	sent := claude.messages()[0].in.Text
	const want = "The user selected these passages from earlier in the chat as context:\n\nSelection 1 (assistant):\n> use a map\nComment:\n> why?\n\nExplain"
	if sent != want {
		t.Fatalf("the agent read %q, want %q", sent, want)
	}
	card := func(snapshot ThreadSnapshot) string {
		for _, entry := range snapshot.Turns[0].Entries {
			if entry.Kind == provider.ItemKindUserMessage {
				if len(entry.Annotations) != 1 {
					return entry.Text
				}
				return entry.Text + " [" + entry.Annotations[0].Quote + ": " + entry.Annotations[0].Note + "]"
			}
		}
		return ""
	}
	if got := card(h.snapshot(chat.Thread)); got != "Explain [use a map: why?]" {
		t.Fatalf("live message = %q", got)
	}
	// A quote with only a comment is a message too.
	h.do(Deliver{Thread: chat.Thread, Body: MessageBody{Annotations: []provider.PromptAnnotation{quote}}})
	h.settledTurns(chat.Thread, 2)
	if sent := claude.messages()[1].in.Text; !strings.HasSuffix(sent, "> why?\n") {
		t.Fatalf("the quote alone reached the agent as %q", sent)
	}
	claude.mu.Lock()
	claude.info.Capabilities.HistoryVersion = 2
	claude.mu.Unlock()
	h.restart()
	h.snapshot(chat.Thread)
	h.eventually("the rebuild", func() bool {
		stored, err := h.engine.db.marker(context.Background(), "claude", "claude-session-1")
		return err == nil && stored.version == 2
	})
	if got := card(h.snapshot(chat.Thread)); got != "Explain [use a map: why?]" {
		t.Fatalf("rebuilt message = %q", got)
	}
}

// Agents act within their scope and ceilings.
func TestAgentScopeAndCeilings(t *testing.T) {
	claude, codex := newFakeInstance("claude", "Claude"), newFakeInstance("codex", "Codex")
	h := newHarness(t, claude, codex)
	one := h.createThread("claude", "tree one")
	two := h.createThread("codex", "tree two")
	h.settledTurns(one.Thread, 1)
	h.settledTurns(two.Thread, 1)
	agent := Agent(one.Thread, one.Participant)
	var refusal *CommandError
	if _, err := h.doAs(agent, Deliver{Thread: two.Thread, Body: MessageBody{Text: "hi"}}); !errors.As(err, &refusal) || refusal.Code != CodeOutOfScope {
		t.Fatalf("message to another tree = %v, want out_of_scope", err)
	}
	h.do(UpdateParticipant{Participant: one.Participant, Setting: provider.ConfigOptionSelection{OptionID: "mode", Value: "ask"}})
	full := provider.AccessFull
	if _, err := h.doAs(agent, Spawn{Parent: one.Thread, Brief: "do anything", Agent: NewParticipant{Instance: "codex"}, Access: &full}); !errors.As(err, &refusal) || refusal.Code != CodeCeilingExceeded {
		t.Fatalf("spawn above the caller's access = %v, want ceiling_exceeded", err)
	}
	child, err := h.doAs(agent, Spawn{Parent: one.Thread, Brief: "read only", Agent: NewParticipant{Instance: "codex"}})
	if err != nil {
		t.Fatal(err)
	}
	snapshot := h.snapshot(child.Thread)
	if level := snapshot.Participants[0].Access; level != provider.AccessAsk {
		t.Fatalf("child access = %v, want the caller's", level)
	}
	childAgent := Agent(child.Thread, child.Participant)
	if _, err := h.doAs(childAgent, Spawn{Parent: child.Thread, Brief: "deeper"}); err != nil {
		t.Fatalf("spawn at depth 2: %v", err)
	}
	grandchild := h.snapshot(child.Thread).Children[0]
	if _, err := h.doAs(Agent(grandchild.ID, grandchild.Participants[0].ID), Spawn{Parent: grandchild.ID, Brief: "too deep"}); !errors.As(err, &refusal) || refusal.Code != CodeDepthExceeded {
		t.Fatalf("spawn past the depth = %v, want depth_exceeded", err)
	}
	if _, err := h.doAs(childAgent, Interrupt{Thread: one.Thread}); !errors.As(err, &refusal) || refusal.Code != CodeOutOfScope {
		t.Fatalf("a child interrupting its parent = %v, want out_of_scope", err)
	}
	if _, err := h.doAs(childAgent, Deliver{Thread: one.Thread, Body: MessageBody{Text: "question for you"}, WantsReply: true}); err != nil {
		t.Fatalf("a child asking its parent: %v", err)
	}
}

// A command repeated with its key returns the first one's result.
func TestKeyedCommandsAreIdempotent(t *testing.T) {
	claude, codex := newFakeInstance("claude", "Claude"), newFakeInstance("codex", "Codex")
	h := newHarness(t, claude, codex)
	parent := h.createThread("claude", "plan")
	h.settledTurns(parent.Thread, 1)
	agent := Agent(parent.Thread, parent.Participant)
	spawn := Command{Key: "call-1", Actor: agent, Body: Spawn{Parent: parent.Thread, Brief: "once", Agent: NewParticipant{Instance: "codex"}}}
	first, err := h.engine.Do(context.Background(), spawn)
	if err != nil {
		t.Fatal(err)
	}
	h.restart()
	second, err := h.engine.Do(context.Background(), spawn)
	if err != nil || second != first {
		t.Fatalf("retried spawn = %#v, %v; want %#v", second, err, first)
	}
	if children := h.snapshot(parent.Thread).Children; len(children) != 1 {
		t.Fatalf("children = %d, want 1", len(children))
	}
}

// Reports reach the reply; a schema without a report says so.
func TestReplyCarriesTheReport(t *testing.T) {
	claude, codex := newFakeInstance("claude", "Claude"), newFakeInstance("codex", "Codex")
	h := newHarness(t, claude, codex)
	parent := h.createThread("claude", "plan")
	h.settledTurns(parent.Thread, 1)
	agent := Agent(parent.Thread, parent.Participant)
	var child CommandResult
	codex.onSend = func(f *fakeInstance, session string, in provider.SendInput) (provider.SendAck, error) {
		f.startTurn(session, in.Delivery, in)
		go func() {
			for child.Thread == "" {
				time.Sleep(time.Millisecond)
			}
			if _, err := h.doAs(Agent(child.Thread, child.Participant), Report{Result: json.RawMessage(`{"verdict":"approve"}`)}); err != nil {
				t.Errorf("Report: %v", err)
			}
			f.settle(session, in.Delivery, provider.TurnCompleted)
		}()
		return provider.SendAck{Turn: in.Delivery}, nil
	}
	var err error
	child, err = h.doAs(agent, Spawn{Parent: parent.Thread, Brief: "review", Agent: NewParticipant{Instance: "codex"}, ResultSchema: json.RawMessage(`{"type":"object"}`)})
	if err != nil {
		t.Fatal(err)
	}
	h.settledTurns(parent.Thread, 2)
	wake := claude.messages()[1].in.Text
	if !strings.Contains(wake, `{"verdict":"approve"}`) {
		t.Fatalf("wake = %q, want the report", wake)
	}
}
