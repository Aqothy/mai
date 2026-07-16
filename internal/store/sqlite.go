package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"time"

	"github.com/Aqothy/maiD/internal/provider"

	_ "modernc.org/sqlite"
)

// SQLite implements RouteStore and ThreadStore in one database file.
type SQLite struct {
	db *sql.DB
}

var _ RouteStore = (*SQLite)(nil)
var _ ThreadStore = (*SQLite)(nil)
var _ ImportStore = (*SQLite)(nil)

const schema = `
CREATE TABLE IF NOT EXISTS threads (
	thread_id            TEXT PRIMARY KEY,
	title                TEXT NOT NULL DEFAULT '',
	cwd                  TEXT NOT NULL DEFAULT '',
	provider_instance_id TEXT NOT NULL DEFAULT '',
	model_selection      TEXT,
	created_at           TEXT NOT NULL,
	updated_at           TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS instances (
	instance_id TEXT PRIMARY KEY,
	name        TEXT NOT NULL DEFAULT '',
	driver_kind TEXT NOT NULL,
	config      TEXT
) STRICT;

CREATE TABLE IF NOT EXISTS thread_routes (
	thread_id           TEXT PRIMARY KEY,
	instance_id         TEXT NOT NULL REFERENCES instances(instance_id),
	provider_session_id TEXT NOT NULL DEFAULT '',
	resume_cursor       TEXT,
	start_input         TEXT
) STRICT;

CREATE UNIQUE INDEX IF NOT EXISTS thread_routes_provider_session
ON thread_routes(instance_id, provider_session_id)
WHERE provider_session_id <> '';

CREATE TABLE IF NOT EXISTS provider_session_imports (
	instance_id         TEXT NOT NULL REFERENCES instances(instance_id),
	provider_session_id TEXT NOT NULL,
	thread_id           TEXT NOT NULL REFERENCES threads(thread_id) ON DELETE CASCADE,
	PRIMARY KEY (instance_id, provider_session_id)
) STRICT;
`

// Open opens or creates the metadata database at path.
func Open(path string) (*SQLite, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("store: create data directory: %w", err)
	}
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
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(schema); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("store: ensure schema: %w", err)
	}
	return &SQLite{db: db}, nil
}

func (s *SQLite) Close() error {
	return s.db.Close()
}

func (s *SQLite) UpsertThread(meta ThreadMeta) error {
	if meta.ThreadID == "" {
		return fmt.Errorf("store: upsert thread requires a thread id")
	}
	var modelSelection any
	if meta.ModelSelection != nil {
		encoded, err := json.Marshal(meta.ModelSelection)
		if err != nil {
			return fmt.Errorf("store: encode thread %q model selection: %w", meta.ThreadID, err)
		}
		modelSelection = string(encoded)
	}
	_, err := s.db.Exec(`INSERT INTO threads (thread_id, title, cwd, provider_instance_id, model_selection, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT (thread_id) DO UPDATE SET
			title = excluded.title,
			cwd = excluded.cwd,
			provider_instance_id = excluded.provider_instance_id,
			model_selection = excluded.model_selection,
			created_at = excluded.created_at,
			updated_at = excluded.updated_at`,
		meta.ThreadID, meta.Title, meta.Cwd, string(meta.ProviderInstanceID), modelSelection,
		timestamp(meta.CreatedAt), timestamp(meta.UpdatedAt))
	if err != nil {
		return fmt.Errorf("store: upsert thread %q: %w", meta.ThreadID, err)
	}
	return nil
}

func (s *SQLite) ListThreads() ([]ThreadMeta, error) {
	rows, err := s.db.Query(`SELECT thread_id, title, cwd, provider_instance_id, model_selection, created_at, updated_at
		FROM threads ORDER BY updated_at DESC, thread_id`)
	if err != nil {
		return nil, fmt.Errorf("store: list threads: %w", err)
	}
	defer rows.Close()
	var threads []ThreadMeta
	for rows.Next() {
		var meta ThreadMeta
		var instanceID string
		var modelSelection sql.NullString
		var createdAt, updatedAt string
		if err := rows.Scan(&meta.ThreadID, &meta.Title, &meta.Cwd, &instanceID, &modelSelection, &createdAt, &updatedAt); err != nil {
			return nil, fmt.Errorf("store: scan thread: %w", err)
		}
		meta.ProviderInstanceID = provider.InstanceID(instanceID)
		if modelSelection.Valid && modelSelection.String != "" {
			selection := &provider.ModelSelection{}
			if err := json.Unmarshal([]byte(modelSelection.String), selection); err != nil {
				return nil, fmt.Errorf("store: decode thread %q model selection: %w", meta.ThreadID, err)
			}
			meta.ModelSelection = selection
		}
		meta.CreatedAt = parseTimestamp(createdAt)
		meta.UpdatedAt = parseTimestamp(updatedAt)
		threads = append(threads, meta)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: list threads: %w", err)
	}
	return threads, nil
}

// ImportThread writes the sidebar row and provider route in one transaction.
// The transaction is immediate (configured in Open), and the database uses one
// connection, so concurrent imports cannot create two maiD threads for the
// same provider session.
func (s *SQLite) ImportThread(meta ThreadMeta, route RouteRecord) (string, bool, error) {
	if meta.ThreadID == "" {
		return "", false, fmt.Errorf("store: import thread requires a thread id")
	}
	if route.InstanceID == "" || route.ProviderSessionID == "" {
		return "", false, fmt.Errorf("store: import thread %q requires an instance id and provider session id", meta.ThreadID)
	}
	if meta.ProviderInstanceID != "" && meta.ProviderInstanceID != route.InstanceID {
		return "", false, fmt.Errorf("store: import thread %q has conflicting provider instance ids", meta.ThreadID)
	}
	meta.ProviderInstanceID = route.InstanceID
	var modelSelection any
	if meta.ModelSelection != nil {
		encoded, err := json.Marshal(meta.ModelSelection)
		if err != nil {
			return "", false, fmt.Errorf("store: encode imported thread %q model selection: %w", meta.ThreadID, err)
		}
		modelSelection = string(encoded)
	}

	tx, err := s.db.Begin()
	if err != nil {
		return "", false, fmt.Errorf("store: begin import thread %q: %w", meta.ThreadID, err)
	}
	defer func() { _ = tx.Rollback() }()

	var existing string
	err = tx.QueryRow(`SELECT thread_id FROM provider_session_imports
		WHERE instance_id = ? AND provider_session_id = ?`,
		string(route.InstanceID), route.ProviderSessionID).Scan(&existing)
	switch {
	case err == nil:
		var currentInstanceID, currentSessionID string
		currentErr := tx.QueryRow(`SELECT instance_id, provider_session_id FROM thread_routes WHERE thread_id = ?`, existing).
			Scan(&currentInstanceID, &currentSessionID)
		if currentErr == nil && (currentInstanceID != string(route.InstanceID) || currentSessionID != route.ProviderSessionID) {
			return "", false, fmt.Errorf("store: imported thread %q is currently bound to provider session %q on instance %q", existing, currentSessionID, currentInstanceID)
		}
		if currentErr != nil && !errors.Is(currentErr, sql.ErrNoRows) {
			return "", false, fmt.Errorf("store: inspect imported thread %q route: %w", existing, currentErr)
		}
		route.StartInput.ThreadID = existing
		startInput, err := json.Marshal(route.StartInput)
		if err != nil {
			return "", false, fmt.Errorf("store: encode imported thread %q start input: %w", existing, err)
		}
		if currentErr != nil {
			if _, err := tx.Exec(`INSERT INTO thread_routes
				(thread_id, instance_id, provider_session_id, resume_cursor, start_input)
				VALUES (?, ?, ?, ?, ?)`, existing, string(route.InstanceID), route.ProviderSessionID,
				nullableText(string(route.ResumeCursor)), string(startInput)); err != nil {
				return "", false, fmt.Errorf("store: restore imported route for thread %q: %w", existing, err)
			}
		}
		if err := tx.Commit(); err != nil {
			return "", false, fmt.Errorf("store: commit restored imported route for thread %q: %w", existing, err)
		}
		return existing, false, nil
	case !errors.Is(err, sql.ErrNoRows):
		return "", false, fmt.Errorf("store: find imported provider session: %w", err)
	}

	// Sessions created through maiD are also returned by provider session lists.
	// Adopt their existing route into the durable import index instead of
	// creating a second sidebar thread for the same provider session.
	err = tx.QueryRow(`SELECT thread_id FROM thread_routes
		WHERE instance_id = ? AND provider_session_id = ? LIMIT 1`,
		string(route.InstanceID), route.ProviderSessionID).Scan(&existing)
	switch {
	case err == nil:
		if _, err := tx.Exec(`INSERT INTO threads
			(thread_id, title, cwd, provider_instance_id, model_selection, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (thread_id) DO NOTHING`,
			existing, meta.Title, meta.Cwd, string(meta.ProviderInstanceID), modelSelection,
			timestamp(meta.CreatedAt), timestamp(meta.UpdatedAt)); err != nil {
			return "", false, fmt.Errorf("store: ensure imported thread %q metadata: %w", existing, err)
		}
		if _, err := tx.Exec(`INSERT INTO provider_session_imports
			(instance_id, provider_session_id, thread_id) VALUES (?, ?, ?)`,
			string(route.InstanceID), route.ProviderSessionID, existing); err != nil {
			return "", false, fmt.Errorf("store: record existing provider session for thread %q: %w", existing, err)
		}
		if err := tx.Commit(); err != nil {
			return "", false, fmt.Errorf("store: commit existing provider session for thread %q: %w", existing, err)
		}
		return existing, false, nil
	case !errors.Is(err, sql.ErrNoRows):
		return "", false, fmt.Errorf("store: find existing provider session route: %w", err)
	}

	if _, err := tx.Exec(`INSERT INTO threads
		(thread_id, title, cwd, provider_instance_id, model_selection, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`, meta.ThreadID, meta.Title, meta.Cwd,
		string(meta.ProviderInstanceID), modelSelection, timestamp(meta.CreatedAt), timestamp(meta.UpdatedAt)); err != nil {
		return "", false, fmt.Errorf("store: insert imported thread %q: %w", meta.ThreadID, err)
	}
	if _, err := tx.Exec(`INSERT INTO provider_session_imports
		(instance_id, provider_session_id, thread_id) VALUES (?, ?, ?)`,
		string(route.InstanceID), route.ProviderSessionID, meta.ThreadID); err != nil {
		return "", false, fmt.Errorf("store: record imported provider session for thread %q: %w", meta.ThreadID, err)
	}
	route.StartInput.ThreadID = meta.ThreadID
	startInput, err := json.Marshal(route.StartInput)
	if err != nil {
		return "", false, fmt.Errorf("store: encode imported thread %q start input: %w", meta.ThreadID, err)
	}
	if _, err := tx.Exec(`INSERT INTO thread_routes
		(thread_id, instance_id, provider_session_id, resume_cursor, start_input)
		VALUES (?, ?, ?, ?, ?)`, meta.ThreadID, string(route.InstanceID), route.ProviderSessionID,
		nullableText(string(route.ResumeCursor)), string(startInput)); err != nil {
		return "", false, fmt.Errorf("store: insert imported route for thread %q: %w", meta.ThreadID, err)
	}
	if err := tx.Commit(); err != nil {
		return "", false, fmt.Errorf("store: commit imported thread %q: %w", meta.ThreadID, err)
	}
	return meta.ThreadID, true, nil
}

func (s *SQLite) SaveRoute(threadID string, record RouteRecord) error {
	if threadID == "" {
		return fmt.Errorf("store: save route requires a thread id")
	}
	if record.InstanceID == "" {
		return fmt.Errorf("store: save route for thread %q requires an instance id", threadID)
	}
	startInput, err := json.Marshal(record.StartInput)
	if err != nil {
		return fmt.Errorf("store: encode thread %q start input: %w", threadID, err)
	}
	_, err = s.db.Exec(`INSERT INTO thread_routes (thread_id, instance_id, provider_session_id, resume_cursor, start_input)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT (thread_id) DO UPDATE SET
			instance_id = excluded.instance_id,
			provider_session_id = excluded.provider_session_id,
			resume_cursor = excluded.resume_cursor,
			start_input = excluded.start_input`,
		threadID, string(record.InstanceID), record.ProviderSessionID,
		nullableText(string(record.ResumeCursor)), string(startInput))
	if err != nil {
		if record.ProviderSessionID != "" {
			var existing string
			lookupErr := s.db.QueryRow(`SELECT thread_id FROM thread_routes
				WHERE instance_id = ? AND provider_session_id = ?`,
				string(record.InstanceID), record.ProviderSessionID).Scan(&existing)
			if lookupErr == nil && existing != threadID {
				return fmt.Errorf("store: save route for thread %q: %w by thread %q", threadID, ErrProviderSessionBound, existing)
			}
		}
		return fmt.Errorf("store: save route for thread %q: %w", threadID, err)
	}
	return nil
}

func (s *SQLite) DeleteRoute(threadID string) error {
	if _, err := s.db.Exec(`DELETE FROM thread_routes WHERE thread_id = ?`, threadID); err != nil {
		return fmt.Errorf("store: delete route for thread %q: %w", threadID, err)
	}
	return nil
}

func (s *SQLite) LoadRoutes() (map[string]RouteRecord, error) {
	rows, err := s.db.Query(`SELECT thread_id, instance_id, provider_session_id, resume_cursor, start_input FROM thread_routes`)
	if err != nil {
		return nil, fmt.Errorf("store: load routes: %w", err)
	}
	defer rows.Close()
	routes := make(map[string]RouteRecord)
	for rows.Next() {
		var threadID, instanceID, sessionID string
		var resumeCursor, startInput sql.NullString
		if err := rows.Scan(&threadID, &instanceID, &sessionID, &resumeCursor, &startInput); err != nil {
			return nil, fmt.Errorf("store: scan route: %w", err)
		}
		record := RouteRecord{InstanceID: provider.InstanceID(instanceID), ProviderSessionID: sessionID}
		if resumeCursor.Valid && resumeCursor.String != "" {
			record.ResumeCursor = json.RawMessage(resumeCursor.String)
		}
		if startInput.Valid && startInput.String != "" {
			if err := json.Unmarshal([]byte(startInput.String), &record.StartInput); err != nil {
				return nil, fmt.Errorf("store: decode thread %q start input: %w", threadID, err)
			}
		}
		routes[threadID] = record
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: load routes: %w", err)
	}
	return routes, nil
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
