package codexapp

import (
	"context"
	"encoding/json"
	"os"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
	"github.com/Aqothy/maiD/internal/provider/providertest"
)

// TestLiveSmoke drives the real Codex app-server end to end and checks that
// what streams live is what the thread's history returns. It sends model
// turns, so it only runs when explicitly asked, and deletes the threads it
// made:
//
//	CODEX_LIVE_TEST=1 CODEX_LIVE_MODEL=gpt-6-luna CODEX_LIVE_EFFORT=low go test ./internal/adapters/codexapp/ -run TestLiveSmoke -v
func TestLiveSmoke(t *testing.T) {
	if os.Getenv("CODEX_LIVE_TEST") != "1" {
		t.Skip("set CODEX_LIVE_TEST=1 to run the live app-server smoke test")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	spec := provider.InstanceSpec{InstanceID: "codex-live-qa", Name: "Codex QA"}
	if binary := os.Getenv("CODEX_LIVE_BINARY"); binary != "" {
		config, err := json.Marshal(Config{Command: []string{binary, "app-server"}})
		if err != nil {
			t.Fatal(err)
		}
		spec.Config = config
	}
	events := providertest.NewRecorder()
	events.Timeout = 3 * time.Minute
	instance, err := OpenInstance(ctx, spec, provider.Host{Emit: events.Emit})
	if err != nil {
		t.Fatal(err)
	}
	defer instance.Close()
	if instance.Info().Auth.Status != provider.AuthStatusAuthenticated {
		t.Fatal("the installed Codex CLI is not authenticated")
	}
	settings := []provider.ConfigOptionSelection{{OptionID: permissionsOptionID, Value: "auto"}}
	if model := os.Getenv("CODEX_LIVE_MODEL"); model != "" {
		settings = append(settings, provider.ConfigOptionSelection{OptionID: "model", Value: model})
	}
	if effort := os.Getenv("CODEX_LIVE_EFFORT"); effort != "" {
		settings = append(settings, provider.ConfigOptionSelection{OptionID: "reasoning_effort", Value: effort})
	}
	cwd := t.TempDir()
	opened, err := instance.Open(ctx, provider.OpenInput{Workspace: provider.Workspace{Cwd: cwd}, Settings: settings})
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	session := opened.Session
	defer func() { _ = instance.Delete(context.Background(), session) }()

	send := func(delivery, text string, steer bool) provider.SendAck {
		t.Helper()
		ack, err := instance.Send(ctx, session, provider.SendInput{Delivery: delivery, Text: text, Steer: steer})
		if err != nil {
			t.Fatalf("send %q: %v", text, err)
		}
		return ack
	}
	completed := func(turn string) {
		t.Helper()
		if settled := events.WaitFor(t, "turn "+turn, providertest.Settled(turn)).Body.(provider.TurnSettled); settled.State != provider.TurnCompleted {
			t.Fatalf("turn %s = %#v", turn, settled)
		}
	}
	first := send("live-1", "Run `sleep 2 && echo one` in your shell, then reply with exactly: ONE", false)
	events.WaitFor(t, "the command to start", func(event provider.Event) bool {
		upserted, ok := event.Body.(provider.EntryUpserted)
		return ok && upserted.Entry.Turn == first.Turn && upserted.Entry.Kind == provider.ItemKindCommandExecution
	})
	if steer := send("live-steer", "Also reply with the word TWO after ONE.", true); steer.Turn != first.Turn {
		t.Fatalf("steer ack = %#v, want turn %s", steer, first.Turn)
	}
	completed(first.Turn)
	compact := send("live-compact", "/compact", false)
	if compact.Turn == "" {
		compact.Turn = events.WaitFor(t, "the compaction's turn", func(event provider.Event) bool {
			started, ok := event.Body.(provider.TurnStarted)
			return ok && started.Delivery == "live-compact"
		}).Body.(provider.TurnStarted).Turn
	}
	completed(compact.Turn)

	page, err := instance.History(ctx, session, provider.Workspace{Cwd: cwd}, "")
	if err != nil {
		t.Fatalf("history: %v", err)
	}
	// Codex replays a turn's items in the order it recorded them, which puts
	// a steer before the command it arrived during; live shows the order they
	// started. The entries themselves agree.
	live, replayed := byRef(comparable(events.LiveTurns(session))), byRef(comparable(page.Turns))
	if !reflect.DeepEqual(live, replayed) {
		liveJSON, _ := json.MarshalIndent(live, "", "  ")
		replayedJSON, _ := json.MarshalIndent(replayed, "", "  ")
		t.Fatalf("live turns differ from history\nlive: %s\nhistory: %s", liveJSON, replayedJSON)
	}
	for _, turn := range page.Turns {
		var entries []string
		for _, entry := range turn.Entries {
			entries = append(entries, string(entry.Kind)+":"+strings.TrimSpace(entry.Text))
		}
		t.Logf("turn %s %s: %q", turn.Ref, turn.State, entries)
	}
	// Reading on from a turn returns only the turns after it.
	for index, turn := range page.Turns {
		after, err := instance.History(ctx, session, provider.Workspace{Cwd: cwd}, provider.Marker(turn.Ref))
		if err != nil || after.Reset || len(after.Turns) != len(page.Turns)-index-1 {
			t.Fatalf("history after %s = %d turns (reset %v), %v; want %d", turn.Ref, len(after.Turns), after.Reset, err, len(page.Turns)-index-1)
		}
	}

	sessions, err := instance.Sessions(ctx, cwd)
	if err != nil {
		t.Fatalf("sessions: %v", err)
	}
	found := false
	for _, summary := range sessions {
		found = found || summary.SessionID == session
	}
	if !found {
		t.Fatal("new session absent from its working-directory history")
	}
	fork, err := instance.Fork(ctx, provider.ForkInput{Session: session, Through: first.Turn, Workspace: provider.Workspace{Cwd: cwd}, Settings: settings})
	if err != nil {
		t.Fatalf("fork: %v", err)
	}
	defer func() { _ = instance.Delete(context.Background(), fork) }()
	forked, err := instance.History(ctx, fork, provider.Workspace{Cwd: cwd}, "")
	if err != nil || len(forked.Turns) != 1 {
		t.Fatalf("fork history = %#v, %v; want the turn it forked through", forked.Turns, err)
	}
}

// byRef orders each turn's entries by ref.
func byRef(turns []provider.HistoryTurn) []provider.HistoryTurn {
	for index := range turns {
		slices.SortFunc(turns[index].Entries, func(a, b provider.Entry) int { return strings.Compare(a.Ref, b.Ref) })
	}
	return turns
}
