package terminal

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"testing"
	"time"
)

// collector gathers ordered session events for assertions.
type collector struct {
	mu        sync.Mutex
	output    bytes.Buffer
	lastSeq   uint64
	seqBroken bool
	maxChunk  int
	exits     int
	exitSeq   uint64
	status    Status
	exitCode  *int
	exited    chan struct{}
}

func newCollector() *collector {
	return &collector{exited: make(chan struct{})}
}

func (c *collector) events() Events {
	return Events{
		Output: func(_, _ string, seq uint64, data []byte) {
			c.mu.Lock()
			defer c.mu.Unlock()
			if seq <= c.lastSeq {
				c.seqBroken = true
			}
			c.lastSeq = seq
			c.maxChunk = max(c.maxChunk, len(data))
			c.output.Write(data)
		},
		Exit: func(_, _ string, seq uint64, status Status, exitCode *int) {
			c.mu.Lock()
			c.exits++
			c.exitSeq = seq
			c.status = status
			c.exitCode = exitCode
			c.mu.Unlock()
			close(c.exited)
		},
	}
}

func (c *collector) contains(marker string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return bytes.Contains(c.output.Bytes(), []byte(marker))
}

// useQuietZsh keeps login-shell startup deterministic by pointing zsh at an
// empty ZDOTDIR so the developer's rc files do not run.
func useQuietZsh(t *testing.T) {
	t.Helper()
	t.Setenv("SHELL", "/bin/zsh")
	t.Setenv("ZDOTDIR", t.TempDir())
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func startTestSession(t *testing.T, svc *Service, id string) (*Session, *collector) {
	t.Helper()
	c := newCollector()
	session, err := svc.Start(id, SpawnSpec{Cwd: t.TempDir(), Columns: 80, Rows: 24}, c.events())
	if err != nil {
		t.Fatalf("start session: %v", err)
	}
	t.Cleanup(func() { session.Terminate(terminateGrace) })
	return session, c
}

func TestShellRunsCommandAndStreamsOrderedOutput(t *testing.T) {
	useQuietZsh(t)
	svc := NewService()
	defer svc.Close()
	session, c := startTestSession(t, svc, "t1")

	// The marker is computed by the shell so the echoed input line cannot
	// satisfy the assertion.
	if err := session.Write([]byte("printf 'MAID-%d\\n' $((1000+2))\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	waitFor(t, "command output", func() bool { return c.contains("MAID-1002") })

	c.mu.Lock()
	broken := c.seqBroken
	c.mu.Unlock()
	if broken {
		t.Fatal("output sequence was not strictly monotonic")
	}
	if session.Status() != StatusRunning {
		t.Fatalf("status = %s, want running", session.Status())
	}
}

func TestResizeChangesSttySize(t *testing.T) {
	useQuietZsh(t)
	svc := NewService()
	defer svc.Close()
	session, c := startTestSession(t, svc, "t1")

	if err := session.Resize(101, 41); err != nil {
		t.Fatalf("resize: %v", err)
	}
	if err := session.Write([]byte("printf 'SIZE-%s-END\\n' \"$(stty size | tr ' ' 'x')\"\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	waitFor(t, "stty output", func() bool { return c.contains("SIZE-41x101-END") })

	if cols, rows := session.Size(); cols != 101 || rows != 41 {
		t.Fatalf("size = %dx%d, want 101x41", cols, rows)
	}
	// Unchanged dimensions dedupe without error.
	if err := session.Resize(101, 41); err != nil {
		t.Fatalf("dedupe resize: %v", err)
	}
}

func TestTerminateIdleShellReturnsWellUnderGrace(t *testing.T) {
	useQuietZsh(t)
	svc := NewService()
	defer svc.Close()
	session, c := startTestSession(t, svc, "t1")
	// Wait for an interactive prompt so the test exercises a shell that has
	// already installed its SIGTERM-ignoring interactive signal handling.
	if err := session.Write([]byte("printf 'READY-%d\\n' $((1+1))\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	waitFor(t, "shell readiness", func() bool { return c.contains("READY-2") })

	start := time.Now()
	session.Terminate(terminateGrace)
	if elapsed := time.Since(start); elapsed >= terminateGrace {
		t.Fatalf("terminate took %v; SIGHUP should end the shell before the %v grace", elapsed, terminateGrace)
	}
}

func TestInvalidDimensionsRejected(t *testing.T) {
	useQuietZsh(t)
	svc := NewService()
	defer svc.Close()

	_, err := svc.Start("bad", SpawnSpec{Cwd: t.TempDir(), Columns: 1, Rows: 24}, Events{})
	if !errors.Is(err, ErrInvalidDimensions) {
		t.Fatalf("start err = %v, want ErrInvalidDimensions", err)
	}

	session, _ := startTestSession(t, svc, "t1")
	if err := session.Resize(501, 24); !errors.Is(err, ErrInvalidDimensions) {
		t.Fatalf("resize err = %v, want ErrInvalidDimensions", err)
	}
}

func TestCwdValidation(t *testing.T) {
	svc := NewService()
	defer svc.Close()

	missing := filepath.Join(t.TempDir(), "missing")
	if _, err := svc.Start("m", SpawnSpec{Cwd: missing, Columns: 80, Rows: 24}, Events{}); !errors.Is(err, ErrInvalidCwd) {
		t.Fatalf("missing cwd err = %v, want ErrInvalidCwd", err)
	}

	file := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(file, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Start("f", SpawnSpec{Cwd: file, Columns: 80, Rows: 24}, Events{}); !errors.Is(err, ErrInvalidCwd) {
		t.Fatalf("file cwd err = %v, want ErrInvalidCwd", err)
	}

	if _, err := svc.Start("r", SpawnSpec{Cwd: "relative/path", Columns: 80, Rows: 24}, Events{}); !errors.Is(err, ErrInvalidCwd) {
		t.Fatalf("relative cwd err = %v, want ErrInvalidCwd", err)
	}

	home, err := ResolveCwd("")
	if err != nil {
		t.Fatalf("empty cwd: %v", err)
	}
	userHome, _ := os.UserHomeDir()
	if home != userHome {
		t.Fatalf("empty cwd resolved to %q, want home %q", home, userHome)
	}
}

func TestNaturalExitReportsExitCode(t *testing.T) {
	useQuietZsh(t)
	svc := NewService()
	defer svc.Close()
	session, c := startTestSession(t, svc, "t1")

	if err := session.Write([]byte("exit 3\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	select {
	case <-c.exited:
	case <-time.After(15 * time.Second):
		t.Fatal("timed out waiting for exit event")
	}
	<-session.Done()

	c.mu.Lock()
	defer c.mu.Unlock()
	if c.exits != 1 {
		t.Fatalf("exit events = %d, want 1", c.exits)
	}
	if c.status != StatusExited {
		t.Fatalf("exit status = %s, want exited", c.status)
	}
	if c.exitCode == nil || *c.exitCode != 3 {
		t.Fatalf("exit code = %v, want 3", c.exitCode)
	}
	if c.exitSeq <= c.lastSeq-1 {
		// The exit event must carry the final sequence.
		t.Fatalf("exit seq %d not after output seq", c.exitSeq)
	}
	if err := session.Write([]byte("echo nope\n")); !errors.Is(err, ErrNotRunning) {
		t.Fatalf("write after exit err = %v, want ErrNotRunning", err)
	}
	// A naturally exited run rejects input but keeps a passive final model
	// that can reflow for a later attachment at a different grid.
	if err := session.Resize(90, 30); err != nil {
		t.Fatalf("resize retained model after exit: %v", err)
	}
	if columns, rows := session.Size(); columns != 90 || rows != 30 {
		t.Fatalf("size after final-model reflow = %dx%d, want 90x30", columns, rows)
	}
}

func TestTerminateKillsProcessGroup(t *testing.T) {
	useQuietZsh(t)
	svc := NewService()
	defer svc.Close()
	session, _ := startTestSession(t, svc, "t1")

	// exec replaces the shell so the leader pid is the long-running child.
	if err := session.Write([]byte("exec /bin/sleep 300\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	pid := session.PID()

	done := make(chan struct{})
	go func() {
		if err := svc.Terminate("t1"); err != nil {
			t.Errorf("terminate: %v", err)
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(terminateGrace + 10*time.Second):
		t.Fatal("terminate did not return")
	}

	waitFor(t, "process death", func() bool {
		return syscall.Kill(pid, 0) != nil
	})
	if session.Status() != StatusStopped {
		t.Fatalf("status = %s, want stopped", session.Status())
	}
}

func TestTerminateKillsForegroundJob(t *testing.T) {
	useQuietZsh(t)
	svc := NewService()
	defer svc.Close()
	session, c := startTestSession(t, svc, "t1")

	// A foreground job under job control runs in its own process group.
	if err := session.Write([]byte("echo START-$$; /bin/sleep 300\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	waitFor(t, "job start", func() bool { return c.contains("START-") })

	start := time.Now()
	session.Terminate(terminateGrace)
	if elapsed := time.Since(start); elapsed > terminateGrace+10*time.Second {
		t.Fatalf("terminate took %s", elapsed)
	}
	<-session.Done()
}

func TestServiceCloseTerminatesAllSessions(t *testing.T) {
	useQuietZsh(t)
	svc := NewService()
	var sessions []*Session
	for i := range 3 {
		session, _ := startTestSession(t, svc, fmt.Sprintf("t%d", i))
		sessions = append(sessions, session)
	}
	pids := make([]int, len(sessions))
	for i, session := range sessions {
		pids[i] = session.PID()
	}

	svc.Close()

	for _, pid := range pids {
		waitFor(t, "shell death", func() bool { return syscall.Kill(pid, 0) != nil })
	}
	if _, err := svc.Start("late", SpawnSpec{Cwd: t.TempDir(), Columns: 80, Rows: 24}, Events{}); !errors.Is(err, ErrServiceClosed) {
		t.Fatalf("start after close err = %v, want ErrServiceClosed", err)
	}
}

func TestStartTwiceFails(t *testing.T) {
	useQuietZsh(t)
	svc := NewService()
	defer svc.Close()
	startTestSession(t, svc, "t1")

	if _, err := svc.Start("t1", SpawnSpec{Cwd: t.TempDir(), Columns: 80, Rows: 24}, Events{}); !errors.Is(err, ErrAlreadyExists) {
		t.Fatalf("second start err = %v, want ErrAlreadyExists", err)
	}
}

func TestRemoveTerminatesAndForgets(t *testing.T) {
	useQuietZsh(t)
	svc := NewService()
	defer svc.Close()
	session, _ := startTestSession(t, svc, "t1")
	pid := session.PID()

	if err := svc.Remove("t1"); err != nil {
		t.Fatalf("remove: %v", err)
	}
	waitFor(t, "shell death", func() bool { return syscall.Kill(pid, 0) != nil })
	if _, err := svc.Get("t1"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("get after remove err = %v, want ErrNotFound", err)
	}
	if err := svc.Terminate("t1"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("terminate after remove err = %v, want ErrNotFound", err)
	}
}

func TestSessionEnvironmentOverrides(t *testing.T) {
	useQuietZsh(t)
	t.Setenv("TERM", "dumb")
	svc := NewService()
	defer svc.Close()
	session, c := startTestSession(t, svc, "t1")

	if err := session.Write([]byte("printf 'ENV-%s-%s-END\\n' \"$TERM\" \"$TERM_PROGRAM\"\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	waitFor(t, "env output", func() bool { return c.contains("ENV-xterm-256color-maiD-END") })
}
