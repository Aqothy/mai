package claudecode

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// TestLiveSmoke drives the real claude CLI end to end. It costs a small
// amount of API/subscription usage, so it only runs when explicitly asked:
//
//	CLAUDE_LIVE_TEST=1 go test ./internal/adapters/claudecode/ -run TestLiveSmoke -v
func TestLiveSmoke(t *testing.T) {
	if os.Getenv("CLAUDE_LIVE_TEST") != "1" {
		t.Skip("set CLAUDE_LIVE_TEST=1 to run the live CLI smoke test")
	}
	events := make(chan provider.RuntimeEvent, 1024)
	instance, err := OpenInstance(context.Background(), provider.InstanceSpec{InstanceID: "claude-code", Name: "Claude Code"}, func(event provider.RuntimeEvent) {
		select {
		case events <- event:
		default:
		}
	})
	if err != nil {
		t.Fatalf("OpenInstance: %v", err)
	}
	defer instance.Close()
	info := instance.Info()
	t.Logf("auth status: %s", info.Auth.Status)
	if info.Auth.Status != provider.AuthStatusAuthenticated {
		t.Skip("claude CLI is not logged in; skipping live turn")
	}

	cwd := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	result, err := instance.StartSession(ctx, provider.StartSessionInput{
		ThreadID:       "live-thread",
		Cwd:            cwd,
		ModelSelection: &provider.ModelSelection{Model: "haiku"},
	})
	if err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	t.Logf("session id: %s, options: %d, skills: %d", result.Session.ProviderSessionID, len(result.Session.ConfigOptions), len(result.Session.Skills))

	// Without a selection the session runs in the CLI's configured mode.
	mode, _ := provider.CurrentConfigString(result.Session.ConfigOptions, "permission_mode")
	t.Logf("permission mode: %s", mode)
	defer func() { _ = instance.DeleteSession(context.Background(), result.Session.ProviderSessionID) }()

	runTurn := func(turnID, prompt string) string {
		t.Helper()
		if err := instance.SendTurn(ctx, provider.SendTurnInput{ThreadID: "live-thread", TurnID: turnID, Input: prompt}); err != nil {
			t.Fatalf("SendTurn: %v", err)
		}
		text := ""
		deadline := time.After(90 * time.Second)
		for {
			select {
			case event := <-events:
				switch event.Type {
				case provider.RuntimeEventContentDelta:
					if event.Payload.StreamKind == provider.RuntimeContentAssistantText {
						text += event.Payload.Delta
					}
				case provider.RuntimeEventThreadTokenUsage:
					t.Logf("usage: %+v", event.Payload.TokenUsage)
				case provider.RuntimeEventTurnCompleted:
					if event.TurnID != turnID {
						continue
					}
					if event.Payload.TurnState != provider.RuntimeTurnCompleted {
						t.Fatalf("turn state = %q (%s)", event.Payload.TurnState, event.Payload.Message)
					}
					if text == "" {
						t.Fatal("no assistant text streamed")
					}
					t.Logf("assistant text: %q", text)
					return text
				}
			case <-deadline:
				t.Fatal("live turn timed out")
			}
		}
	}
	runTurn("live-turn-1", "Reply with exactly: OK")

	// Effort changes apply to the running CLI.
	if err := instance.SetConfigOption(ctx, provider.SetConfigOptionInput{ThreadID: "live-thread", OptionID: "effort", Value: "low"}); err != nil {
		t.Fatalf("set effort: %v", err)
	}
	runTurn("live-turn-2", "Reply with exactly: DONE")

	// The transcript replays both turns.
	if err := instance.StopSession(ctx, provider.StopSessionInput{ThreadID: "live-thread"}); err != nil {
		t.Fatalf("StopSession: %v", err)
	}
	replayed, err := instance.StartSession(ctx, provider.StartSessionInput{ThreadID: "live-thread", Cwd: cwd, ResumeCursor: result.Session.ResumeCursor, ReplayHistory: true})
	if err != nil {
		t.Fatalf("replay StartSession: %v", err)
	}
	var prompts []string
	for _, event := range replayed.Replay {
		if event.Payload.ItemType == provider.ItemKindUserMessage {
			prompts = append(prompts, event.Payload.Detail)
		}
	}
	if len(prompts) != 2 || replayed.HistoryUnavailable {
		t.Fatalf("replayed prompts = %q (unavailable %v)", prompts, replayed.HistoryUnavailable)
	}
}
