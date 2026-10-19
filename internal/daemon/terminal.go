package daemon

import (
	"cmp"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/Aqothy/jsonrpc2"
	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/provider"
	"github.com/Aqothy/maiD/internal/store"
	"github.com/Aqothy/maiD/internal/terminal"
	"github.com/Aqothy/maiD/internal/terminal/vtscreen"
)

// terminalRuntime composes the PTY service with RPC concerns: terminal
// identity, notification fanout, and SQLite metadata.
// Only identity metadata is durable; a daemon restart reports every persisted
// terminal as stopped.
type terminalRuntime struct {
	service *terminal.Service
	meta    store.TerminalStore // nil when metadata persistence is unavailable

	mu      sync.Mutex
	entries map[string]*terminalEntry
}

type terminalEntry struct {
	// operations fences lifecycle work for this terminal without serializing
	// unrelated terminals. Stream subscriptions live on each RPC client.
	operations sync.Mutex

	terminalID string
	title      string
	cwd        string
	createdAt  time.Time
	updatedAt  time.Time
	// onExit runs once, off the event path, when the current run ends. Only
	// command terminals set it; relaunching (to a shell) clears it.
	onExit func(exitCode *int)
}

func newTerminalRuntime(meta store.TerminalStore, logger *slog.Logger) *terminalRuntime {
	rt := &terminalRuntime{
		service: terminal.NewService(),
		meta:    meta,
		entries: make(map[string]*terminalEntry),
	}
	if meta == nil {
		return rt
	}
	metas, err := meta.ListTerminals()
	if err != nil {
		logger.Warn("restore persisted terminals", "error", err)
		return rt
	}
	// Restored rows have no live session, so they present as stopped until
	// the user explicitly opens (relaunches) one.
	for _, m := range metas {
		rt.entries[m.TerminalID] = &terminalEntry{
			terminalID: m.TerminalID,
			title:      m.Title,
			cwd:        m.Cwd,
			createdAt:  m.CreatedAt,
			updatedAt:  m.UpdatedAt,
		}
	}
	if len(metas) > 0 {
		logger.Info("restored persisted terminals", "count", len(metas))
	}
	return rt
}

// persist writes one entry's durable metadata. Failures are logged, not
// fatal; the in-memory terminal remains usable for this daemon run.
func (rt *terminalRuntime) persist(entry *terminalEntry, logger *slog.Logger) {
	if rt.meta == nil {
		return
	}
	rt.mu.Lock()
	meta := store.TerminalMeta{
		TerminalID: entry.terminalID,
		Title:      entry.title,
		Cwd:        entry.cwd,
		CreatedAt:  entry.createdAt,
		UpdatedAt:  entry.updatedAt,
	}
	rt.mu.Unlock()
	if err := rt.meta.UpsertTerminal(meta); err != nil {
		logger.Warn("persist terminal metadata", "terminal", meta.TerminalID, "error", err)
	}
}

// lockEntry starts an operation on the current identity for terminalID. The
// identity check after locking prevents an operation that raced deletion from
// acting on a detached entry pointer.
func (rt *terminalRuntime) lockEntry(terminalID string) (*terminalEntry, bool) {
	rt.mu.Lock()
	entry, ok := rt.entries[terminalID]
	rt.mu.Unlock()
	if !ok {
		return nil, false
	}

	entry.operations.Lock()
	rt.mu.Lock()
	current, ok := rt.entries[terminalID]
	rt.mu.Unlock()
	if !ok || current != entry {
		entry.operations.Unlock()
		return nil, false
	}
	return entry, true
}

func (s *Server) createTerminal(client *rpcClient, params wire.TerminalCreateParams) (wire.TerminalAttachSnapshot, error) {
	rt := s.terminals
	cwd, err := terminal.ResolveCwd(params.Cwd)
	if err != nil {
		return wire.TerminalAttachSnapshot{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, err)
	}
	appearance, err := parseTerminalAppearance(params.Appearance)
	if err != nil {
		return wire.TerminalAttachSnapshot{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, err)
	}

	terminalID := terminal.NewID()
	now := time.Now().UTC()
	entry := &terminalEntry{
		terminalID: terminalID,
		title:      params.Title,
		cwd:        cwd,
		createdAt:  now,
		updatedAt:  now,
	}
	entry.operations.Lock()
	undoSubscribe := client.subscribeTerminal(terminalID, params.AttachmentID, params.Columns, params.Rows, appearance)
	// Register the entry (and with it the output subscription) before the
	// shell starts so no early output is lost; the client buffers stream items
	// until this call returns its snapshot.
	rt.mu.Lock()
	rt.entries[terminalID] = entry
	rt.mu.Unlock()

	session, err := rt.service.Start(terminalID, terminal.SpawnSpec{
		Cwd:     cwd,
		Columns: params.Columns,
		Rows:    params.Rows,
	}, s.terminalEvents())
	if err != nil {
		if errors.Is(err, terminal.ErrInvalidDimensions) {
			// Nothing useful was created; a dimension bug should not leave a
			// ghost row.
			rt.mu.Lock()
			delete(rt.entries, terminalID)
			rt.mu.Unlock()
			undoSubscribe()
			entry.operations.Unlock()
			return wire.TerminalAttachSnapshot{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, err)
		}
		// Spawn failures keep the stopped metadata row so the user can retry
		// or delete it.
		undoSubscribe()
		rt.persist(entry, s.logger)
		entry.operations.Unlock()
		s.publishTerminalListUpsert(s.terminalMetaSummary(entry))
		return wire.TerminalAttachSnapshot{}, fmt.Errorf("terminal spawn failed: %w", err)
	}

	rt.persist(entry, s.logger)
	if err := s.sizeTerminal(entry, session); err != nil {
		s.logger.Warn("terminal appearance failed", "terminal", terminalID, "error", err)
	}
	snapshot, err := s.terminalAttachSnapshot(entry, session)
	if err != nil {
		undoSubscribe()
		entry.operations.Unlock()
		s.publishTerminalListUpsert(s.terminalListSummary(entry))
		return wire.TerminalAttachSnapshot{}, err
	}
	entry.operations.Unlock()
	s.publishTerminalListUpsert(snapshot.Terminal)
	s.logger.Info("terminal created", "terminal", terminalID, "run", session.RunID, "client", client.id,
		"columns", params.Columns, "rows", params.Rows)
	return snapshot, nil
}

// startCommandTerminal starts a terminal running command instead of a shell,
// in the user's home directory. Clients attach to it by id with their own grid
// size. onExit runs once with the exit code when the program ends.
func (s *Server) startCommandTerminal(title string, command provider.TerminalCommand, onExit func(exitCode *int)) (string, error) {
	if len(command.Argv) == 0 {
		return "", fmt.Errorf("terminal command is empty")
	}
	rt := s.terminals
	cwd, err := terminal.ResolveCwd("")
	if err != nil {
		return "", err
	}
	terminalID := terminal.NewID()
	now := time.Now().UTC()
	entry := &terminalEntry{terminalID: terminalID, title: title, cwd: cwd, createdAt: now, updatedAt: now, onExit: onExit}
	entry.operations.Lock()
	rt.mu.Lock()
	rt.entries[terminalID] = entry
	rt.mu.Unlock()
	if _, err := rt.service.Start(terminalID, terminal.SpawnSpec{Cwd: cwd, Columns: 80, Rows: 24, Command: command.Argv, Env: command.Env}, s.terminalEvents()); err != nil {
		rt.mu.Lock()
		delete(rt.entries, terminalID)
		rt.mu.Unlock()
		entry.operations.Unlock()
		return "", fmt.Errorf("start %s: %w", command.Argv[0], err)
	}
	rt.persist(entry, s.logger)
	entry.operations.Unlock()
	s.publishTerminalListUpsert(s.terminalListSummary(entry))
	return terminalID, nil
}

// attachTerminal registers the calling client as another stream listener and
// returns the authoritative snapshot. Subscription happens before snapshot
// capture, so live output above the snapshot sequence can be buffered by the
// client without loss. The attaching view becomes the one sizing the PTY.
func (s *Server) attachTerminal(client *rpcClient, params wire.TerminalAttachParams) (wire.TerminalAttachSnapshot, error) {
	rt := s.terminals
	if err := terminal.ValidateSize(params.Columns, params.Rows); err != nil {
		return wire.TerminalAttachSnapshot{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, err)
	}
	appearance, err := parseTerminalAppearance(params.Appearance)
	if err != nil {
		return wire.TerminalAttachSnapshot{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, err)
	}
	entry, ok := rt.lockEntry(params.TerminalID)
	if !ok {
		return wire.TerminalAttachSnapshot{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, terminal.ErrNotFound)
	}
	session, err := rt.service.Get(params.TerminalID)
	if err != nil {
		entry.operations.Unlock()
		return wire.TerminalAttachSnapshot{}, fmt.Errorf("%w: relaunch to start a new shell", terminal.ErrNotRunning)
	}
	if status := session.Status(); status == terminal.StatusStopped || status == terminal.StatusError {
		entry.operations.Unlock()
		return wire.TerminalAttachSnapshot{}, fmt.Errorf("%w: relaunch to start a new shell", terminal.ErrNotRunning)
	}

	undoSubscribe := client.subscribeTerminal(params.TerminalID, params.AttachmentID, params.Columns, params.Rows, appearance)
	// Resize before capturing the snapshot: the attach model reflows to the
	// caller's grid first, so the native snapshot paints current state at
	// exactly the grid the client renders — the mis-wrap class raw replay
	// suffered cannot occur. The snapshot's grid matching the request also
	// keeps the client from immediately re-sending the same resize.
	if err := s.sizeTerminal(entry, session); err != nil {
		undoSubscribe()
		entry.operations.Unlock()
		return wire.TerminalAttachSnapshot{}, fmt.Errorf("terminal attach resize: %w", err)
	}
	// Attaching is seeing: finished and failed statuses go away.
	seen := session.Seen()
	snapshot, err := s.terminalAttachSnapshot(entry, session)
	if err != nil {
		undoSubscribe()
		entry.operations.Unlock()
		return wire.TerminalAttachSnapshot{}, err
	}
	if seen {
		s.publishTerminalListUpsert(snapshot.Terminal)
	}
	entry.operations.Unlock()
	s.logger.Info("terminal attached", "terminal", params.TerminalID, "run", session.RunID, "client", client.id,
		"columns", params.Columns, "rows", params.Rows)
	return snapshot, nil
}

// relaunchTerminal replaces the terminal's run with a fresh shell in the
// persisted cwd and attaches the calling client to the new run.
func (s *Server) relaunchTerminal(client *rpcClient, params wire.TerminalAttachParams) (wire.TerminalAttachSnapshot, error) {
	rt := s.terminals
	if err := terminal.ValidateSize(params.Columns, params.Rows); err != nil {
		return wire.TerminalAttachSnapshot{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, err)
	}
	appearance, err := parseTerminalAppearance(params.Appearance)
	if err != nil {
		return wire.TerminalAttachSnapshot{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, err)
	}
	entry, ok := rt.lockEntry(params.TerminalID)
	if !ok {
		return wire.TerminalAttachSnapshot{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, terminal.ErrNotFound)
	}
	undoSubscribe := client.subscribeTerminal(params.TerminalID, params.AttachmentID, params.Columns, params.Rows, appearance)
	entry.onExit = nil
	session, err := rt.service.Relaunch(params.TerminalID, terminal.SpawnSpec{
		Cwd:     entry.cwd,
		Columns: params.Columns,
		Rows:    params.Rows,
	}, s.terminalEvents())
	if err != nil {
		undoSubscribe()
		entry.operations.Unlock()
		if errors.Is(err, terminal.ErrInvalidDimensions) || errors.Is(err, terminal.ErrInvalidCwd) {
			return wire.TerminalAttachSnapshot{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, err)
		}
		return wire.TerminalAttachSnapshot{}, fmt.Errorf("terminal spawn failed: %w", err)
	}
	// Relaunch is an identity-level action: it bumps updatedAt so the row
	// moves to the top of the Threads list.
	rt.mu.Lock()
	entry.updatedAt = time.Now().UTC()
	rt.mu.Unlock()
	rt.persist(entry, s.logger)
	if err := s.sizeTerminal(entry, session); err != nil {
		s.logger.Warn("terminal appearance failed", "terminal", params.TerminalID, "error", err)
	}

	// Existing listeners need one explicit new-run signal even when the fresh
	// shell has not produced output yet. Their clients reattach for a snapshot;
	// the caller already awaiting this response buffers and deduplicates it.
	s.publishTerminalStreamItem(params.TerminalID, wire.TerminalStreamItem{
		Kind:       terminal.StreamItemStatus,
		TerminalID: params.TerminalID,
		RunID:      session.RunID,
		Status:     terminal.StatusRunning,
	})
	snapshot, err := s.terminalAttachSnapshot(entry, session)
	if err != nil {
		undoSubscribe()
		entry.operations.Unlock()
		s.publishTerminalListUpsert(s.terminalListSummary(entry))
		return wire.TerminalAttachSnapshot{}, err
	}
	entry.operations.Unlock()
	s.publishTerminalListUpsert(snapshot.Terminal)
	s.logger.Info("terminal relaunched", "terminal", params.TerminalID, "run", session.RunID, "client", client.id,
		"columns", params.Columns, "rows", params.Rows)
	return snapshot, nil
}

// detachTerminal removes only the caller's listener without touching the
// shell or any other attached client.
func (s *Server) detachTerminal(client *rpcClient, params wire.TerminalDetachParams) {
	entry, ok := s.terminals.lockEntry(params.TerminalID)
	if !ok {
		return
	}
	defer entry.operations.Unlock()
	if client.detachTerminal(params.TerminalID, params.AttachmentID) {
		s.refreshTerminalAttachment(entry)
	}
}

// refreshTerminalAttachment re-derives, after an attachment went away,
// which remaining view sizes the terminal. Callers hold entry.operations.
func (s *Server) refreshTerminalAttachment(entry *terminalEntry) {
	session, err := s.terminals.service.Get(entry.terminalID)
	if err != nil {
		return
	}
	if err := s.sizeTerminal(entry, session); err != nil && !errors.Is(err, terminal.ErrNotRunning) {
		s.logger.Warn("terminal resize failed", "terminal", entry.terminalID, "error", err)
	}
}

// latestTerminalView is the connection whose view last attached or
// resized: the view that sizes the PTY and whose appearance the program's
// queries get. Typing claims the size by resizing first. Callers hold
// entry.operations.
func (s *Server) latestTerminalView(terminalID string) (*rpcClient, terminalAttachment) {
	var latestClient *rpcClient
	var latest terminalAttachment
	for _, client := range s.terminalSubscribers(terminalID) {
		if attachment, ok := client.terminalAttachment(terminalID); ok && attachment.lastUsed > latest.lastUsed {
			latestClient, latest = client, attachment
		}
	}
	return latestClient, latest
}

// sizeTerminal gives the PTY the grid, and the program's queries the
// appearance, of the latest view. One PTY has one size, and the view someone
// is typing into is the one that must not garble; this is tmux's default
// window-size "latest". With nobody attached the size stays. Callers hold
// entry.operations.
func (s *Server) sizeTerminal(entry *terminalEntry, session *terminal.Session) error {
	client, latest := s.latestTerminalView(entry.terminalID)
	if client == nil {
		return nil
	}
	if err := session.SetAppearance(latest.appearance); err != nil && !errors.Is(err, terminal.ErrNotRunning) {
		return err
	}
	if columns, rows := session.Size(); columns == latest.columns && rows == latest.rows {
		return nil
	}
	if err := session.Resize(latest.columns, latest.rows); err != nil {
		// A run that ended keeps its grid.
		if errors.Is(err, terminal.ErrNotRunning) {
			return nil
		}
		return err
	}
	s.logger.Info("terminal resized", "terminal", entry.terminalID, "columns", latest.columns, "rows", latest.rows)
	return nil
}

func (s *Server) terminalAttachSnapshot(entry *terminalEntry, session *terminal.Session) (wire.TerminalAttachSnapshot, error) {
	snapshot, err := session.Snapshot()
	if err != nil {
		return wire.TerminalAttachSnapshot{}, fmt.Errorf("terminal attach snapshot: %w", err)
	}
	summary := s.terminalMetaSummary(entry)
	summary.Status = snapshot.Status
	summary.ExitCode = snapshot.ExitCode
	applyProgram(&summary, session.Program())
	return wire.TerminalAttachSnapshot{
		Terminal:       summary,
		RunID:          snapshot.RunID,
		Sequence:       snapshot.Sequence,
		Columns:        snapshot.Columns,
		Rows:           snapshot.Rows,
		SnapshotFormat: snapshot.SnapshotFormat,
		Snapshot:       snapshot.Data,
	}, nil
}

// terminalMetaSummary carries only persisted identity; the caller overlays
// live-run fields when a session exists. Without one the terminal is stopped.
func (s *Server) terminalMetaSummary(entry *terminalEntry) wire.TerminalSummary {
	rt := s.terminals
	rt.mu.Lock()
	defer rt.mu.Unlock()
	return wire.TerminalSummary{
		TerminalID: entry.terminalID,
		Title:      entry.title,
		Cwd:        entry.cwd,
		Status:     terminal.StatusStopped,
		CreatedAt:  entry.createdAt,
		UpdatedAt:  entry.updatedAt,
	}
}

func (s *Server) terminateTerminal(terminalID string) error {
	rt := s.terminals
	entry, ok := rt.lockEntry(terminalID)
	if !ok {
		return fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, terminal.ErrNotFound)
	}
	defer entry.operations.Unlock()
	if err := rt.service.Terminate(terminalID); err != nil {
		if errors.Is(err, terminal.ErrNotFound) {
			return fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, err)
		}
		return err
	}
	s.logger.Info("terminal terminated", "terminal", terminalID)
	return nil
}

// renameTerminal is an identity-level action: it changes the persisted title
// and bumps updatedAt.
func (s *Server) renameTerminal(params wire.TerminalRenameParams) (wire.TerminalSummary, error) {
	rt := s.terminals
	entry, ok := rt.lockEntry(params.TerminalID)
	if !ok {
		return wire.TerminalSummary{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, terminal.ErrNotFound)
	}
	defer entry.operations.Unlock()
	rt.mu.Lock()
	entry.title = params.Title
	entry.updatedAt = time.Now().UTC()
	rt.mu.Unlock()
	rt.persist(entry, s.logger)

	summary := s.terminalListSummary(entry)
	s.publishTerminalListUpsert(summary)
	return summary, nil
}

// deleteTerminal terminates any live run and removes the terminal's identity.
func (s *Server) deleteTerminal(terminalID string) error {
	rt := s.terminals
	entry, ok := rt.lockEntry(terminalID)
	if !ok {
		return fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, terminal.ErrNotFound)
	}
	defer entry.operations.Unlock()
	// Remove terminates the live process group when one exists.
	if err := rt.service.Remove(terminalID); err != nil && !errors.Is(err, terminal.ErrNotFound) {
		return err
	}
	rt.mu.Lock()
	delete(rt.entries, terminalID)
	rt.mu.Unlock()
	s.unsubscribeAllTerminalClients(terminalID)
	if rt.meta != nil {
		if err := rt.meta.DeleteTerminal(terminalID); err != nil {
			s.logger.Warn("delete terminal metadata", "terminal", terminalID, "error", err)
		}
	}
	s.publishTerminalListRemoved(terminalID)
	s.logger.Info("terminal deleted", "terminal", terminalID)
	return nil
}

// subscribeTerminalList registers the client for terminal list updates and
// returns the deterministic snapshot: updatedAt descending, then terminal id.
func (s *Server) subscribeTerminalList(client *rpcClient) wire.TerminalListStreamItem {
	client.subscribeTerminalList()
	rt := s.terminals
	rt.mu.Lock()
	entries := make([]*terminalEntry, 0, len(rt.entries))
	for _, entry := range rt.entries {
		entries = append(entries, entry)
	}
	rt.mu.Unlock()

	summaries := make([]wire.TerminalSummary, 0, len(entries))
	for _, entry := range entries {
		summaries = append(summaries, s.terminalListSummary(entry))
	}
	slices.SortFunc(summaries, func(a, b wire.TerminalSummary) int {
		if c := b.UpdatedAt.Compare(a.UpdatedAt); c != 0 {
			return c
		}
		return cmp.Compare(a.TerminalID, b.TerminalID)
	})
	return wire.TerminalListStreamItem{Kind: wire.TerminalListItemSnapshot, Terminals: summaries}
}

// terminalListSummary overlays live-run state (without replay bytes) on the
// persisted identity for list rows.
func (s *Server) terminalListSummary(entry *terminalEntry) wire.TerminalSummary {
	summary := s.terminalMetaSummary(entry)
	if session, err := s.terminals.service.Get(entry.terminalID); err == nil {
		summary.Status = session.Status()
		if code, ok := session.ExitCode(); ok {
			summary.ExitCode = &code
		}
		applyProgram(&summary, session.Program())
	}
	return summary
}

// applyProgram copies what the program reports about itself onto a summary.
func applyProgram(summary *wire.TerminalSummary, program terminal.ProgramInfo) {
	summary.ProgramTitle = program.Title
	summary.Pwd = program.Pwd
	if status := program.Status; status != nil {
		summary.ProgramStatus = &wire.TerminalProgramStatus{
			State:     status.State,
			Need:      status.Need,
			Progress:  status.Progress,
			App:       status.App,
			Title:     status.Title,
			Message:   status.Message,
			UpdatedAt: status.UpdatedAt,
		}
	}
}

// publishTerminalProgram fans a changed title, working directory or program
// status out as a terminal-list upsert, so other devices see it without
// attaching. A stale run's change is dropped by the run check.
func (s *Server) publishTerminalProgram(terminalID, runID string) {
	rt := s.terminals
	rt.mu.Lock()
	entry, ok := rt.entries[terminalID]
	rt.mu.Unlock()
	if !ok {
		return
	}
	session, err := rt.service.Get(terminalID)
	if err != nil || session.RunID != runID {
		return
	}
	s.publishTerminalListUpsert(s.terminalListSummary(entry))
}

// publishTerminalListUpsert fans one changed summary out to list subscribers.
// List updates happen only for identity and lifecycle changes, so the normal
// bounded notify path is sufficient.
func (s *Server) publishTerminalListUpsert(summary wire.TerminalSummary) {
	s.publishTerminalListItem(wire.TerminalListStreamItem{
		Kind:     wire.TerminalListItemUpserted,
		Terminal: &summary,
	})
}

func (s *Server) publishTerminalListRemoved(terminalID string) {
	s.publishTerminalListItem(wire.TerminalListStreamItem{
		Kind:       wire.TerminalListItemRemoved,
		TerminalID: terminalID,
	})
}

func (s *Server) publishTerminalListItem(item wire.TerminalListStreamItem) {
	s.rpcMu.Lock()
	var subscribers []*rpcClient
	for _, client := range s.rpcClients {
		if client.subscribedTerminalList() {
			subscribers = append(subscribers, client)
		}
	}
	s.rpcMu.Unlock()
	if len(subscribers) == 0 {
		return
	}
	params, ok := s.marshalNotification(item, wire.MethodTerminalSubscribeList)
	if !ok {
		return
	}
	for _, client := range subscribers {
		client.notify(wire.MethodTerminalSubscribeList, params)
	}
}

func (s *Server) terminalSubscribers(terminalID string) []*rpcClient {
	s.rpcMu.Lock()
	defer s.rpcMu.Unlock()
	subscribers := make([]*rpcClient, 0, len(s.rpcClients))
	for _, client := range s.rpcClients {
		if client.subscribedTerminal(terminalID) {
			subscribers = append(subscribers, client)
		}
	}
	return subscribers
}

func (s *Server) unsubscribeAllTerminalClients(terminalID string) {
	for _, client := range s.terminalSubscribers(terminalID) {
		client.unsubscribeTerminal(terminalID)
	}
}

// publishTerminalStreamItem fans one ordered run item to every attached
// connection. Each connection owns its own bounded queue; a slow listener is
// disconnected and recovers through a new snapshot without delaying healthy
// listeners or the PTY reader.
func (s *Server) publishTerminalStreamItem(terminalID string, item wire.TerminalStreamItem) {
	subscribers := s.terminalSubscribers(terminalID)
	if len(subscribers) == 0 {
		return
	}
	params, ok := s.marshalNotification(item, wire.MethodTerminalSubscribe)
	if !ok {
		return
	}
	for _, client := range subscribers {
		client.notify(wire.MethodTerminalSubscribe, params)
	}
}

// writeTerminal accepts input from any view attached to this run. Clients
// never answer the program (the daemon's terminal does), so everything they
// send is the user's; a view that types claims the size by resizing first.
// Stale-run and unattached input is dropped silently as a routine lifecycle
// race rather than surfaced as a repeating alert.
func (s *Server) writeTerminal(client *rpcClient, params wire.TerminalWriteParams) error {
	session, entry, ok := s.terminalSessionForSubscriber(client, params.TerminalID, params.RunID)
	if !ok {
		return nil
	}
	defer entry.operations.Unlock()
	if err := session.Write(params.Data); err != nil && !errors.Is(err, terminal.ErrNotRunning) {
		s.logger.Warn("terminal write failed", "terminal", params.TerminalID, "error", err)
	}
	return nil
}

func (s *Server) resizeTerminal(client *rpcClient, params wire.TerminalResizeParams) error {
	session, entry, ok := s.terminalSessionForSubscriber(client, params.TerminalID, params.RunID)
	if !ok {
		return nil
	}
	defer entry.operations.Unlock()
	appearance, err := parseTerminalAppearance(params.Appearance)
	if err == nil {
		err = terminal.ValidateSize(params.Columns, params.Rows)
	}
	if err != nil {
		s.logger.Warn("terminal resize rejected", "terminal", params.TerminalID, "client", client.id, "error", err)
		return nil
	}
	// A resize claims the size.
	if !client.resizeTerminalAttachment(params.TerminalID, params.Columns, params.Rows, appearance) {
		return nil
	}
	if err := s.sizeTerminal(entry, session); err != nil && !errors.Is(err, terminal.ErrNotRunning) {
		s.logger.Warn("terminal resize failed", "terminal", params.TerminalID, "error", err)
	}
	return nil
}

// terminalSessionForSubscriber authorizes one input/resize operation: the
// terminal and live run must exist, the run id must match, and the sender must
// have attached to the terminal on this connection.
func (s *Server) terminalSessionForSubscriber(client *rpcClient, terminalID, runID string) (*terminal.Session, *terminalEntry, bool) {
	rt := s.terminals
	entry, ok := rt.lockEntry(terminalID)
	if !ok {
		return nil, nil, false
	}
	if !client.subscribedTerminal(terminalID) {
		entry.operations.Unlock()
		return nil, nil, false
	}
	session, err := rt.service.Get(terminalID)
	if err != nil || session.RunID != runID {
		entry.operations.Unlock()
		return nil, nil, false
	}
	return session, entry, true
}

func (s *Server) terminalEvents() terminal.Events {
	return terminal.Events{
		Output:         s.publishTerminalOutput,
		Resized:        s.publishTerminalResized,
		Exit:           s.publishTerminalExit,
		ProgramChanged: s.publishTerminalProgram,
	}
}

func (s *Server) publishTerminalResized(terminalID, runID string, seq uint64, columns, rows uint16) {
	s.publishTerminalStreamItem(terminalID, wire.TerminalStreamItem{
		Kind:       terminal.StreamItemResized,
		TerminalID: terminalID,
		RunID:      runID,
		Sequence:   seq,
		Columns:    columns,
		Rows:       rows,
	})
}

func (s *Server) publishTerminalOutput(terminalID, runID string, seq uint64, data []byte) {
	s.publishTerminalStreamItem(terminalID, wire.TerminalStreamItem{
		Kind:       terminal.StreamItemOutput,
		TerminalID: terminalID,
		RunID:      runID,
		Sequence:   seq,
		Data:       data,
	})
}

func (s *Server) publishTerminalExit(terminalID, runID string, seq uint64, status terminal.Status, exitCode *int) {
	s.logger.Info("terminal run ended", "terminal", terminalID, "run", runID, "status", status)
	entry, ok := s.terminals.lockEntry(terminalID)
	if !ok {
		return
	}
	current, currentErr := s.terminals.service.Get(terminalID)
	if currentErr != nil || current.RunID != runID {
		// Relaunch already installed a replacement. Its explicit running signal
		// supersedes this old run's terminal status for every listener.
		entry.operations.Unlock()
		return
	}
	summary := s.terminalListSummary(entry)
	// Enqueue the run's final list state before releasing the terminal fence,
	// so a later relaunch/delete update cannot be overtaken by this exit.
	s.publishTerminalListUpsert(summary)
	onExit := entry.onExit
	entry.onExit = nil
	entry.operations.Unlock()
	if onExit != nil {
		go onExit(exitCode)
	}

	s.publishTerminalStreamItem(terminalID, wire.TerminalStreamItem{
		Kind:       terminal.StreamItemStatus,
		TerminalID: terminalID,
		RunID:      runID,
		Sequence:   seq,
		Status:     status,
		ExitCode:   exitCode,
	})
}

// parseTerminalAppearance validates a view's appearance at the RPC boundary.
func parseTerminalAppearance(appearance wire.TerminalAppearance) (vtscreen.Appearance, error) {
	var parsed vtscreen.Appearance
	switch appearance.ColorScheme {
	case terminal.ColorSchemeDark:
		parsed.Dark = true
	case terminal.ColorSchemeLight:
	default:
		return parsed, fmt.Errorf("appearance color scheme %q is not light or dark", appearance.ColorScheme)
	}
	var err error
	if parsed.Foreground, err = parseTerminalColor(appearance.Foreground); err != nil {
		return parsed, err
	}
	if parsed.Background, err = parseTerminalColor(appearance.Background); err != nil {
		return parsed, err
	}
	if len(appearance.Palette) > 256 {
		return parsed, fmt.Errorf("appearance palette has %d colors, over 256", len(appearance.Palette))
	}
	parsed.Palette = make([]vtscreen.RGB, len(appearance.Palette))
	for index, color := range appearance.Palette {
		if parsed.Palette[index], err = parseTerminalColor(color); err != nil {
			return parsed, err
		}
	}
	return parsed, nil
}

// parseTerminalColor reads "#rrggbb".
func parseTerminalColor(color string) (vtscreen.RGB, error) {
	hex, ok := strings.CutPrefix(color, "#")
	value, err := strconv.ParseUint(hex, 16, 32)
	if !ok || len(hex) != 6 || err != nil {
		return vtscreen.RGB{}, fmt.Errorf("appearance color %q is not #rrggbb", color)
	}
	return vtscreen.RGB{R: uint8(value >> 16), G: uint8(value >> 8), B: uint8(value)}, nil
}
