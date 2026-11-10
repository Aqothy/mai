package store

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func openTestStore(t *testing.T) *SQLite {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "maid.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

// A database of another layout is set aside, not changed, and a new one
// starts in its place.
func TestOpenSetsAsideADatabaseOfAnotherLayout(t *testing.T) {
	path := filepath.Join(t.TempDir(), "maid.db")
	old, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := old.Exec(`CREATE TABLE threads (thread_id TEXT PRIMARY KEY); INSERT INTO threads VALUES ('kept')`); err != nil {
		t.Fatal(err)
	}
	_ = old.Close()

	s, err := Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer s.Close()
	var tables int
	if err := s.DB().QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE name = 'threads'`).Scan(&tables); err != nil || tables != 0 {
		t.Fatalf("old table in the new file: %d, %v", tables, err)
	}
	if _, err := os.Stat(path + ".0.old"); err != nil {
		t.Fatalf("the old file wasn't kept: %v", err)
	}
	aside, err := sql.Open("sqlite", "file:"+path+".0.old")
	if err != nil {
		t.Fatal(err)
	}
	defer aside.Close()
	var kept string
	if err := aside.QueryRow(`SELECT thread_id FROM threads`).Scan(&kept); err != nil || kept != "kept" {
		t.Fatalf("old data = %q, %v", kept, err)
	}

	// Reopening the new file keeps it.
	_ = s.Close()
	again, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer again.Close()
	if err := again.UpsertTerminal(TerminalMeta{TerminalID: "x", Cwd: "/"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(fmt.Sprintf("%s.%d.old", path, schemaVersion)); !os.IsNotExist(err) {
		t.Fatalf("the current layout was set aside: %v", err)
	}
}
