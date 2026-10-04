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

// A naturally exited run reports its exit code once, rejects input and
// restarts, but keeps a passive final model that reflows for a later
// attachment at a different grid.
func TestNaturalExitKeepsFinalModel(t *testing.T) {
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

	if err := session.Resize(100, 30); err != nil {
		t.Fatalf("resize retained model: %v", err)
	}
	snapshot := mustSessionSnapshot(t, session)
	if snapshot.Status != StatusExited || snapshot.ExitCode == nil || *snapshot.ExitCode != 7 {
		t.Fatalf("snapshot status = %s code %v, want exited 7", snapshot.Status, snapshot.ExitCode)
	}
	if snapshot.Columns != 100 || snapshot.Rows != 30 {
		t.Fatalf("snapshot size = %dx%d, want 100x30", snapshot.Columns, snapshot.Rows)
	}
	if !bytes.Contains(snapshot.Data, []byte("BEFORE-EXIT")) {
		t.Fatal("snapshot lost the final screen after natural exit")
	}
}

func TestRelaunchStartsFreshRun(t *testing.T) {
	useQuietZsh(t)
	svc := NewService()
	defer svc.Close()
	session, c := startTestSession(t, svc, "t1")
	if err := session.Write([]byte("printf 'OLD-RUN-OUT\\n'\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	waitFor(t, "old output", func() bool { return c.contains("OLD-RUN-OUT") })
	oldPID := shellPID(session)
	oldRunID := session.RunID

	c2 := newCollector()
	relaunched, err := svc.Relaunch("t1", SpawnSpec{Cwd: t.TempDir(), Columns: 90, Rows: 30}, c2.events())
	if err != nil {
		t.Fatalf("relaunch: %v", err)
	}
	t.Cleanup(func() { relaunched.Terminate(terminateGrace) })

	waitFor(t, "old shell death", func() bool { return syscall.Kill(oldPID, 0) != nil })
	if relaunched.RunID == oldRunID {
		t.Fatal("relaunch reused the old run id")
	}
	snapshot := mustSessionSnapshot(t, relaunched)
	if bytes.Contains(snapshot.Data, []byte("OLD-RUN-OUT")) {
		t.Fatal("relaunch kept old snapshot output")
	}
	if snapshot.Columns != 90 || snapshot.Rows != 30 {
		t.Fatalf("relaunch size = %dx%d, want 90x30", snapshot.Columns, snapshot.Rows)
	}

	// The relaunched shell is live and independent of the old run's state.
	if err := relaunched.Write([]byte("printf 'NEW-RUN-%d\\n' $((50+5))\n")); err != nil {
		t.Fatalf("write to relaunched: %v", err)
	}
	waitFor(t, "new output", func() bool { return c2.contains("NEW-RUN-55") })

	current, err := svc.Get("t1")
	if err != nil || current != relaunched {
		t.Fatal("service does not track the relaunched session")
	}
}
