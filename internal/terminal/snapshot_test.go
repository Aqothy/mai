package terminal

import (
	"bytes"
	"errors"
	"syscall"
	"testing"
	"time"
)

func mustSessionSnapshot(t *testing.T, session *Session) Snapshot {
	t.Helper()
	snapshot, err := session.Snapshot()
	if err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	return snapshot
}

func TestNativeSnapshotEndsAtSnapshotSequence(t *testing.T) {
	useQuietZsh(t)
	svc := NewService()
	defer svc.Close()
	session, c := startTestSession(t, svc, "t1")

	if err := session.Write([]byte("printf 'SNAPSHOT-%d\\n' $((100+1))\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	waitFor(t, "output", func() bool { return c.contains("SNAPSHOT-101") })

	snapshot := mustSessionSnapshot(t, session)
	if snapshot.RunID != session.RunID {
		t.Fatalf("snapshot run id = %s, want %s", snapshot.RunID, session.RunID)
	}
	if snapshot.Status != StatusRunning {
		t.Fatalf("snapshot status = %s, want running", snapshot.Status)
	}
	if snapshot.SnapshotFormat != GhosttySnapshotFormat {
		t.Fatalf("snapshot format = %q, want %q", snapshot.SnapshotFormat, GhosttySnapshotFormat)
	}
	if !bytes.Contains(snapshot.Data, []byte("SNAPSHOT-101")) {
		t.Fatal("native snapshot missing prior output")
	}
	if snapshot.Sequence == 0 {
		t.Fatal("snapshot sequence not advanced by output")
	}
	if snapshot.Columns != 80 || snapshot.Rows != 24 {
		t.Fatalf("snapshot size = %dx%d, want 80x24", snapshot.Columns, snapshot.Rows)
	}
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
	c.mu.Lock()
	maxChunk := c.maxChunk
	c.mu.Unlock()
	if maxChunk > outputBatchSize {
		t.Fatalf("output notification = %d bytes, want at most %d", maxChunk, outputBatchSize)
	}
}

func TestSnapshotSurvivesNaturalExitAndClearsOnTerminate(t *testing.T) {
	useQuietZsh(t)
	svc := NewService()
	defer svc.Close()
	session, c := startTestSession(t, svc, "t1")

	if err := session.Write([]byte("printf 'BEFORE-EXIT\\n'; exit 7\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	select {
	case <-c.exited:
	case <-time.After(15 * time.Second):
		t.Fatal("timed out waiting for exit")
	}

	snapshot := mustSessionSnapshot(t, session)
	if snapshot.Status != StatusExited {
		t.Fatalf("status = %s, want exited", snapshot.Status)
	}
	if snapshot.ExitCode == nil || *snapshot.ExitCode != 7 {
		t.Fatalf("exit code = %v, want 7", snapshot.ExitCode)
	}
	if !bytes.Contains(snapshot.Data, []byte("BEFORE-EXIT")) {
		t.Fatal("snapshot discarded after natural exit")
	}

	// Explicit termination of a second session discards its snapshot.
	second, c2 := startTestSession(t, svc, "t2")
	if err := second.Write([]byte("printf 'SECOND-OUT\\n'\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	waitFor(t, "second output", func() bool { return c2.contains("SECOND-OUT") })
	second.Terminate(terminateGrace)
	if _, err := second.Snapshot(); !errors.Is(err, ErrNotRunning) {
		t.Fatalf("terminated session snapshot error = %v, want ErrNotRunning", err)
	}
}

func TestExitedSnapshotReflowsToAnAttachingGrid(t *testing.T) {
	useQuietZsh(t)
	svc := NewService()
	defer svc.Close()
	session, c := startTestSession(t, svc, "t1")

	if err := session.Write([]byte("printf 'FINAL-SCREEN\\n'; exit 0\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	select {
	case <-c.exited:
	case <-time.After(15 * time.Second):
		t.Fatal("timed out waiting for exit")
	}

	if err := session.Resize(100, 30); err != nil {
		t.Fatalf("resize retained model: %v", err)
	}
	snapshot := mustSessionSnapshot(t, session)
	if snapshot.Columns != 100 || snapshot.Rows != 30 {
		t.Fatalf("snapshot size = %dx%d, want 100x30", snapshot.Columns, snapshot.Rows)
	}
	if !bytes.Contains(snapshot.Data, []byte("FINAL-SCREEN")) {
		t.Fatal("reflowed snapshot lost final screen")
	}
}

func TestStartDoesNotReplaceExitedSession(t *testing.T) {
	useQuietZsh(t)
	svc := NewService()
	defer svc.Close()
	exited, collector := startTestSession(t, svc, "t1")
	if err := exited.Write([]byte("exit 0\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	select {
	case <-collector.exited:
	case <-time.After(15 * time.Second):
		t.Fatal("timed out waiting for exit")
	}

	if _, err := svc.Start("t1", SpawnSpec{Cwd: t.TempDir(), Columns: 80, Rows: 24}, Events{}); !errors.Is(err, ErrAlreadyExists) {
		t.Fatalf("start over exited session error = %v, want ErrAlreadyExists", err)
	}
	if _, err := exited.Snapshot(); err != nil {
		t.Fatalf("exited snapshot after rejected start: %v", err)
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
	oldPID := session.PID()
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

func TestRelaunchUnknownTerminalStartsIt(t *testing.T) {
	useQuietZsh(t)
	svc := NewService()
	defer svc.Close()

	session, err := svc.Relaunch("fresh", SpawnSpec{Cwd: t.TempDir(), Columns: 80, Rows: 24}, Events{})
	if err != nil {
		t.Fatalf("relaunch without prior run: %v", err)
	}
	t.Cleanup(func() { session.Terminate(terminateGrace) })
	if session.Status() != StatusRunning {
		t.Fatalf("status = %s, want running", session.Status())
	}
}

func TestRelaunchAfterCloseFails(t *testing.T) {
	useQuietZsh(t)
	svc := NewService()
	svc.Close()
	if _, err := svc.Relaunch("t1", SpawnSpec{Cwd: t.TempDir(), Columns: 80, Rows: 24}, Events{}); !errors.Is(err, ErrServiceClosed) {
		t.Fatalf("relaunch after close err = %v, want ErrServiceClosed", err)
	}
}
