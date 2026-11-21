// Package store opens the daemon's SQLite database. The orchestration ledger
// and session cache own its tables.
package store

import (
	"database/sql"
	"fmt"
	"net/url"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite"
)

// SQLite wraps the daemon's single database file, shared by the orchestration
// ledger (DB).
type SQLite struct {
	db *sql.DB
}

// Open opens or creates the database at path with schemas. version names that
// layout as a whole. maiD is unreleased and keeps no migrations: a file of
// another version is renamed beside it (path.<its version>.old) rather than
// changed, and a new one started.
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
			for _, schema := range schemas {
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
