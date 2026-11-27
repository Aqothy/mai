package claudecode

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
	"github.com/Aqothy/maiD/internal/provider/providertest"
)

// TestLiveSmoke drives the real claude CLI end to end and checks that what
// streams live is what the transcript replays. It costs a small amount of
// API/subscription usage, so it only runs when explicitly asked:
//
//	CLAUDE_LIVE_TEST=1 go test ./internal/adapters/claudecode/ -run TestLiveSmoke -v
func TestLiveSmoke(t *testing.T) {
	if os.Getenv("CLAUDE_LIVE_TEST") != "1" {
		t.Skip("set CLAUDE_LIVE_TEST=1 to run the live CLI smoke test")
	}
	events := providertest.NewRecorder()
	events.Timeout = 2 * time.Minute
	instance, err := OpenInstance(context.Background(), provider.InstanceSpec{InstanceID: "claude-code", Name: "Claude Code"}, provider.Host{Emit: events.Emit})
	if err != nil {
		t.Fatalf("OpenInstance: %v", err)
	}
	defer instance.Close()
	if info := instance.Info(); info.Auth.Status != provider.AuthStatusAuthenticated {
		t.Skip("claude CLI is not logged in; skipping live turn")
	}
	h := testInstance{Instance: instance, events: events}

	cwd := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	opened, err := instance.Open(ctx, provider.OpenInput{
		Workspace: provider.Workspace{Cwd: cwd},
		Settings:  []provider.ConfigOptionSelection{{OptionID: "model", Value: "haiku"}, {OptionID: "permission_mode", Value: "acceptEdits"}},
	})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	session := opened.Session
	defer func() { _ = instance.Delete(context.Background(), session) }()

	first := h.send(t, session, "Write the word OK to a file named ok.txt with your Write tool, then reply with exactly: DONE", false)
	requireCompleted(t, events, first)
	steered := h.send(t, session, "Use your Bash tool to run `sleep 3 && echo one`, then reply with exactly: ONE", false)
	events.WaitFor(t, "the tool to start", func(event provider.Event) bool {
		upserted, ok := event.Body.(provider.EntryUpserted)
		return ok && upserted.Entry.Turn == steered && upserted.Entry.Tool != nil
	})
	steer := h.send(t, session, "Also reply with the word TWO after ONE.", true)
	// The steer joins the turn at the tool's boundary, or runs as the next.
	requireCompleted(t, events, steered)
	events.WaitFor(t, "the steer to be read", func(event provider.Event) bool {
		upserted, ok := event.Body.(provider.EntryUpserted)
		return ok && upserted.Entry.Delivery == steer
	})
	if turn := events.LiveTurns(session); turn[len(turn)-1].State == provider.TurnRunning {
		requireCompleted(t, events, turn[len(turn)-1].Ref)
	}
	if found, err := instance.Delivered(ctx, session, provider.DeliveryProbe{Delivery: steer}); err != nil || found != provider.TriYes {
		t.Fatalf("steer delivered = %v, %v", found, err)
	}
	h.requireLiveIsHistory(t, session)
	for _, turn := range h.events.LiveTurns(session) {
		t.Logf("turn %s %s: %q", turn.Ref, turn.State, entryTexts(turn))
	}
}

func requireCompleted(t *testing.T, events *providertest.Recorder, turn string) {
	t.Helper()
	if settled := events.WaitFor(t, "turn "+turn, providertest.Settled(turn)).Body.(provider.TurnSettled); settled.State != provider.TurnCompleted {
		t.Fatalf("turn %s = %#v", turn, settled)
	}
}
