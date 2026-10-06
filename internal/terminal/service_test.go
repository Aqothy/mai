package terminal

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"sync"
	"syscall"
	"testing"
	"time"
)

// collector gathers ordered session events for assertions.
type collector struct {
	mu       sync.Mutex
	output   bytes.Buffer
	lastSeq  uint64
	exits    int
	exitSeq  uint64
	status   Status
	exitCode *int
	exited   chan struct{}
}

func newCollector() *collector {
	return &collector{exited: make(chan struct{})}
}

func (c *collector) events() Events {
	return Events{
		Output: func(_, _ string, seq uint64, data []byte) {
			c.mu.Lock()
			defer c.mu.Unlock()
			c.lastSeq = seq
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

// shellPID is the session leader's pid; it is fixed once the shell starts.
func shellPID(session *Session) int {
	return session.cmd.Process.Pid
}

func waitForExit(t *testing.T, c *collector) {
	t.Helper()
	select {
	case <-c.exited:
	case <-time.After(15 * time.Second):
		t.Fatal("timed out waiting for exit event")
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

func TestTerminateKillsProcessGroup(t *testing.T) {
	useQuietZsh(t)
	svc := NewService()
	defer svc.Close()
	session, _ := startTestSession(t, svc, "t1")

	// exec replaces the shell so the leader pid is the long-running child.
	if err := session.Write([]byte("exec /bin/sleep 300\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	pid := shellPID(session)

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
	// Explicit termination discards the attach model.
	if _, err := session.Snapshot(); !errors.Is(err, ErrNotRunning) {
		t.Fatalf("terminated session snapshot error = %v, want ErrNotRunning", err)
	}
}

func TestTerminateKillsForegroundJob(t *testing.T) {
	useQuietZsh(t)
	svc := NewService()
	defer svc.Close()
	session, c := startTestSession(t, svc, "t1")

	// A foreground job under job control runs in its own process group. It
	// ignores SIGHUP, so the kernel's hangup on shell exit cannot kill it:
	// only Terminate signaling the foreground group does.
	if err := session.Write([]byte("sh -c 'trap \"\" HUP; echo JOB-$$-PID; exec /bin/sleep 300'\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	jobPID := regexp.MustCompile(`JOB-(\d+)-PID`)
	var pid int
	waitFor(t, "job start", func() bool {
		c.mu.Lock()
		defer c.mu.Unlock()
		match := jobPID.FindSubmatch(c.output.Bytes())
		if match == nil {
			return false
		}
		pid, _ = strconv.Atoi(string(match[1]))
		return true
	})
	t.Cleanup(func() { _ = syscall.Kill(pid, syscall.SIGKILL) })

	session.Terminate(terminateGrace)
	waitFor(t, "foreground job death", func() bool { return syscall.Kill(pid, 0) != nil })
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
		pids[i] = shellPID(session)
	}

	svc.Close()

	for _, pid := range pids {
		waitFor(t, "shell death", func() bool { return syscall.Kill(pid, 0) != nil })
	}
	if _, err := svc.Start("late", SpawnSpec{Cwd: t.TempDir(), Columns: 80, Rows: 24}, Events{}); !errors.Is(err, ErrServiceClosed) {
		t.Fatalf("start after close err = %v, want ErrServiceClosed", err)
	}
	if _, err := svc.Relaunch("t0", SpawnSpec{Cwd: t.TempDir(), Columns: 80, Rows: 24}, Events{}); !errors.Is(err, ErrServiceClosed) {
		t.Fatalf("relaunch after close err = %v, want ErrServiceClosed", err)
	}
}

func TestRemoveTerminatesAndForgets(t *testing.T) {
	useQuietZsh(t)
	svc := NewService()
	defer svc.Close()
	session, _ := startTestSession(t, svc, "t1")
	pid := shellPID(session)

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
