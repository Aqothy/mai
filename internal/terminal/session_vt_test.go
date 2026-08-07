package terminal

// Attach snapshots are exported from the daemon's terminal model instead of
// replaying raw byte history or synthesizing an approximate VT redraw.

import (
	"strings"
	"testing"
	"time"
)

func TestSessionSnapshotIsExportedFromModel(t *testing.T) {
	svc := NewService()
	defer svc.Close()
	session, err := svc.Start("t1", SpawnSpec{Cwd: t.TempDir(), Columns: 80, Rows: 24}, Events{})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	if err := session.Write([]byte("printf 'SYNTH-%d\\n' $((40+2))\n")); err != nil {
		t.Fatalf("Write: %v", err)
	}

	deadline := time.Now().Add(15 * time.Second)
	for {
		snapshot := mustSessionSnapshot(t, session)
		if strings.Contains(string(snapshot.Data), "SYNTH-42") {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("marker never appeared in native snapshot")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestSessionSnapshotFollowsResizeBeforeAttach(t *testing.T) {
	svc := NewService()
	defer svc.Close()
	session, err := svc.Start("t1", SpawnSpec{Cwd: t.TempDir(), Columns: 80, Rows: 24}, Events{})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	if err := session.Resize(120, 40); err != nil {
		t.Fatalf("Resize: %v", err)
	}
	snapshot := mustSessionSnapshot(t, session)
	if snapshot.Columns != 120 || snapshot.Rows != 40 {
		t.Fatalf("snapshot grid %dx%d, want 120x40", snapshot.Columns, snapshot.Rows)
	}
}
