package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
	"github.com/coder/websocket"
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
			_, err := newTestServer(t).StartProvider(context.Background(), tc.spec, false)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err = %v, want it to contain %q", err, tc.want)
			}
		})
	}
}

// Restarting a provider ends the turns its old process ran, and cancels
// their open requests: the old process can no longer settle or answer them.
func TestProviderRestartEndsTheOldProcessesTurnsAndRequests(t *testing.T) {
	s := newTestServer(t)
	startFakeACPAgent(t, s, "agent")
	client := newRecordingClient(t, s)
	blockedThread := client.createThread(t, "agent", t.TempDir()).Thread
	askingThread := client.createThread(t, "agent", t.TempDir()).Thread
	client.subscribe(t, blockedThread)
	client.subscribe(t, askingThread)
	gate := t.TempDir()
	blocked := client.deliver(t, blockedThread, "block "+gate).Delivery
	asking := client.deliver(t, askingThread, "permission").Delivery
	waitForFile(t, gate+"/ready")
	request := client.waitEvent(t, "the permission request", func(event orchestration.ThreadEvent) bool {
		return event.Kind == orchestration.EventRequest
	}).Request

	if _, err := s.StartProvider(context.Background(), acpInstanceSpec("agent", "agent", fakeACPAgentCommand()), true); err != nil {
		t.Fatalf("restart: %v", err)
	}
	for _, turn := range []orchestration.TurnView{client.waitSettled(t, blockedThread, blocked), client.waitSettled(t, askingThread, asking)} {
		if turn.State == provider.TurnCompleted || turn.State == provider.TurnRunning {
			t.Fatalf("turn of the replaced process = %s, want it ended", turn.State)
		}
	}
	client.waitEvent(t, "the request cancelled", func(event orchestration.ThreadEvent) bool {
		return event.Kind == orchestration.EventResolved && event.Resolved.Request == request.ID
	})
	_, err := client.commandErr(wire.CommandParams{Respond: &orchestration.Respond{Thread: askingThread, Request: request.ID, Action: request.Ask.Actions[0].ID}})
	if code, reason := commandCode(err); code != commandRefusedCode || reason != orchestration.CodeNotFound {
		t.Fatalf("answering the cancelled request = %v, want refused not found", err)
	}
	// The new process takes the chats' next messages.
	if turn := client.waitSettled(t, blockedThread, client.deliver(t, blockedThread, "hello").Delivery); turn.State != provider.TurnCompleted {
		t.Fatalf("turn on the new process = %s, want completed", turn.State)
	}
}

// Closing the daemon kills an agent behind a wrapper (npx, npm exec) too:
// killing only the direct child would leak the agent it spawned. The fake
// agent runs behind a shell that doesn't exec it, as a grandchild.
func TestProviderCloseKillsWrappedAgentProcessTree(t *testing.T) {
	s := newTestServer(t)
	pidPath := t.TempDir() + "/agent.pid"
	inner := fmt.Sprintf("MAID_DAEMON_ACP_HELPER=1 '%s' -test.run=TestHelperProcess -- -linger -pidfile '%s'; exit $?", os.Args[0], pidPath)
	if _, err := s.StartProvider(context.Background(), acpInstanceSpec("wrapped", "wrapped", []string{"/bin/sh", "-c", inner}), false); err != nil {
		t.Fatalf("provider start: %v", err)
	}
	pid := readPID(t, pidPath)
	if err := syscall.Kill(pid, 0); err != nil {
		t.Fatalf("wrapped agent %d not alive before close: %v", pid, err)
	}
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	defer func() { _ = syscall.Kill(pid, syscall.SIGKILL) }()
	waitUntil(t, "the wrapped agent to die with its process group", func() bool { return syscall.Kill(pid, 0) != nil })
}

// An engine that can't commit stops, and the daemon shuts down and returns
// the error from RunWebSocket, so main owns the exit.
func TestEngineFailureClosesServerAndSurfacesFromRunWebSocket(t *testing.T) {
	s := newTestServer(t)
	startFakeACPAgent(t, s, "agent")
	runErr := make(chan error, 1)
	go func() { runErr <- s.RunWebSocket("127.0.0.1:0") }()
	waitUntil(t, "the listener", func() bool {
		s.mu.Lock()
		defer s.mu.Unlock()
		return s.httpServer != nil
	})

	project, err := s.engine.AddProject(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	// The database going away under the engine, as a full or failed disk.
	_ = s.metadataStore.Close()
	_, _ = s.engine.Do(context.Background(), orchestration.Command{Actor: orchestration.Person("test"), Body: orchestration.CreateThread{
		Workspace: provider.Workspace{Cwd: project.Path}, Participant: orchestration.NewParticipant{Instance: "agent"},
	}})
	select {
	case err := <-runErr:
		if err == nil || err != s.engine.Err() {
			t.Fatalf("RunWebSocket = %v, want the engine's error %v", err, s.engine.Err())
		}
	case <-time.After(15 * time.Second):
		t.Fatal("RunWebSocket did not return after the engine stopped")
	}
	if err := s.Close(); err != nil {
		t.Fatalf("a second Close = %v, want nil", err)
	}
}

// Closing the daemon doesn't wait for a client that stopped reading, such as
// a suspended phone: the daemon's writes to it block, and only the pings
// would have given up on it.
func TestCloseDoesNotWaitForAClientThatStoppedReading(t *testing.T) {
	s := newTestServer(t)
	s.pingInterval = time.Hour
	attachment, err := s.engine.StoreAttachment(strings.Repeat("a", 4<<20))
	if err != nil {
		t.Fatal(err)
	}
	ws, _, err := websocket.Dial(context.Background(), newWSTestServer(t, s), nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	t.Cleanup(func() { _ = ws.CloseNow() })
	for id := range 16 {
		request := fmt.Sprintf(`{"jsonrpc":"2.0","id":%d,"method":%q,"params":{"id":%q}}`, id+1, wire.MethodAttachmentGet, attachment)
		if err := ws.Write(context.Background(), websocket.MessageText, []byte(request)); err != nil {
			t.Fatal(err)
		}
	}
	waitUntil(t, "the daemon's writes to the client to block", func() bool {
		s.rpcMu.Lock()
		defer s.rpcMu.Unlock()
		for _, client := range s.rpcClients {
			ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
			err := client.conn.Notify(ctx, wire.MethodThreadList, nil)
			cancel()
			return errors.Is(err, context.DeadlineExceeded)
		}
		return false
	})

	closed := make(chan error, 1)
	go func() { closed <- s.Close() }()
	select {
	case err := <-closed:
		if err != nil {
			t.Fatalf("close: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Close is still waiting for the client that stopped reading")
	}
}

// Closing the daemon stops agents and terminals at the same time, each
// within its grace: the terminal's program hears its hangup while an agent
// is still stopping, not after, and Close is done once the slowest is.
func TestCloseStopsAgentsAndTerminalsTogether(t *testing.T) {
	dir := t.TempDir()
	shell := filepath.Join(dir, "shell")
	script := fmt.Sprintf("#!/bin/sh\necho $$ > '%[1]s/shell.pid'\ntrap 'echo hup >> %[1]s/hup' HUP\ntrap '' TERM\nwhile :; do sleep 0.05; done\n", dir)
	if err := os.WriteFile(shell, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SHELL", shell)
	s := newTestServer(t)
	// An agent that ignores stdin closing and SIGTERM takes both of its
	// one-second graces before it is killed.
	startFakeACPAgent(t, s, "agent", "-linger", "-ignore-term", "-pidfile", filepath.Join(dir, "agent.pid"))
	createTestTerminal(t, newRecordingClient(t, s))
	agent, shellPID := readPID(t, filepath.Join(dir, "agent.pid")), readPID(t, filepath.Join(dir, "shell.pid"))

	started := time.Now()
	closed := make(chan error, 1)
	go func() { closed <- s.Close() }()
	waitForFile(t, filepath.Join(dir, "hup"))
	if syscall.Kill(agent, 0) != nil {
		t.Fatal("the terminal heard its hangup only after the agent was gone")
	}
	select {
	case err := <-closed:
		if err != nil {
			t.Fatalf("close: %v", err)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("Close did not return")
	}
	if elapsed := time.Since(started); elapsed < 2*time.Second || elapsed > 3*time.Second {
		t.Fatalf("Close took %v, want the agent's two 1 s graces (2 s), with the terminal's 1 s alongside", elapsed)
	}
	for name, pid := range map[string]int{"agent": agent, "terminal program": shellPID} {
		if syscall.Kill(pid, 0) == nil {
			t.Fatalf("the %s (pid %d) outlived Close", name, pid)
		}
	}
}

func readPID(t *testing.T, path string) int {
	t.Helper()
	waitForFile(t, path)
	var pid int
	waitUntil(t, path+" to hold a pid", func() bool {
		raw, err := os.ReadFile(path)
		if err != nil {
			return false
		}
		pid, err = strconv.Atoi(strings.TrimSpace(string(raw)))
		return err == nil
	})
	return pid
}
