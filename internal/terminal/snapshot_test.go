package terminal

import (
	"bytes"
	"errors"
	"syscall"
	"testing"
)

func mustSessionSnapshot(t *testing.T, session *Session) Snapshot {
	t.Helper()
	snapshot, err := session.Snapshot()
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	return snapshot
}

func TestSnapshotAfterLargeOutputIsCappedAndTruncated(t *testing.T) {
	useQuietZsh(t)
	svc := NewService()
	defer svc.Close()
	session, c := startTestSession(t, svc, "t1")

	// The marker is computed by the shell so the echoed input line cannot
	// satisfy the wait before the burst has actually streamed through.
	if err := session.Write([]byte("head -c 4194304 /dev/zero | tr '\\0' 'x'; printf '\\nBURST-%d\\n' $((7000+7))\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	waitFor(t, "burst completion", func() bool { return c.contains("BURST-7007") })

	snapshot := mustSessionSnapshot(t, session)
	// The attach model retains bounded scrollback; old lines drop off
	// silently and the exported model must stay well under the burst size.
	if len(snapshot.Data) > 3*1024*1024 {
		t.Fatalf("native snapshot = %d bytes, want bounded", len(snapshot.Data))
	}
	if !bytes.Contains(snapshot.Data, []byte("BURST-7007")) {
		t.Fatal("snapshot lost the newest output")
	}
}

// A naturally exited run reports its exit code once and rejects input and
// restarts. The retained final model at a new grid is owned by the daemon
// attach-after-exit test.
func TestNaturalExitReportsOnceAndRejectsInput(t *testing.T) {
	useQuietZsh(t)
	svc := NewService()
	defer svc.Close()
	session, c := startTestSession(t, svc, "t1")

	if err := session.Write([]byte("printf 'BEFORE-EXIT\\n'; exit 7\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	waitForExit(t, c)
	<-session.Done()

	c.mu.Lock()
	if c.exits != 1 || c.status != StatusExited || c.exitCode == nil || *c.exitCode != 7 {
		c.mu.Unlock()
		t.Fatalf("exit events = %d status %s code %v, want one exited 7", c.exits, c.status, c.exitCode)
	}
	// The exit event carries the final sequence.
	if c.exitSeq < c.lastSeq {
		c.mu.Unlock()
		t.Fatalf("exit seq %d before output seq %d", c.exitSeq, c.lastSeq)
	}
	c.mu.Unlock()

	if err := session.Write([]byte("echo nope\n")); !errors.Is(err, ErrNotRunning) {
		t.Fatalf("write after exit err = %v, want ErrNotRunning", err)
	}
	if _, err := svc.Start("t1", SpawnSpec{Cwd: t.TempDir(), Columns: 80, Rows: 24}, Events{}); !errors.Is(err, ErrAlreadyExists) {
		t.Fatalf("start over exited session error = %v, want ErrAlreadyExists", err)
	}
}

// Run fencing and fresh output are owned by the daemon relaunch test; this
// covers the old process and the service's session tracking.
func TestRelaunchReplacesRun(t *testing.T) {
	useQuietZsh(t)
	svc := NewService()
	defer svc.Close()
	session, _ := startTestSession(t, svc, "t1")
	oldPID := shellPID(session)

	relaunched, err := svc.Relaunch("t1", SpawnSpec{Cwd: t.TempDir(), Columns: 90, Rows: 30}, Events{})
	if err != nil {
		t.Fatalf("relaunch: %v", err)
	}
	t.Cleanup(func() { relaunched.Terminate(terminateGrace) })

	waitFor(t, "old shell death", func() bool { return syscall.Kill(oldPID, 0) != nil })
	if snapshot := mustSessionSnapshot(t, relaunched); snapshot.Columns != 90 || snapshot.Rows != 30 {
		t.Fatalf("relaunch size = %dx%d, want 90x30", snapshot.Columns, snapshot.Rows)
	}
	if current, err := svc.Get("t1"); err != nil || current != relaunched {
		t.Fatal("service does not track the relaunched session")
	}
}
