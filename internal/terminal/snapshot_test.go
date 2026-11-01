package terminal

import (
	"bytes"
	"errors"
	"strings"
	"syscall"
	"testing"

	libghostty "go.mitchellh.com/libghostty"
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
	// The exit is the run's last event.
	if c.outputAfterExit > 0 {
		c.mu.Unlock()
		t.Fatalf("%d output events after the exit", c.outputAfterExit)
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

// Observe's snapshot holds exactly the output delivered before it: an
// observer that then receives the output after it neither misses nor
// repeats any. Observed many times through a flood, where output is nearly
// always on its way from the PTY to the run's terminal and its listeners.
func TestObserveSnapshotHoldsExactlyTheOutputDeliveredBeforeIt(t *testing.T) {
	svc := NewService()
	defer svc.Close()
	c := newCollector()
	session, err := svc.Start("t1", SpawnSpec{
		Cwd: t.TempDir(), Columns: 80, Rows: 24, Command: []string{"/usr/bin/seq", "-f", "LINE-%g", "1", "1000000"},
	}, c.events())
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	const observations = 40
	for observed := 0; observed < observations; {
		select {
		case <-c.exited:
			t.Fatalf("the flood ended after %d observations, want %d during it", observed, observations)
		default:
		}
		var data []byte
		var delivered string
		err := session.Observe(func(snapshot Snapshot) {
			data = snapshot.Data
			c.mu.Lock()
			delivered = lastLine(c.output.String())
			c.mu.Unlock()
		})
		if err != nil {
			t.Fatalf("observe: %v", err)
		}
		if delivered == "" {
			continue
		}
		if shown := lastLine(snapshotText(t, data)); shown != delivered {
			t.Fatalf("snapshot ends at %q, but the output delivered before it ends at %q", shown, delivered)
		}
		observed++
	}
}

// lastLine is text's last line that isn't empty.
func lastLine(text string) string {
	lines := strings.Fields(strings.ReplaceAll(text, "\r", ""))
	if len(lines) == 0 {
		return ""
	}
	return lines[len(lines)-1]
}

// snapshotText decodes a snapshot as a client does and returns its text.
func snapshotText(t *testing.T, data []byte) string {
	t.Helper()
	decoder, err := libghostty.NewSnapshotDecoderBytes(data)
	if err != nil {
		t.Fatalf("snapshot decoder: %v", err)
	}
	defer decoder.Close()
	term, err := decoder.Decode()
	if err != nil {
		t.Fatalf("decode snapshot: %v", err)
	}
	defer term.Close()
	formatter, err := libghostty.NewFormatter(term, libghostty.WithFormatterFormat(libghostty.FormatterFormatPlain))
	if err != nil {
		t.Fatalf("formatter: %v", err)
	}
	defer formatter.Close()
	text, err := formatter.FormatString()
	if err != nil {
		t.Fatalf("format: %v", err)
	}
	return text
}
