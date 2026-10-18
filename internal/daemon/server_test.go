package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
)

func TestProviderStartValidation(t *testing.T) {
	for _, tc := range []struct {
		name string
		spec provider.InstanceSpec
		want string
	}{
		{name: "instance id", spec: provider.InstanceSpec{}, want: "provider start requires instanceId"},
		{name: "config", spec: provider.InstanceSpec{InstanceID: "codex", Name: "codex", Driver: "acp"}, want: "missing ACP config"},
		{name: "command", spec: acpInstanceSpec("codex", "codex", nil), want: "ACP config requires command"},
		{name: "malformed config", spec: provider.InstanceSpec{InstanceID: "codex", Name: "codex", Driver: "acp", Config: json.RawMessage(`{"command":`)}, want: "decode ACP config"},
		{name: "unsupported driver", spec: provider.InstanceSpec{InstanceID: "codex", Name: "codex", Driver: "unknown"}, want: `unsupported provider driver "unknown"`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := NewServer()
			defer server.Close()
			_, err := server.StartProvider(context.Background(), tc.spec, false)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err = %v, want error containing %q", err, tc.want)
			}
		})
	}
}

func TestProviderRestartSettlesActiveTurnFromReplacedProcess(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()

	dir := t.TempDir()
	startFakeACPAgent(t, s, "codex")

	threadID := orchestration.ThreadID("thread-restart-settles-turn")
	if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{Type: orchestration.CommandThreadCreate, CommandID: "cmd-create-restart-settle", ThreadID: threadID, Title: "Restart settle", ProviderInstanceID: "codex", Cwd: dir}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{Type: orchestration.CommandThreadTurnStart, CommandID: "cmd-turn-restart-settle", ThreadID: threadID, Message: &orchestration.CommandMessage{MessageID: "msg-restart", Text: "block " + dir}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}
	waitForFile(t, dir+"/ready")

	if _, err := s.StartProvider(context.Background(), acpInstanceSpec("codex", "codex", fakeACPAgentCommand()), true); err != nil {
		t.Fatalf("provider restart: %v", err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		thread, ok := s.orchestration.ThreadListEntry(threadID)
		if ok && thread.LatestTurn != nil && thread.LatestTurn.State == orchestration.TurnStateError && thread.Session != nil && thread.Session.ActiveTurnID == "" {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	thread, _ := s.orchestration.ThreadListEntry(threadID)
	t.Fatalf("thread after restart = %#v, want replaced provider turn settled as error", thread)
}

// A restart between a turn's session start and its send moves the session to
// the replacement, whose events must reach the turn although the thread is
// still bound to the replaced process's generation.
func TestProviderRestartBetweenSessionStartAndSendCompletesTurn(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()
	startFakeACPAgent(t, s, "codex")

	threadID := orchestration.ThreadID("thread-restart-before-send")
	// Listeners run before the engine answers the reactor's bound update, so
	// this restart lands after StartSession returned and before SendTurn.
	var once sync.Once
	stop := s.orchestration.OnEvent(func(event orchestration.Event) {
		session := event.Payload.Session
		if event.Type != orchestration.EventThreadSessionStatusSet || event.ThreadID() != threadID || session == nil || session.ProviderGeneration == 0 || session.Status != orchestration.SessionStatusRunning {
			return
		}
		once.Do(func() {
			if _, err := s.StartProvider(context.Background(), acpInstanceSpec("codex", "codex", fakeACPAgentCommand()), true); err != nil {
				t.Errorf("provider restart: %v", err)
			}
		})
	})
	defer stop()

	if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{Type: orchestration.CommandThreadCreate, CommandID: "cmd-create-restart-before-send", ThreadID: threadID, Title: "Restart before send", ProviderInstanceID: "codex", Cwd: t.TempDir()}); err != nil {
		t.Fatalf("thread.create: %v", err)
	}
	if _, err := s.orchestration.Dispatch(context.Background(), orchestration.Command{Type: orchestration.CommandThreadTurnStart, CommandID: "cmd-turn-restart-before-send", ThreadID: threadID, Message: &orchestration.CommandMessage{MessageID: "msg-restart-before-send", Text: "hello"}}); err != nil {
		t.Fatalf("thread.turn.start: %v", err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		entry, _ := s.orchestration.ThreadListEntry(threadID)
		if entry.LatestTurn != nil && entry.LatestTurn.State == orchestration.TurnStateCompleted {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	entry, _ := s.orchestration.ThreadListEntry(threadID)
	t.Fatalf("session = %+v, latest turn = %+v; want the turn completed by the replacement", entry.Session, entry.LatestTurn)
}

// The replaced process's own cancellation of its permission request is
// dropped with its other non-terminal events, so the settled turn must cancel
// the card; otherwise it stays pending and answering it fails at the provider.
func TestProviderRestartCancelsPendingApprovalOfReplacedProcess(t *testing.T) {
	s := newTestServer(t)
	defer s.Close()
	startFakeACPAgent(t, s, "codex")

	client := newRecordingClient(t, s)
	threadID := orchestration.ThreadID("thread-restart-cancels-approval")
	client.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadCreate, CommandID: "cmd-create-restart-approval", ThreadID: threadID, Title: "Restart approval", ProviderInstanceID: "codex", Cwd: t.TempDir()})
	client.subscribeThread(t, threadID)
	client.dispatch(t, orchestration.Command{Type: orchestration.CommandThreadTurnStart, CommandID: "cmd-turn-restart-approval", ThreadID: threadID, Message: &orchestration.CommandMessage{MessageID: "msg-restart-approval", Text: "permission"}})
	opened := client.waitForThreadEvent(t, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadApprovalOpened && event.Payload.Approval != nil
	})
	requestID := opened.Payload.Approval.RequestID
	if entry, _ := s.orchestration.ThreadListEntry(threadID); !entry.HasPendingApprovals {
		t.Fatalf("thread list entry = %#v, want a pending approval", entry)
	}

	if _, err := s.StartProvider(context.Background(), acpInstanceSpec("codex", "codex", fakeACPAgentCommand()), true); err != nil {
		t.Fatalf("provider restart: %v", err)
	}

	resolved := client.waitForThreadEvent(t, func(event orchestration.Event) bool {
		return event.Type == orchestration.EventThreadApprovalResolved && event.Payload.Approval != nil && event.Payload.Approval.RequestID == requestID
	})
	if !resolved.Payload.Approval.Cancelled || resolved.Payload.Approval.Decision != provider.ApprovalDecisionCancel {
		t.Fatalf("resolved = %#v, want the approval cancelled", resolved.Payload.Approval)
	}
	if entry, _ := s.orchestration.ThreadListEntry(threadID); entry.HasPendingApprovals {
		t.Fatalf("thread list entry = %#v, want no pending approvals", entry)
	}
	if _, err := client.dispatchErr(orchestration.Command{Type: orchestration.CommandThreadApprovalRespond, CommandID: "cmd-respond-restart-approval", ThreadID: threadID, RequestID: orchestration.ApprovalID(requestID), Decision: provider.ApprovalDecisionAccept}); err == nil || !strings.Contains(err.Error(), "already resolved") {
		t.Fatalf("answering the cancelled approval: err = %v, want it rejected as already resolved", err)
	}
}

// TestProviderCloseKillsWrappedAgentProcessTree guards against orphaning the
// real agent when the configured command is a wrapper (npx/npm exec): killing
// only the direct child would leak the agent process it spawned. The fake agent
// runs behind a non-exec'ing shell so it is a grandchild of the daemon.
func TestProviderCloseKillsWrappedAgentProcessTree(t *testing.T) {
	s := NewServer()
	dir := t.TempDir()
	pidPath := dir + "/agent.pid"
	// The trailing "exit $?" keeps the shell from exec-replacing itself with the
	// helper, so the helper stays a grandchild like npx's spawned agent.
	inner := fmt.Sprintf("MAID_DAEMON_ACP_HELPER=1 '%s' -test.run=TestHelperProcess -- -linger -pidfile '%s'; exit $?", os.Args[0], pidPath)
	if _, err := s.StartProvider(context.Background(), acpInstanceSpec("wrapped", "wrapped", []string{"/bin/sh", "-c", inner}), false); err != nil {
		t.Fatalf("provider start: %v", err)
	}
	waitForFile(t, pidPath)
	raw, err := os.ReadFile(pidPath)
	if err != nil {
		t.Fatalf("read helper pidfile: %v", err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		t.Fatalf("parse helper pid %q: %v", raw, err)
	}
	if err := syscall.Kill(pid, 0); err != nil {
		t.Fatalf("wrapped agent process %d not alive before close: %v", pid, err)
	}

	if err := s.Close(); err != nil {
		t.Fatalf("server close: %v", err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if err := syscall.Kill(pid, 0); err != nil {
			return // grandchild died with the process group
		}
		time.Sleep(10 * time.Millisecond)
	}
	_ = syscall.Kill(pid, 9)
	t.Fatalf("wrapped agent process %d survived server close (leaked agent)", pid)
}

func waitForFile(t *testing.T, path string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", path)
}

// TestInvariantViolationClosesServerAndSurfacesFromRunWebSocket pins fatal-path
// ownership: the server records the typed error, shuts down its listener, and
// returns the error to main, which remains the sole owner of process exit.
func TestInvariantViolationClosesServerAndSurfacesFromRunWebSocket(t *testing.T) {
	s := NewServer()

	runErr := make(chan error, 1)
	go func() { runErr <- s.RunWebSocket("127.0.0.1:0") }()
	// Give the listener a beat to install itself so Close tears it down.
	time.Sleep(50 * time.Millisecond)

	violation := &orchestration.InvariantViolationError{Cause: "test boom"}
	s.handleInvariantViolation(violation)

	select {
	case err := <-runErr:
		var got *orchestration.InvariantViolationError
		if !errors.As(err, &got) || got != violation {
			t.Fatalf("RunWebSocket returned %v, want the reported InvariantViolationError", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("RunWebSocket did not return after an invariant violation")
	}
	// The shutdown ran: a second Close is idempotent.
	if err := s.Close(); err != nil {
		t.Fatalf("second Close err = %v, want idempotent nil", err)
	}
}
