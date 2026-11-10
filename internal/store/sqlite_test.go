package store

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// testLayout is a layout version for the tests' files.
const testLayout = 7

func openTestStore(t *testing.T) *SQLite {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "maid.db"), testLayout)
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

	const ledger = `CREATE TABLE IF NOT EXISTS threads (thread_id TEXT PRIMARY KEY, title TEXT NOT NULL) STRICT`
	s, err := Open(path, testLayout, ledger)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer s.Close()
	// The new file has the caller's tables as it declares them, and the old
	// file's row isn't in them.
	var threads int
	if err := s.DB().QueryRow(`SELECT COUNT(title) FROM threads`).Scan(&threads); err != nil || threads != 0 {
		t.Fatalf("threads in the new file: %d, %v; want the new table, empty", threads, err)
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
	again, err := Open(path, testLayout, ledger)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer again.Close()
	if err := again.UpsertTerminal(TerminalMeta{TerminalID: "x", Cwd: "/"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(fmt.Sprintf("%s.%d.old", path, testLayout)); !os.IsNotExist(err) {
		t.Fatalf("the current layout was set aside: %v", err)
	}
}
