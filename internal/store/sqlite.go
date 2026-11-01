package store

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"time"

	"github.com/Aqothy/maiD/internal/provider"

	_ "modernc.org/sqlite"
)

// SQLite implements the store interfaces in one database file, which the
// orchestration ledger shares (DB).
type SQLite struct {
	db *sql.DB
}

var _ InstanceStore = (*SQLite)(nil)
var _ TerminalStore = (*SQLite)(nil)

// schemaVersion is the layout of every table in the file, the ledger's
// included. maiD is unreleased and keeps no migrations: a file of another
// layout is set aside and a new one started.
const schemaVersion = 1

const schema = `
CREATE TABLE IF NOT EXISTS instances (
	instance_id TEXT PRIMARY KEY,
	name        TEXT NOT NULL DEFAULT '',
	driver_kind TEXT NOT NULL,
	config      TEXT
) STRICT;

CREATE TABLE IF NOT EXISTS terminal_threads (
	terminal_id TEXT PRIMARY KEY,
	title       TEXT NOT NULL DEFAULT '',
	cwd         TEXT NOT NULL,
	created_at  TEXT NOT NULL,
	updated_at  TEXT NOT NULL
) STRICT;
`

// Open opens or creates the database at path. A file of an older layout is
// renamed beside it (path.<version>.old) rather than changed.
func Open(path string) (*SQLite, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("store: create data directory: %w", err)
	}
	for {
		db, err := open(path)
		if err != nil {
			return nil, err
		}
		var version int
		if err := db.QueryRow(`PRAGMA user_version`).Scan(&version); err != nil {
			_ = db.Close()
			return nil, fmt.Errorf("store: read schema version: %w", err)
		}
		var tables int
		_ = db.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'`).Scan(&tables)
		if version == schemaVersion || tables == 0 {
			if _, err := db.Exec(schema); err != nil {
				_ = db.Close()
				return nil, fmt.Errorf("store: ensure schema: %w", err)
			}
			if _, err := db.Exec(fmt.Sprintf(`PRAGMA user_version = %d`, schemaVersion)); err != nil {
				_ = db.Close()
				return nil, fmt.Errorf("store: set schema version: %w", err)
			}
			return &SQLite{db: db}, nil
		}
		_ = db.Close()
		aside := fmt.Sprintf("%s.%d.old", path, version)
		for _, suffix := range []string{"", "-wal", "-shm"} {
			if err := os.Rename(path+suffix, aside+suffix); err != nil && !os.IsNotExist(err) {
				return nil, fmt.Errorf("store: set aside database of layout %d: %w", version, err)
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

func (s *SQLite) SaveInstance(spec provider.InstanceSpec) error {
	if spec.InstanceID == "" {
		return fmt.Errorf("store: save instance requires an instance id")
	}
	if spec.Driver == "" {
		return fmt.Errorf("store: save instance %q requires a driver", spec.InstanceID)
	}
	_, err := s.db.Exec(`INSERT INTO instances (instance_id, name, driver_kind, config)
		VALUES (?, ?, ?, ?)
		ON CONFLICT (instance_id) DO UPDATE SET
			name = excluded.name,
			driver_kind = excluded.driver_kind,
			config = excluded.config`,
		string(spec.InstanceID), spec.Name, string(spec.Driver), nullableText(string(spec.Config)))
	if err != nil {
		return fmt.Errorf("store: save instance %q: %w", spec.InstanceID, err)
	}
	return nil
}

func (s *SQLite) LoadInstances() ([]provider.InstanceSpec, error) {
	rows, err := s.db.Query(`SELECT instance_id, name, driver_kind, config FROM instances ORDER BY instance_id`)
	if err != nil {
		return nil, fmt.Errorf("store: load instances: %w", err)
	}
	defer rows.Close()
	var specs []provider.InstanceSpec
	for rows.Next() {
		var instanceID, name, driver string
		var config sql.NullString
		if err := rows.Scan(&instanceID, &name, &driver, &config); err != nil {
			return nil, fmt.Errorf("store: scan instance: %w", err)
		}
		spec := provider.InstanceSpec{InstanceID: provider.InstanceID(instanceID), Name: name, Driver: provider.DriverKind(driver)}
		if config.Valid && config.String != "" {
			spec.Config = json.RawMessage(config.String)
		}
		specs = append(specs, spec)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: load instances: %w", err)
	}
	return specs, nil
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

func nullableText(value string) any {
	if value == "" {
		return nil
	}
	return value
}
