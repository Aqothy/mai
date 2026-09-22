package codexapp

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// TestLiveSmoke uses the installed, authenticated CLI and a disposable working
// directory. It consumes subscription/API usage and is deliberately opt-in.
func TestLiveSmoke(t *testing.T) {
	if os.Getenv("CODEX_LIVE_TEST") != "1" {
		t.Skip("set CODEX_LIVE_TEST=1 to run the live CLI smoke test")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	events := make(chan provider.RuntimeEvent, 1024)
	spec := provider.InstanceSpec{InstanceID: "codex-live-qa", Name: "Codex QA"}
	if binary := os.Getenv("CODEX_LIVE_BINARY"); binary != "" {
		config, err := json.Marshal(Config{Command: []string{binary, "app-server"}})
		if err != nil {
			t.Fatal(err)
		}
		spec.Config = config
	}
	instance, err := OpenInstance(ctx, spec, func(event provider.RuntimeEvent) {
		select {
		case events <- event:
		case <-ctx.Done():
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	defer instance.Close()
	t.Logf("authentication: %s", instance.Info().Auth.Status)
	if instance.Info().Auth.Status != provider.AuthStatusAuthenticated {
		t.Fatal("the installed Codex CLI is not authenticated")
	}
	cwd := t.TempDir()
	instance.mu.Lock()
	for _, model := range instance.models {
		t.Logf("available model: %s (default=%t)", model.Model, model.IsDefault)
	}
	instance.mu.Unlock()
	var selection *provider.ModelSelection
	if model := os.Getenv("CODEX_LIVE_MODEL"); model != "" {
		selection = &provider.ModelSelection{Model: model}
	}
	var config []provider.ConfigOptionSelection
	selectedEffort := os.Getenv("CODEX_LIVE_EFFORT")
	if selectedEffort != "" {
		config = []provider.ConfigOptionSelection{{OptionID: "reasoning_effort", Value: selectedEffort}}
	}
	checkEffort := func(session provider.Session) {
		t.Helper()
		if selectedEffort != "" {
			if got, ok := currentConfigString(session.ConfigOptions, "reasoning_effort"); !ok || got != selectedEffort {
				t.Fatalf("session reasoning effort = %q, %v; want %q", got, ok, selectedEffort)
			}
			t.Logf("effective reasoning effort: %s", selectedEffort)
		}
	}
	started, err := instance.StartSession(ctx, provider.StartSessionInput{ThreadID: "live-thread", Cwd: cwd, ModelSelection: selection, ConfigSelections: config})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	checkEffort(started.Session)
	if err := instance.SendTurn(ctx, provider.SendTurnInput{
		ThreadID: "live-thread", TurnID: "live-turn",
		Input: "Reply with exactly OK. Do not use tools or modify files.",
	}); err != nil {
		t.Fatalf("send: %v", err)
	}
	var text strings.Builder
	for {
		select {
		case event := <-events:
			if event.ThreadID != "live-thread" || event.TurnID != "live-turn" {
				continue
			}
			switch event.Type {
			case provider.RuntimeEventContentDelta:
				if event.Payload.StreamKind == provider.RuntimeContentAssistantText {
					text.WriteString(event.Payload.Delta)
				}
			case provider.RuntimeEventTurnCompleted:
				if event.Payload.TurnState != provider.RuntimeTurnCompleted {
					t.Fatalf("turn: %s (%s)", event.Payload.TurnState, event.Payload.Message)
				}
				if strings.TrimSpace(text.String()) != "OK" {
					t.Fatalf("unexpected assistant text: %q", text.String())
				}
				goto completed
			}
		case <-ctx.Done():
			t.Fatalf("waiting for completion: %v", ctx.Err())
		}
	}

completed:
	sessions, err := instance.ListSessions(ctx, cwd)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	found := false
	for _, session := range sessions {
		found = found || session.SessionID == started.Session.ProviderSessionID
	}
	if !found {
		t.Fatal("new session absent from its working-directory history")
	}
	if err := instance.StopSession(ctx, provider.StopSessionInput{ThreadID: "live-thread"}); err != nil {
		t.Fatalf("stop: %v", err)
	}
	resumed, err := instance.StartSession(ctx, provider.StartSessionInput{
		ThreadID: "resumed-thread", ProviderSessionID: started.Session.ProviderSessionID,
		Cwd: cwd, ReplayHistory: true, ModelSelection: selection, ConfigSelections: config,
	})
	if err != nil {
		t.Fatalf("resume: %v", err)
	}
	if resumed.HistoryUnavailable || len(resumed.Replay) == 0 {
		t.Fatal("completed session replay is unavailable or empty")
	}
	checkEffort(resumed.Session)
	forked, err := instance.ForkSession(ctx, provider.ForkSessionInput{ProviderSessionID: started.Session.ProviderSessionID})
	if err != nil {
		t.Fatalf("fork: %v", err)
	}
	if forked.Summary.SessionID == "" || forked.Summary.SessionID == started.Session.ProviderSessionID {
		t.Fatal("fork did not create an independent native session")
	}
	t.Logf("completed text, listing, stop/resume (%d replay events), and fork passed", len(resumed.Replay))
}
