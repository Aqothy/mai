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

	if err := instance.SendTurn(ctx, provider.SendTurnInput{ThreadID: "live-thread", TurnID: "live-turn-1", Input: "Reply with exactly: OK"}); err != nil {
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
				if event.TurnID != "live-turn-1" {
					continue
				}
				if event.Payload.TurnState != provider.RuntimeTurnCompleted {
					t.Fatalf("turn state = %q (%s)", event.Payload.TurnState, event.Payload.Message)
				}
				if text == "" {
					t.Fatal("no assistant text streamed")
				}
				t.Logf("assistant text: %q", text)
				return
			}
		case <-deadline:
			t.Fatal("live turn timed out")
		}
	}
}
