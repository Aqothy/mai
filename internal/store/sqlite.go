package store

import (
	"database/sql"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

// SQLite implements TerminalStore in one database file, which the
// orchestration ledger shares (DB).
type SQLite struct {
	db *sql.DB
}

var _ TerminalStore = (*SQLite)(nil)

// terminalSchema is the one table this package keeps. It is part of the
// file's layout, which the caller of Open versions.
const terminalSchema = `
CREATE TABLE IF NOT EXISTS terminal_threads (
	terminal_id TEXT PRIMARY KEY,
	title       TEXT NOT NULL DEFAULT '',
	cwd         TEXT NOT NULL,
	created_at  TEXT NOT NULL,
	updated_at  TEXT NOT NULL
) STRICT;
`

// Open opens or creates the database at path, with this package's table and
// those of schemas. version names that layout as a whole. maiD is unreleased
// and keeps no migrations: a file of another version is renamed beside it
// (path.<its version>.old) rather than changed, and a new one started.
func Open(path string, version int, schemas ...string) (*SQLite, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("store: create data directory: %w", err)
	}
	for {
		db, err := open(path)
		if err != nil {
			return nil, err
		}
		var found int
		if err := db.QueryRow(`PRAGMA user_version`).Scan(&found); err != nil {
			_ = db.Close()
			return nil, fmt.Errorf("store: read schema version: %w", err)
		}
		var tables int
		_ = db.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'`).Scan(&tables)
		if found == version || tables == 0 {
			for _, schema := range append([]string{terminalSchema}, schemas...) {
				if _, err := db.Exec(schema); err != nil {
					_ = db.Close()
					return nil, fmt.Errorf("store: ensure schema: %w", err)
				}
			}
			if _, err := db.Exec(fmt.Sprintf(`PRAGMA user_version = %d`, version)); err != nil {
				_ = db.Close()
				return nil, fmt.Errorf("store: set schema version: %w", err)
			}
			return &SQLite{db: db}, nil
		}
		_ = db.Close()
		aside := fmt.Sprintf("%s.%d.old", path, found)
		for _, suffix := range []string{"", "-wal", "-shm"} {
			if err := os.Rename(path+suffix, aside+suffix); err != nil && !os.IsNotExist(err) {
				return nil, fmt.Errorf("store: set aside database of layout %d: %w", found, err)
			}
		}
	}
}

func open(path string) (*sql.DB, error) {
	dsn := "file:" + url.PathEscape(path) +
		"?_pragma=busy_timeout(5000)" +
		"&_pragma=journal_mode(WAL)" +
		"&_pragma=synchronous(NORMAL)" +
		"&_pragma=foreign_keys(1)" +
		"&_txlock=immediate"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("store: open %s: %w", path, err)
	}
	// WAL lets reads (snapshots, pages) run beside the engine's writes; the
	// immediate transactions serialize writers.
	db.SetMaxOpenConns(4)
	return db, nil
}

// DB is the database handle, for the orchestration ledger.
func (s *SQLite) DB() *sql.DB { return s.db }

func (s *SQLite) Close() error {
	return s.db.Close()
}

func (s *SQLite) UpsertTerminal(meta TerminalMeta) error {
	if meta.TerminalID == "" {
		return fmt.Errorf("store: upsert terminal requires a terminal id")
	}
	_, err := s.db.Exec(`INSERT INTO terminal_threads (terminal_id, title, cwd, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT (terminal_id) DO UPDATE SET
			title = excluded.title,
			cwd = excluded.cwd,
			created_at = excluded.created_at,
			updated_at = excluded.updated_at`,
		meta.TerminalID, meta.Title, meta.Cwd, timestamp(meta.CreatedAt), timestamp(meta.UpdatedAt))
	if err != nil {
		return fmt.Errorf("store: upsert terminal %q: %w", meta.TerminalID, err)
	}
	return nil
}

func (s *SQLite) DeleteTerminal(terminalID string) error {
	if _, err := s.db.Exec(`DELETE FROM terminal_threads WHERE terminal_id = ?`, terminalID); err != nil {
		return fmt.Errorf("store: delete terminal %q: %w", terminalID, err)
	}
	return nil
}

func (s *SQLite) ListTerminals() ([]TerminalMeta, error) {
	rows, err := s.db.Query(`SELECT terminal_id, title, cwd, created_at, updated_at
		FROM terminal_threads ORDER BY updated_at DESC, terminal_id`)
	if err != nil {
		return nil, fmt.Errorf("store: list terminals: %w", err)
	}
	defer rows.Close()
	var terminals []TerminalMeta
	for rows.Next() {
		var meta TerminalMeta
		var createdAt, updatedAt string
		if err := rows.Scan(&meta.TerminalID, &meta.Title, &meta.Cwd, &createdAt, &updatedAt); err != nil {
			return nil, fmt.Errorf("store: scan terminal: %w", err)
		}
		meta.CreatedAt = parseTimestamp(createdAt)
		meta.UpdatedAt = parseTimestamp(updatedAt)
		terminals = append(terminals, meta)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: list terminals: %w", err)
	}
	return terminals, nil
}

// timestamp stores times as fixed-width RFC3339 UTC (9 fraction digits) so
// lexical ordering matches chronological ordering (ListThreads sorts by the
// TEXT column). RFC3339Nano would trim trailing zeros and break that.
func timestamp(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05.000000000Z07:00")
}

func parseTimestamp(value string) time.Time {
	t, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return time.Time{}
	}
	return t
}
