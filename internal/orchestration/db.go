package orchestration

import (
	"bytes"
	"compress/gzip"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"time"

	"github.com/Aqothy/maiD/internal/provider"
)

// The ledger is plain tables, mutated only by the engine, one transaction per
// step. The session cache keeps what providers said, rebuildable from native
// data; the native mirror keeps native frames for adapters (provider.Mirror).
const schema = `
CREATE TABLE IF NOT EXISTS threads (
	thread_id TEXT PRIMARY KEY,
	title TEXT NOT NULL,
	workspace TEXT NOT NULL,
	origin_kind TEXT NOT NULL,
	parent_id TEXT REFERENCES threads(thread_id) ON DELETE CASCADE,
	origin_by TEXT NOT NULL DEFAULT '',
	origin_at TEXT NOT NULL DEFAULT '',
	contract TEXT,
	accepts_input INTEGER NOT NULL DEFAULT 0,
	forked_from_thread TEXT REFERENCES threads(thread_id) ON DELETE SET NULL,
	forked_from_turn TEXT NOT NULL DEFAULT '',
	address TEXT NOT NULL DEFAULT '',
	hold TEXT NOT NULL DEFAULT '',
	policy TEXT,
	seen_at TEXT NOT NULL DEFAULT '',
	created_at TEXT NOT NULL,
	updated_at TEXT NOT NULL
) STRICT;
CREATE INDEX IF NOT EXISTS threads_parent ON threads(parent_id);
CREATE TABLE IF NOT EXISTS participants (
	participant_id TEXT PRIMARY KEY,
	thread_id TEXT NOT NULL REFERENCES threads(thread_id) ON DELETE CASCADE,
	instance_id TEXT NOT NULL,
	settings TEXT,
	native_session TEXT NOT NULL DEFAULT '',
	seen_through TEXT NOT NULL DEFAULT ''
) STRICT;
CREATE UNIQUE INDEX IF NOT EXISTS participants_native ON participants(instance_id, native_session) WHERE native_session <> '';
CREATE TABLE IF NOT EXISTS turns (
	turn_id TEXT PRIMARY KEY,
	thread_id TEXT NOT NULL REFERENCES threads(thread_id) ON DELETE CASCADE,
	participant_id TEXT NOT NULL,
	native_session TEXT NOT NULL,
	native_ref TEXT NOT NULL,
	started_by TEXT NOT NULL,
	by_agent INTEGER NOT NULL DEFAULT 0,
	hops INTEGER NOT NULL,
	state TEXT NOT NULL,
	stop_reason TEXT NOT NULL DEFAULT '',
	error TEXT NOT NULL DEFAULT '',
	report TEXT,
	started_at TEXT NOT NULL,
	settled_at TEXT NOT NULL DEFAULT ''
) STRICT;
CREATE INDEX IF NOT EXISTS turns_order ON turns(thread_id, started_at, turn_id);
CREATE UNIQUE INDEX IF NOT EXISTS turns_native ON turns(thread_id, native_session, native_ref);
CREATE TABLE IF NOT EXISTS deliveries (
	delivery_id TEXT PRIMARY KEY,
	thread_id TEXT NOT NULL REFERENCES threads(thread_id) ON DELETE CASCADE,
	to_participant TEXT NOT NULL,
	from_actor TEXT NOT NULL,
	kind TEXT NOT NULL,
	mode TEXT NOT NULL,
	body TEXT,
	state TEXT NOT NULL,
	turn_id TEXT NOT NULL DEFAULT '',
	hops INTEGER NOT NULL,
	reason TEXT NOT NULL DEFAULT '',
	wants_reply INTEGER NOT NULL DEFAULT 0,
	answers TEXT NOT NULL DEFAULT '',
	answer TEXT,
	position REAL NOT NULL,
	sent_at TEXT NOT NULL DEFAULT '',
	created_at TEXT NOT NULL
) STRICT;
CREATE UNIQUE INDEX IF NOT EXISTS deliveries_answers ON deliveries(answers) WHERE answers <> '';
CREATE INDEX IF NOT EXISTS deliveries_thread ON deliveries(thread_id, state);
CREATE TABLE IF NOT EXISTS projects (
	path TEXT PRIMARY KEY,
	added_at TEXT NOT NULL
) STRICT;
CREATE TABLE IF NOT EXISTS receipts (
	actor TEXT NOT NULL,
	key TEXT NOT NULL,
	result TEXT NOT NULL,
	created_at TEXT NOT NULL,
	PRIMARY KEY (actor, key)
) STRICT;
CREATE TABLE IF NOT EXISTS session_entries (
	instance_id TEXT NOT NULL,
	native_session TEXT NOT NULL,
	seq INTEGER NOT NULL,
	ref TEXT NOT NULL,
	turn_ref TEXT NOT NULL,
	entry TEXT NOT NULL,
	authored TEXT NOT NULL,
	PRIMARY KEY (instance_id, native_session, seq)
) STRICT;
CREATE UNIQUE INDEX IF NOT EXISTS session_entries_ref ON session_entries(instance_id, native_session, ref);
CREATE INDEX IF NOT EXISTS session_entries_turn ON session_entries(instance_id, native_session, turn_ref, seq);
CREATE TABLE IF NOT EXISTS session_markers (
	instance_id TEXT NOT NULL,
	native_session TEXT NOT NULL,
	marker TEXT NOT NULL,
	version INTEGER NOT NULL,
	touched_at TEXT NOT NULL,
	PRIMARY KEY (instance_id, native_session)
) STRICT;
CREATE TABLE IF NOT EXISTS native_mirror (
	instance_id TEXT NOT NULL,
	native_session TEXT NOT NULL,
	seq INTEGER NOT NULL,
	frames BLOB NOT NULL,
	PRIMARY KEY (instance_id, native_session, seq)
) STRICT;
`

// timeLayout sorts as text, so turns order by start time in SQL.
const timeLayout = "2006-01-02T15:04:05.000000000Z"

func encodeTime(at time.Time) string {
	if at.IsZero() {
		return ""
	}
	return at.UTC().Format(timeLayout)
}

func decodeTime(text string) time.Time {
	if text == "" {
		return time.Time{}
	}
	at, _ := time.Parse(timeLayout, text)
	return at
}

type authorship string

const (
	authoredByProvider authorship = "provider"
	authoredByMaid     authorship = "maid"
)

// db is the engine's storage. Only the engine writes it; reads may run on
// any goroutine.
type db struct {
	sql *sql.DB
}

func openDB(handle *sql.DB) (*db, error) {
	if _, err := handle.Exec(schema); err != nil {
		return nil, fmt.Errorf("orchestration: ensure schema: %w", err)
	}
	return &db{sql: handle}, nil
}

// state is what the engine holds in memory from the ledger at startup.
type state struct {
	threads      []Thread
	participants []Participant
	// turns are each thread's latest turn and every running one.
	turns []Turn
	// deliveries are the open ones (queued, sending, refused) and messages
	// still owed a reply.
	deliveries []Delivery
	projects   []Project
}

func (d *db) load(ctx context.Context) (state, error) {
	var loaded state
	rows, err := d.sql.QueryContext(ctx, `SELECT thread_id, title, workspace, origin_kind, COALESCE(parent_id, ''), origin_by, origin_at, contract, accepts_input,
		COALESCE(forked_from_thread, ''), forked_from_turn, address, hold, policy, seen_at, created_at, updated_at FROM threads`)
	if err != nil {
		return state{}, fmt.Errorf("load threads: %w", err)
	}
	for rows.Next() {
		thread, err := scanThread(rows)
		if err != nil {
			rows.Close()
			return state{}, err
		}
		loaded.threads = append(loaded.threads, thread)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return state{}, err
	}
	if loaded.participants, err = d.participants(ctx, "", nil); err != nil {
		return state{}, err
	}
	if loaded.turns, err = d.queryTurns(ctx, `SELECT `+turnColumns+` FROM turns WHERE state = 'running' OR turn_id IN (
		SELECT turn_id FROM (SELECT turn_id, ROW_NUMBER() OVER (PARTITION BY thread_id ORDER BY started_at DESC, turn_id DESC) AS latest FROM turns) WHERE latest = 1)`); err != nil {
		return state{}, err
	}
	if loaded.deliveries, err = d.queryDeliveries(ctx, `SELECT `+deliveryColumns+` FROM deliveries d WHERE state IN ('queued', 'sending', 'refused')
		OR (kind = 'message' AND wants_reply = 1 AND state = 'delivered' AND NOT EXISTS (SELECT 1 FROM deliveries r WHERE r.answers = d.delivery_id))`); err != nil {
		return state{}, err
	}
	if loaded.projects, err = d.loadProjects(ctx); err != nil {
		return state{}, err
	}
	return loaded, nil
}

func (d *db) loadProjects(ctx context.Context) ([]Project, error) {
	rows, err := d.sql.QueryContext(ctx, `SELECT path, added_at FROM projects`)
	if err != nil {
		return nil, fmt.Errorf("load projects: %w", err)
	}
	defer rows.Close()
	var projects []Project
	for rows.Next() {
		var path, added string
		if err := rows.Scan(&path, &added); err != nil {
			return nil, fmt.Errorf("scan project: %w", err)
		}
		projects = append(projects, Project{Path: path, AddedAt: decodeTime(added)})
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("load projects: %w", err)
	}
	return projects, nil
}

type scanner interface{ Scan(...any) error }

func scanThread(row scanner) (Thread, error) {
	var thread Thread
	var workspace, contract, policy sql.NullString
	var acceptsInput int
	var forkedThread, forkedTurn, seenAt, createdAt, updatedAt string
	var kind, hold string
	if err := row.Scan(&thread.ID, &thread.Title, &workspace, &kind, &thread.Origin.Parent, &thread.Origin.By, &thread.Origin.At, &contract, &acceptsInput,
		&forkedThread, &forkedTurn, &thread.Address, &hold, &policy, &seenAt, &createdAt, &updatedAt); err != nil {
		return Thread{}, fmt.Errorf("scan thread: %w", err)
	}
	thread.Origin.Kind, thread.Hold = OriginKind(kind), Hold(hold)
	thread.Origin.AcceptsInput = acceptsInput != 0
	if forkedThread != "" {
		thread.Origin.ForkedFrom = &ForkPoint{Thread: ThreadID(forkedThread), Turn: TurnID(forkedTurn)}
	}
	if err := decodeJSON(workspace, &thread.Workspace); err != nil {
		return Thread{}, err
	}
	if contract.Valid {
		thread.Origin.Contract = &Contract{}
		if err := decodeJSON(contract, thread.Origin.Contract); err != nil {
			return Thread{}, err
		}
	}
	if policy.Valid {
		thread.Policy = &TreePolicy{}
		if err := decodeJSON(policy, thread.Policy); err != nil {
			return Thread{}, err
		}
	}
	thread.SeenAt, thread.CreatedAt, thread.UpdatedAt = decodeTime(seenAt), decodeTime(createdAt), decodeTime(updatedAt)
	return thread, nil
}

func decodeJSON(text sql.NullString, into any) error {
	if !text.Valid || text.String == "" {
		return nil
	}
	if err := json.Unmarshal([]byte(text.String), into); err != nil {
		return fmt.Errorf("decode stored JSON: %w", err)
	}
	return nil
}

// encodeJSON is a nullable JSON column: NULL for a nil value.
func encodeJSON(value any) any {
	if value == nil {
		return nil
	}
	raw, err := json.Marshal(value)
	if err != nil || string(raw) == "null" {
		return nil
	}
	return string(raw)
}

func (d *db) participants(ctx context.Context, where string, args []any) ([]Participant, error) {
	rows, err := d.sql.QueryContext(ctx, `SELECT participant_id, thread_id, instance_id, settings, native_session, seen_through FROM participants`+where, args...)
	if err != nil {
		return nil, fmt.Errorf("load participants: %w", err)
	}
	defer rows.Close()
	var participants []Participant
	for rows.Next() {
		var participant Participant
		var settings sql.NullString
		if err := rows.Scan(&participant.ID, &participant.Thread, &participant.Instance, &settings, &participant.Session, &participant.SeenThrough); err != nil {
			return nil, fmt.Errorf("scan participant: %w", err)
		}
		if err := decodeJSON(settings, &participant.Settings); err != nil {
			return nil, err
		}
		participants = append(participants, participant)
	}
	return participants, rows.Err()
}

const turnColumns = `turn_id, thread_id, participant_id, native_session, native_ref, started_by, by_agent, hops, state, stop_reason, error, report, started_at, settled_at`

func (d *db) queryTurns(ctx context.Context, query string, args ...any) ([]Turn, error) {
	rows, err := d.sql.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("load turns: %w", err)
	}
	defer rows.Close()
	var turns []Turn
	for rows.Next() {
		var turn Turn
		var startedBy, state, stopReason, startedAt, settledAt string
		var report sql.NullString
		var byAgent int
		if err := rows.Scan(&turn.ID, &turn.Thread, &turn.Participant, &turn.Session, &turn.Ref, &startedBy, &byAgent, &turn.Hops, &state, &stopReason, &turn.Error, &report, &startedAt, &settledAt); err != nil {
			return nil, fmt.Errorf("scan turn: %w", err)
		}
		turn.StartedBy, turn.State, turn.StopReason = StartedBy(startedBy), provider.TurnState(state), provider.StopReason(stopReason)
		turn.ByAgent = byAgent != 0
		if report.Valid {
			turn.Report = json.RawMessage(report.String)
		}
		turn.StartedAt, turn.SettledAt = decodeTime(startedAt), decodeTime(settledAt)
		turns = append(turns, turn)
	}
	return turns, rows.Err()
}

// threadTurns are a thread's turns in display order, at most limit (all when
// zero) of the newest ones before the turn before.
func (d *db) threadTurns(ctx context.Context, thread ThreadID, before *Turn, limit int) ([]Turn, error) {
	query := `SELECT ` + turnColumns + ` FROM turns WHERE thread_id = ?`
	args := []any{string(thread)}
	if before != nil {
		query += ` AND (started_at, turn_id) < (?, ?)`
		args = append(args, encodeTime(before.StartedAt), string(before.ID))
	}
	query += ` ORDER BY started_at DESC, turn_id DESC`
	if limit > 0 {
		query += fmt.Sprintf(` LIMIT %d`, limit)
	}
	turns, err := d.queryTurns(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	for left, right := 0, len(turns)-1; left < right; left, right = left+1, right-1 {
		turns[left], turns[right] = turns[right], turns[left]
	}
	return turns, nil
}

// threadTurnsAfter are a thread's turns after one, or all of them when it is
// nil, oldest first.
func (d *db) threadTurnsAfter(ctx context.Context, thread ThreadID, after *Turn) ([]Turn, error) {
	query := `SELECT ` + turnColumns + ` FROM turns WHERE thread_id = ?`
	args := []any{string(thread)}
	if after != nil {
		query += ` AND (started_at, turn_id) > (?, ?)`
		args = append(args, encodeTime(after.StartedAt), string(after.ID))
	}
	return d.queryTurns(ctx, query+` ORDER BY started_at, turn_id`, args...)
}

func (d *db) turn(ctx context.Context, id TurnID) (Turn, bool, error) {
	turns, err := d.queryTurns(ctx, `SELECT `+turnColumns+` FROM turns WHERE turn_id = ?`, string(id))
	if err != nil || len(turns) == 0 {
		return Turn{}, false, err
	}
	return turns[0], true, nil
}

// deliveredTurns are the turns of a thread that deliveries started or ran in.
func (d *db) deliveredTurns(ctx context.Context, thread ThreadID) (map[TurnID]bool, error) {
	rows, err := d.sql.QueryContext(ctx, `SELECT DISTINCT turn_id FROM deliveries WHERE thread_id = ? AND turn_id <> ''`, string(thread))
	if err != nil {
		return nil, fmt.Errorf("load delivered turns: %w", err)
	}
	defer rows.Close()
	turns := make(map[TurnID]bool)
	for rows.Next() {
		var turn string
		if err := rows.Scan(&turn); err != nil {
			return nil, fmt.Errorf("scan delivered turn: %w", err)
		}
		turns[TurnID(turn)] = true
	}
	return turns, rows.Err()
}

func (d *db) turnByRef(ctx context.Context, thread ThreadID, session, ref string) (Turn, bool, error) {
	turns, err := d.queryTurns(ctx, `SELECT `+turnColumns+` FROM turns WHERE thread_id = ? AND native_session = ? AND native_ref = ?`, string(thread), session, ref)
	if err != nil || len(turns) == 0 {
		return Turn{}, false, err
	}
	return turns[0], true, nil
}

const deliveryColumns = `delivery_id, thread_id, to_participant, from_actor, kind, mode, body, state, turn_id, hops, reason, wants_reply, answers, answer, position, sent_at, created_at`

func (d *db) queryDeliveries(ctx context.Context, query string, args ...any) ([]Delivery, error) {
	rows, err := d.sql.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("load deliveries: %w", err)
	}
	defer rows.Close()
	var deliveries []Delivery
	for rows.Next() {
		var delivery Delivery
		var from string
		var body, answer sql.NullString
		var kind, mode, state, sentAt, createdAt string
		var wantsReply int
		if err := rows.Scan(&delivery.ID, &delivery.Thread, &delivery.To, &from, &kind, &mode, &body, &state, &delivery.Turn, &delivery.Hops, &delivery.Reason,
			&wantsReply, &delivery.Answers, &answer, &delivery.Position, &sentAt, &createdAt); err != nil {
			return nil, fmt.Errorf("scan delivery: %w", err)
		}
		delivery.Kind, delivery.Mode, delivery.State = DeliveryKind(kind), DeliveryMode(mode), DeliveryState(state)
		delivery.WantsReply = wantsReply != 0
		if err := json.Unmarshal([]byte(from), &delivery.From); err != nil {
			return nil, fmt.Errorf("decode delivery sender: %w", err)
		}
		if err := decodeJSON(body, &delivery.Body); err != nil {
			return nil, err
		}
		if answer.Valid {
			delivery.Answer = &Answer{}
			if err := decodeJSON(answer, delivery.Answer); err != nil {
				return nil, err
			}
		}
		delivery.Sent, delivery.CreatedAt = decodeTime(sentAt), decodeTime(createdAt)
		deliveries = append(deliveries, delivery)
	}
	return deliveries, rows.Err()
}

func (d *db) delivery(ctx context.Context, id DeliveryID) (Delivery, bool, error) {
	deliveries, err := d.queryDeliveries(ctx, `SELECT `+deliveryColumns+` FROM deliveries WHERE delivery_id = ?`, string(id))
	if err != nil || len(deliveries) == 0 {
		return Delivery{}, false, err
	}
	return deliveries[0], true, nil
}

// replyTo is the reply to a message, if it has one.
func (d *db) replyTo(ctx context.Context, message DeliveryID) (Delivery, bool, error) {
	deliveries, err := d.queryDeliveries(ctx, `SELECT `+deliveryColumns+` FROM deliveries WHERE answers = ?`, string(message))
	if err != nil || len(deliveries) == 0 {
		return Delivery{}, false, err
	}
	return deliveries[0], true, nil
}

func (d *db) receipt(ctx context.Context, actor Actor, key string) (json.RawMessage, bool, error) {
	var result string
	err := d.sql.QueryRowContext(ctx, `SELECT result FROM receipts WHERE actor = ? AND key = ?`, actor.key(), key).Scan(&result)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, fmt.Errorf("load receipt: %w", err)
	}
	return json.RawMessage(result), true, nil
}

// cachedEntry is one row of the session cache.
type cachedEntry struct {
	instance provider.InstanceID
	session  string
	entry    provider.Entry
	authored authorship
}

// turnEntries are the entries of a session's turn, in provider order.
func (d *db) turnEntries(ctx context.Context, instance provider.InstanceID, session, turnRef string) ([]provider.Entry, error) {
	return d.queryEntries(ctx, `SELECT entry FROM session_entries WHERE instance_id = ? AND native_session = ? AND turn_ref = ? ORDER BY seq`, string(instance), session, turnRef)
}

func (d *db) sessionEntry(ctx context.Context, instance provider.InstanceID, session, ref string) (provider.Entry, bool, error) {
	entries, err := d.queryEntries(ctx, `SELECT entry FROM session_entries WHERE instance_id = ? AND native_session = ? AND ref = ?`, string(instance), session, ref)
	if err != nil || len(entries) == 0 {
		return provider.Entry{}, false, err
	}
	return entries[0], true, nil
}

func (d *db) queryEntries(ctx context.Context, query string, args ...any) ([]provider.Entry, error) {
	rows, err := d.sql.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("load session entries: %w", err)
	}
	defer rows.Close()
	var entries []provider.Entry
	for rows.Next() {
		var raw string
		if err := rows.Scan(&raw); err != nil {
			return nil, fmt.Errorf("scan session entry: %w", err)
		}
		var entry provider.Entry
		if err := json.Unmarshal([]byte(raw), &entry); err != nil {
			return nil, fmt.Errorf("decode session entry: %w", err)
		}
		entries = append(entries, entry)
	}
	return entries, rows.Err()
}

type marker struct {
	marker  provider.Marker
	version int
}

// marker is how far the cache has a session; zero when it has none of it.
func (d *db) marker(ctx context.Context, instance provider.InstanceID, session string) (marker, error) {
	var found marker
	err := d.sql.QueryRowContext(ctx, `SELECT marker, version FROM session_markers WHERE instance_id = ? AND native_session = ?`, string(instance), session).Scan(&found.marker, &found.version)
	if errors.Is(err, sql.ErrNoRows) {
		return marker{}, nil
	}
	if err != nil {
		return marker{}, fmt.Errorf("load session marker: %w", err)
	}
	return found, nil
}

// participantInstances maps a thread's participants to their instances.
func (d *db) participantInstances(ctx context.Context, thread ThreadID) (map[ParticipantID]provider.InstanceID, error) {
	participants, err := d.participants(ctx, ` WHERE thread_id = ?`, []any{string(thread)})
	if err != nil {
		return nil, err
	}
	instances := make(map[ParticipantID]provider.InstanceID, len(participants))
	for _, participant := range participants {
		instances[participant.ID] = participant.Instance
	}
	return instances, nil
}

// threadEntry finds an entry of any session a thread's turns ran in.
func (d *db) threadEntry(ctx context.Context, thread ThreadID, ref string) (provider.Entry, bool, error) {
	entries, err := d.queryEntries(ctx, `SELECT e.entry FROM session_entries e
		JOIN turns t ON t.native_session = e.native_session AND t.native_ref = e.turn_ref
		JOIN participants p ON p.participant_id = t.participant_id AND p.instance_id = e.instance_id
		WHERE t.thread_id = ? AND e.ref = ? LIMIT 1`, string(thread), ref)
	if err != nil || len(entries) == 0 {
		return provider.Entry{}, false, err
	}
	return entries[0], true, nil
}

// tx is one engine step's writes, committed together.
type tx struct {
	threads         map[ThreadID]Thread
	deleted         []ThreadID
	sessions        []sessionKey
	participants    map[ParticipantID]Participant
	turns           map[TurnID]Turn
	droppedTurns    []TurnID
	deliveries      map[DeliveryID]Delivery
	receipts        []receiptRow
	entries         []cachedEntry
	rebuilds        []sessionRebuild
	markers         map[sessionKey]marker
	addedProjects   []Project
	removedProjects []string
}

type sessionKey struct {
	instance provider.InstanceID
	session  string
}

type receiptRow struct {
	actor  Actor
	key    string
	result json.RawMessage
}

// sessionRebuild replaces a session's provider-authored entries with entries, in
// their order; entries maiD authored keep their places after the entries
// that preceded them.
type sessionRebuild struct {
	key     sessionKey
	entries []provider.Entry
}

func newTx() *tx {
	return &tx{
		threads:      make(map[ThreadID]Thread),
		participants: make(map[ParticipantID]Participant),
		turns:        make(map[TurnID]Turn),
		deliveries:   make(map[DeliveryID]Delivery),
		markers:      make(map[sessionKey]marker),
	}
}

func (t *tx) empty() bool {
	return len(t.threads) == 0 && len(t.deleted) == 0 && len(t.participants) == 0 && len(t.turns) == 0 && len(t.droppedTurns) == 0 && len(t.deliveries) == 0 &&
		len(t.receipts) == 0 && len(t.entries) == 0 && len(t.rebuilds) == 0 && len(t.markers) == 0 &&
		len(t.addedProjects) == 0 && len(t.removedProjects) == 0
}

func (d *db) commit(ctx context.Context, t *tx) error {
	if t.empty() {
		return nil
	}
	sqlTx, err := d.sql.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin ledger write: %w", err)
	}
	// After a commit, rolling back is a no-op; before one, a failed write has
	// its own error.
	defer func() { _ = sqlTx.Rollback() }()
	if err := writeTx(ctx, sqlTx, t); err != nil {
		return err
	}
	if err := sqlTx.Commit(); err != nil {
		return fmt.Errorf("commit ledger write: %w", err)
	}
	return nil
}

func writeTx(ctx context.Context, sqlTx *sql.Tx, t *tx) error {
	for _, id := range t.deleted {
		if _, err := sqlTx.ExecContext(ctx, `DELETE FROM threads WHERE thread_id = ?`, string(id)); err != nil {
			return fmt.Errorf("delete thread: %w", err)
		}
	}
	for _, key := range t.sessions {
		for _, table := range []string{"session_entries", "session_markers", "native_mirror"} {
			if _, err := sqlTx.ExecContext(ctx, `DELETE FROM `+table+` WHERE instance_id = ? AND native_session = ?`, string(key.instance), key.session); err != nil {
				return fmt.Errorf("delete session %s: %w", table, err)
			}
		}
	}
	// Parents before children, so the foreign key holds within the write.
	written := make(map[ThreadID]bool, len(t.threads))
	var writeThread func(Thread) error
	writeThread = func(thread Thread) error {
		if written[thread.ID] {
			return nil
		}
		written[thread.ID] = true
		if parent, ok := t.threads[thread.Origin.Parent]; ok {
			if err := writeThread(parent); err != nil {
				return err
			}
		}
		if from := thread.Origin.ForkedFrom; from != nil {
			if source, ok := t.threads[from.Thread]; ok {
				if err := writeThread(source); err != nil {
					return err
				}
			}
		}
		return putThread(ctx, sqlTx, thread)
	}
	for _, thread := range t.threads {
		if err := writeThread(thread); err != nil {
			return err
		}
	}
	for _, participant := range t.participants {
		if _, err := sqlTx.ExecContext(ctx, `INSERT INTO participants (participant_id, thread_id, instance_id, settings, native_session, seen_through)
			VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (participant_id) DO UPDATE SET instance_id = excluded.instance_id, settings = excluded.settings,
			native_session = excluded.native_session, seen_through = excluded.seen_through`,
			string(participant.ID), string(participant.Thread), string(participant.Instance), encodeJSON(nilIfEmpty(participant.Settings)), participant.Session,
			string(participant.SeenThrough)); err != nil {
			return fmt.Errorf("write participant: %w", err)
		}
	}
	for _, turn := range t.turns {
		var report any
		if len(turn.Report) > 0 {
			report = string(turn.Report)
		}
		if _, err := sqlTx.ExecContext(ctx, `INSERT INTO turns (`+turnColumns+`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT (turn_id) DO UPDATE SET participant_id = excluded.participant_id, native_session = excluded.native_session, native_ref = excluded.native_ref,
			hops = excluded.hops, state = excluded.state, stop_reason = excluded.stop_reason, error = excluded.error, report = excluded.report,
			started_at = excluded.started_at, settled_at = excluded.settled_at`,
			string(turn.ID), string(turn.Thread), string(turn.Participant), turn.Session, turn.Ref, string(turn.StartedBy), boolInt(turn.ByAgent), turn.Hops, string(turn.State),
			string(turn.StopReason), turn.Error, report, encodeTime(turn.StartedAt), encodeTime(turn.SettledAt)); err != nil {
			return fmt.Errorf("write turn: %w", err)
		}
	}
	for _, delivery := range t.deliveries {
		from, _ := json.Marshal(delivery.From)
		if _, err := sqlTx.ExecContext(ctx, `INSERT INTO deliveries (`+deliveryColumns+`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT (delivery_id) DO UPDATE SET to_participant = excluded.to_participant, mode = excluded.mode, body = excluded.body, state = excluded.state,
			turn_id = excluded.turn_id, hops = excluded.hops, reason = excluded.reason, answer = excluded.answer, position = excluded.position, sent_at = excluded.sent_at`,
			string(delivery.ID), string(delivery.Thread), string(delivery.To), string(from), string(delivery.Kind), string(delivery.Mode), encodeJSON(bodyOrNil(delivery.Body)),
			string(delivery.State), string(delivery.Turn), delivery.Hops, delivery.Reason, boolInt(delivery.WantsReply), string(delivery.Answers), encodeJSON(delivery.Answer),
			delivery.Position, encodeTime(delivery.Sent), encodeTime(delivery.CreatedAt)); err != nil {
			return fmt.Errorf("write delivery: %w", err)
		}
	}
	for _, receipt := range t.receipts {
		if _, err := sqlTx.ExecContext(ctx, `INSERT INTO receipts (actor, key, result, created_at) VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING`,
			receipt.actor.key(), receipt.key, string(receipt.result), encodeTime(time.Now())); err != nil {
			return fmt.Errorf("write receipt: %w", err)
		}
	}
	for _, turn := range t.droppedTurns {
		if _, err := sqlTx.ExecContext(ctx, `DELETE FROM turns WHERE turn_id = ?`, string(turn)); err != nil {
			return fmt.Errorf("drop turn: %w", err)
		}
	}
	for _, rebuild := range t.rebuilds {
		if err := rebuildSession(ctx, sqlTx, rebuild); err != nil {
			return err
		}
	}
	for _, entry := range t.entries {
		if err := putEntry(ctx, sqlTx, entry); err != nil {
			return err
		}
	}
	for key, marker := range t.markers {
		if _, err := sqlTx.ExecContext(ctx, `INSERT INTO session_markers (instance_id, native_session, marker, version, touched_at) VALUES (?, ?, ?, ?, ?)
			ON CONFLICT (instance_id, native_session) DO UPDATE SET marker = excluded.marker, version = excluded.version, touched_at = excluded.touched_at`,
			string(key.instance), key.session, string(marker.marker), marker.version, encodeTime(time.Now())); err != nil {
			return fmt.Errorf("write session marker: %w", err)
		}
	}
	for _, path := range t.removedProjects {
		if _, err := sqlTx.ExecContext(ctx, `DELETE FROM projects WHERE path = ?`, path); err != nil {
			return fmt.Errorf("remove project: %w", err)
		}
	}
	for _, project := range t.addedProjects {
		if _, err := sqlTx.ExecContext(ctx, `INSERT INTO projects (path, added_at) VALUES (?, ?)`,
			project.Path, encodeTime(project.AddedAt)); err != nil {
			return fmt.Errorf("add project: %w", err)
		}
	}
	return nil
}

func putThread(ctx context.Context, sqlTx *sql.Tx, thread Thread) error {
	var parent, forkedThread any
	if thread.Origin.Parent != "" {
		parent = string(thread.Origin.Parent)
	}
	forkedTurn := ""
	if from := thread.Origin.ForkedFrom; from != nil {
		forkedThread, forkedTurn = string(from.Thread), string(from.Turn)
	}
	var contract, policy any
	if thread.Origin.Contract != nil {
		contract = encodeJSON(thread.Origin.Contract)
	}
	if thread.Policy != nil {
		policy = encodeJSON(thread.Policy)
	}
	_, err := sqlTx.ExecContext(ctx, `INSERT INTO threads (thread_id, title, workspace, origin_kind, parent_id, origin_by, origin_at, contract, accepts_input,
		forked_from_thread, forked_from_turn, address, hold, policy, seen_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT (thread_id) DO UPDATE SET title = excluded.title, workspace = excluded.workspace, accepts_input = excluded.accepts_input,
		forked_from_thread = excluded.forked_from_thread, forked_from_turn = excluded.forked_from_turn, address = excluded.address, hold = excluded.hold,
		policy = excluded.policy, seen_at = excluded.seen_at, updated_at = excluded.updated_at`,
		string(thread.ID), thread.Title, encodeJSON(thread.Workspace), string(thread.Origin.Kind), parent, string(thread.Origin.By), thread.Origin.At, contract,
		boolInt(thread.Origin.AcceptsInput), forkedThread, forkedTurn, string(thread.Address), string(thread.Hold), policy, encodeTime(thread.SeenAt),
		encodeTime(thread.CreatedAt), encodeTime(thread.UpdatedAt))
	if err != nil {
		return fmt.Errorf("write thread: %w", err)
	}
	return nil
}

func putEntry(ctx context.Context, sqlTx *sql.Tx, entry cachedEntry) error {
	raw, err := json.Marshal(entry.entry)
	if err != nil {
		return fmt.Errorf("encode session entry: %w", err)
	}
	_, err = sqlTx.ExecContext(ctx, `INSERT INTO session_entries (instance_id, native_session, seq, ref, turn_ref, entry, authored)
		VALUES (?, ?, (SELECT COALESCE(MAX(seq), 0) + 1 FROM session_entries WHERE instance_id = ? AND native_session = ?), ?, ?, ?, ?)
		ON CONFLICT (instance_id, native_session, ref) DO UPDATE SET turn_ref = excluded.turn_ref, entry = excluded.entry`,
		string(entry.instance), entry.session, string(entry.instance), entry.session, entry.entry.Ref, entry.entry.Turn, string(raw), string(entry.authored))
	if err != nil {
		return fmt.Errorf("write session entry: %w", err)
	}
	return nil
}

func rebuildSession(ctx context.Context, sqlTx *sql.Tx, r sessionRebuild) error {
	rows, err := sqlTx.QueryContext(ctx, `SELECT ref, turn_ref, entry, authored FROM session_entries WHERE instance_id = ? AND native_session = ? ORDER BY seq`, string(r.key.instance), r.key.session)
	if err != nil {
		return fmt.Errorf("read session for rebuild: %w", err)
	}
	type old struct {
		ref, turn, raw string
		authored       authorship
	}
	var existing []old
	for rows.Next() {
		var row old
		var authored string
		if err := rows.Scan(&row.ref, &row.turn, &row.raw, &authored); err != nil {
			rows.Close()
			return fmt.Errorf("scan session for rebuild: %w", err)
		}
		row.authored = authorship(authored)
		existing = append(existing, row)
	}
	rows.Close()
	// Each maiD-authored entry follows the provider entry that preceded it.
	after := make(map[string][]old)
	var leading []old
	anchor := ""
	for _, row := range existing {
		if row.authored == authoredByProvider {
			anchor = row.ref
			continue
		}
		if anchor == "" {
			leading = append(leading, row)
		} else {
			after[anchor] = append(after[anchor], row)
		}
	}
	if _, err := sqlTx.ExecContext(ctx, `DELETE FROM session_entries WHERE instance_id = ? AND native_session = ?`, string(r.key.instance), r.key.session); err != nil {
		return fmt.Errorf("clear session for rebuild: %w", err)
	}
	seq := 0
	insert := func(ref, turn, raw string, authored authorship) error {
		seq++
		_, err := sqlTx.ExecContext(ctx, `INSERT INTO session_entries (instance_id, native_session, seq, ref, turn_ref, entry, authored) VALUES (?, ?, ?, ?, ?, ?, ?)`,
			string(r.key.instance), r.key.session, seq, ref, turn, raw, string(authored))
		if err != nil {
			return fmt.Errorf("write rebuilt session entry: %w", err)
		}
		return nil
	}
	turns := make(map[string]bool)
	for _, entry := range r.entries {
		turns[entry.Turn] = true
	}
	placed := func(rows []old) error {
		for _, row := range rows {
			// An entry whose turn no longer exists goes with it.
			if turns[row.turn] {
				if err := insert(row.ref, row.turn, row.raw, row.authored); err != nil {
					return err
				}
			}
		}
		return nil
	}
	if err := placed(leading); err != nil {
		return err
	}
	for _, entry := range r.entries {
		raw, err := json.Marshal(entry)
		if err != nil {
			return fmt.Errorf("encode session entry: %w", err)
		}
		if err := insert(entry.Ref, entry.Turn, string(raw), authoredByProvider); err != nil {
			return err
		}
		if err := placed(after[entry.Ref]); err != nil {
			return err
		}
		delete(after, entry.Ref)
	}
	// MaiD entries whose anchor is gone end their turn.
	for _, rows := range after {
		if err := placed(rows); err != nil {
			return err
		}
	}
	return nil
}

func nilIfEmpty[T any](values []T) any {
	if len(values) == 0 {
		return nil
	}
	return values
}

func bodyOrNil(body MessageBody) any {
	if body.Text == "" && len(body.Attachments) == 0 && len(body.Annotations) == 0 {
		return nil
	}
	return body
}

func boolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}

// mirrorWriter writes every instance's native mirror, off the engine.
type mirrorWriter struct {
	db     *db
	logger *slog.Logger
	writes chan mirrorWrite
	// stopped is closed once run has written everything queued before its
	// context ended.
	stopped chan struct{}
}

type mirrorWrite struct {
	instance provider.InstanceID
	session  string
	frames   []json.RawMessage
	// done, when set, marks a flush: closed once the writes before it are
	// written.
	done chan struct{}
}

func newMirrorWriter(database *db, logger *slog.Logger) *mirrorWriter {
	return &mirrorWriter{db: database, logger: logger, writes: make(chan mirrorWrite, 4096), stopped: make(chan struct{})}
}

func (w *mirrorWriter) flush(ctx context.Context) error {
	done := make(chan struct{})
	select {
	case w.writes <- mirrorWrite{done: done}:
	case <-ctx.Done():
		return ctx.Err()
	}
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// run writes queued frames in batches, one compressed row per session per
// batch. When ctx ends it writes what is still queued first: for an agent
// that can't replay its sessions, the mirror is their only record.
func (w *mirrorWriter) run(ctx context.Context) {
	defer close(w.stopped)
	for {
		var batch []mirrorWrite
		select {
		case <-ctx.Done():
			for batch := w.drain(nil); len(batch) > 0; batch = w.drain(nil) {
				w.write(batch)
			}
			return
		case write := <-w.writes:
			batch = append(batch, write)
		}
		w.write(w.drain(batch))
	}
}

// drain adds what is queued to batch, up to a batch's size.
func (w *mirrorWriter) drain(batch []mirrorWrite) []mirrorWrite {
	for len(batch) < 512 {
		select {
		case write := <-w.writes:
			batch = append(batch, write)
		default:
			return batch
		}
	}
	return batch
}

func (w *mirrorWriter) write(batch []mirrorWrite) {
	bySession := make(map[sessionKey][]json.RawMessage)
	var order []sessionKey
	var waiters []chan struct{}
	for _, write := range batch {
		if write.done != nil {
			waiters = append(waiters, write.done)
			continue
		}
		key := sessionKey{write.instance, write.session}
		if _, ok := bySession[key]; !ok {
			order = append(order, key)
		}
		bySession[key] = append(bySession[key], write.frames...)
	}
	for _, key := range order {
		blob, err := encodeFrames(bySession[key])
		if err == nil {
			_, err = w.db.sql.Exec(`INSERT INTO native_mirror (instance_id, native_session, seq, frames)
				VALUES (?, ?, (SELECT COALESCE(MAX(seq), 0) + 1 FROM native_mirror WHERE instance_id = ? AND native_session = ?), ?)`,
				string(key.instance), key.session, string(key.instance), key.session, blob)
		}
		if err != nil {
			// The session goes on without these frames: its rebuilds lack
			// them.
			w.logger.Error("write native mirror", "instance", key.instance, "session", key.session, "error", err)
		}
	}
	for _, done := range waiters {
		close(done)
	}
}

// instanceMirror is one instance's provider.Mirror.
type instanceMirror struct {
	writer   *mirrorWriter
	instance provider.InstanceID
}

func (m *instanceMirror) Append(session string, frames []json.RawMessage) {
	m.writer.writes <- mirrorWrite{instance: m.instance, session: session, frames: frames}
}

func (m *instanceMirror) Load(ctx context.Context, session string) ([]json.RawMessage, error) {
	if err := m.writer.flush(ctx); err != nil {
		return nil, err
	}
	rows, err := m.writer.db.sql.QueryContext(ctx, `SELECT frames FROM native_mirror WHERE instance_id = ? AND native_session = ? ORDER BY seq`, string(m.instance), session)
	if err != nil {
		return nil, fmt.Errorf("load native mirror: %w", err)
	}
	defer rows.Close()
	var frames []json.RawMessage
	for rows.Next() {
		var blob []byte
		if err := rows.Scan(&blob); err != nil {
			return nil, fmt.Errorf("scan native mirror: %w", err)
		}
		batch, err := decodeFrames(blob)
		if err != nil {
			return nil, err
		}
		frames = append(frames, batch...)
	}
	return frames, rows.Err()
}

func (m *instanceMirror) Fork(ctx context.Context, session, into string) error {
	if err := m.writer.flush(ctx); err != nil {
		return err
	}
	_, err := m.writer.db.sql.ExecContext(ctx, `INSERT INTO native_mirror (instance_id, native_session, seq, frames)
		SELECT instance_id, ?, seq, frames FROM native_mirror WHERE instance_id = ? AND native_session = ?`, into, string(m.instance), session)
	if err != nil {
		return fmt.Errorf("fork native mirror: %w", err)
	}
	return nil
}

func (m *instanceMirror) Delete(ctx context.Context, session string) error {
	if err := m.writer.flush(ctx); err != nil {
		return err
	}
	if _, err := m.writer.db.sql.ExecContext(ctx, `DELETE FROM native_mirror WHERE instance_id = ? AND native_session = ?`, string(m.instance), session); err != nil {
		return fmt.Errorf("delete native mirror: %w", err)
	}
	return nil
}

func encodeFrames(frames []json.RawMessage) ([]byte, error) {
	raw, err := json.Marshal(frames)
	if err != nil {
		return nil, err
	}
	var buffer bytes.Buffer
	writer := gzip.NewWriter(&buffer)
	if _, err := writer.Write(raw); err != nil {
		return nil, err
	}
	if err := writer.Close(); err != nil {
		return nil, err
	}
	return buffer.Bytes(), nil
}

func decodeFrames(blob []byte) ([]json.RawMessage, error) {
	reader, err := gzip.NewReader(bytes.NewReader(blob))
	if err != nil {
		return nil, fmt.Errorf("decode native mirror: %w", err)
	}
	raw, err := io.ReadAll(reader)
	if err != nil {
		return nil, fmt.Errorf("decode native mirror: %w", err)
	}
	var frames []json.RawMessage
	if err := json.Unmarshal(raw, &frames); err != nil {
		return nil, fmt.Errorf("decode native mirror: %w", err)
	}
	return frames, nil
}
