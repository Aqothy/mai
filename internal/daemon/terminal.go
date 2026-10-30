package daemon

import (
	"cmp"
	"errors"
	"fmt"
	"log/slog"
	"maps"
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

// errTerminalClientClosed fails a terminal call from a connection that closed
// while it ran.
var errTerminalClientClosed = errors.New("terminal: connection closed")

// terminalRuntime composes the PTY service with RPC concerns: terminal
// identity, notification fanout, and SQLite metadata.
// Only identity metadata is durable; a daemon restart reports every persisted
// terminal as stopped.
type terminalRuntime struct {
	service *terminal.Service
	meta    store.TerminalStore // nil when metadata persistence is unavailable

	mu      sync.Mutex
	entries map[string]*terminalEntry
	// listMu orders terminal-list publications: each reads a terminal's
	// current state and enqueues it while holding listMu, so subscribers
	// receive states in the order they happened. It is taken on the PTY's
	// event path, so its holders never wait for entry.operations or a
	// session's output.
	listMu sync.Mutex
}

type terminalEntry struct {
	// operations fences lifecycle work for this terminal without serializing
	// unrelated terminals.
	operations sync.Mutex
	views      terminalViews

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
	// Register the entry and the view before the shell starts so no early
	// output is lost; the client buffers stream items until this call returns
	// its snapshot. The view is attached once the entry is registered, where a
	// closing connection finds it.
	rt.mu.Lock()
	rt.entries[terminalID] = entry
	rt.mu.Unlock()
	view := terminalView{
		client: client, attachmentID: params.AttachmentID,
		columns: params.Columns, rows: params.Rows, appearance: appearance,
	}
	if !entry.views.attach(view, true) {
		rt.mu.Lock()
		delete(rt.entries, terminalID)
		rt.mu.Unlock()
		entry.operations.Unlock()
		return wire.TerminalAttachSnapshot{}, errTerminalClientClosed
	}

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
			entry.operations.Unlock()
			return wire.TerminalAttachSnapshot{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, err)
		}
		// Spawn failures keep the stopped metadata row so the user can retry
		// or delete it.
		entry.views.detach(client, params.AttachmentID)
		rt.persist(entry, s.logger)
		entry.operations.Unlock()
		s.publishTerminalList(terminalID)
		return wire.TerminalAttachSnapshot{}, fmt.Errorf("terminal spawn failed: %w", err)
	}

	rt.persist(entry, s.logger)
	s.sizeToActiveView(entry)
	snapshot, err := s.terminalAttachSnapshot(entry, session)
	if err != nil {
		entry.views.detach(client, params.AttachmentID)
		entry.operations.Unlock()
		s.publishTerminalList(terminalID)
		return wire.TerminalAttachSnapshot{}, err
	}
	entry.operations.Unlock()
	s.publishTerminalList(terminalID)
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
	s.publishTerminalList(terminalID)
	return terminalID, nil
}

// attachTerminal adds the calling client's view and returns the
// authoritative snapshot. The view joins before the snapshot is captured, so
// live output above the snapshot sequence can be buffered by the client
// without loss. A view the user opens takes the size; one reattaching keeps
// its place, so it never takes the size from the device in use.
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

	view := terminalView{
		client: client, attachmentID: params.AttachmentID,
		columns: params.Columns, rows: params.Rows, appearance: appearance,
	}
	if !entry.views.attach(view, params.Focus) {
		entry.operations.Unlock()
		return wire.TerminalAttachSnapshot{}, errTerminalClientClosed
	}
	// Size before capturing the snapshot, so the native snapshot paints
	// current state at the grid the PTY has from here on.
	s.sizeToActiveView(entry)
	// Attaching is seeing: finished and failed statuses go away.
	seen := session.Seen()
	snapshot, err := s.terminalAttachSnapshot(entry, session)
	if err != nil {
		entry.views.detach(client, params.AttachmentID)
		entry.operations.Unlock()
		return wire.TerminalAttachSnapshot{}, err
	}
	if seen {
		s.publishTerminalList(params.TerminalID)
	}
	entry.operations.Unlock()
	s.logger.Info("terminal attached", "terminal", params.TerminalID, "run", session.RunID, "client", client.id,
		"columns", params.Columns, "rows", params.Rows, "focus", params.Focus)
	return snapshot, nil
}

// relaunchTerminal replaces the terminal's run with a fresh shell in the
// persisted cwd and attaches the calling client to the new run.
func (s *Server) relaunchTerminal(client *rpcClient, params wire.TerminalRelaunchParams) (wire.TerminalAttachSnapshot, error) {
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
	view := terminalView{
		client: client, attachmentID: params.AttachmentID,
		columns: params.Columns, rows: params.Rows, appearance: appearance,
	}
	if !entry.views.attach(view, true) {
		entry.operations.Unlock()
		return wire.TerminalAttachSnapshot{}, errTerminalClientClosed
	}
	entry.onExit = nil
	session, err := rt.service.Relaunch(params.TerminalID, terminal.SpawnSpec{
		Cwd:     entry.cwd,
		Columns: params.Columns,
		Rows:    params.Rows,
	}, s.terminalEvents())
	if err != nil {
		entry.views.detach(client, params.AttachmentID)
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
	s.sizeToActiveView(entry)

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
		entry.views.detach(client, params.AttachmentID)
		entry.operations.Unlock()
		s.publishTerminalList(params.TerminalID)
		return wire.TerminalAttachSnapshot{}, err
	}
	entry.operations.Unlock()
	s.publishTerminalList(params.TerminalID)
	s.logger.Info("terminal relaunched", "terminal", params.TerminalID, "run", session.RunID, "client", client.id,
		"columns", params.Columns, "rows", params.Rows)
	return snapshot, nil
}

// detachTerminal removes only the caller's view without touching the shell;
// if it was active, the view active before it takes the size.
func (s *Server) detachTerminal(client *rpcClient, params wire.TerminalDetachParams) {
	entry, ok := s.terminals.lockEntry(params.TerminalID)
	if !ok {
		return
	}
	defer entry.operations.Unlock()
	if entry.views.detach(client, params.AttachmentID) {
		s.sizeToActiveView(entry)
	}
}

// detachClientTerminals removes a closed connection's views, handing each
// terminal it was active on back to the view active before it.
func (s *Server) detachClientTerminals(client *rpcClient) {
	rt := s.terminals
	rt.mu.Lock()
	entries := slices.Collect(maps.Values(rt.entries))
	rt.mu.Unlock()
	for _, entry := range entries {
		// An attach still running sees the connection closed and undoes
		// itself, so only views already attached need removing.
		if !entry.views.attached(client) {
			continue
		}
		entry, ok := rt.lockEntry(entry.terminalID)
		if !ok {
			continue
		}
		if entry.views.remove(client) {
			s.sizeToActiveView(entry)
		}
		entry.operations.Unlock()
	}
}

// sizeToActiveView gives the terminal's live run the active view's grid, and
// the program's queries its appearance. One PTY has one size, and the view
// someone is using is the one that must not garble. A run that ended keeps
// its grid. Callers hold entry.operations.
func (s *Server) sizeToActiveView(entry *terminalEntry) {
	view, ok := entry.views.active()
	if !ok {
		return
	}
	session, err := s.terminals.service.Get(entry.terminalID)
	if err != nil {
		return
	}
	if err := session.SetAppearance(view.appearance); err != nil && !errors.Is(err, terminal.ErrNotRunning) {
		s.logger.Warn("terminal appearance failed", "terminal", entry.terminalID, "error", err)
	}
	if c, r := session.Size(); c == view.columns && r == view.rows {
		return
	}
	if err := session.Resize(view.columns, view.rows); err != nil {
		if !errors.Is(err, terminal.ErrNotRunning) {
			s.logger.Warn("terminal resize failed", "terminal", entry.terminalID, "error", err)
		}
		return
	}
	s.logger.Info("terminal resized", "terminal", entry.terminalID, "columns", view.columns, "rows", view.rows)
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

	s.publishTerminalList(params.TerminalID)
	return s.terminalListSummary(entry), nil
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
	entry.views.clear()
	if rt.meta != nil {
		if err := rt.meta.DeleteTerminal(terminalID); err != nil {
			s.logger.Warn("delete terminal metadata", "terminal", terminalID, "error", err)
		}
	}
	s.publishTerminalList(terminalID)
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
// status out to the list, so other devices see it without attaching.
func (s *Server) publishTerminalProgram(terminalID string) {
	s.publishTerminalList(terminalID)
}

// publishTerminalList fans a terminal's current list state out to list
// subscribers: an upsert, or a removal once it's deleted. Reading the state
// and enqueueing it under listMu means a slower publisher can't overwrite a
// newer state with an older one.
func (s *Server) publishTerminalList(terminalID string) {
	rt := s.terminals
	rt.listMu.Lock()
	defer rt.listMu.Unlock()
	rt.mu.Lock()
	entry, ok := rt.entries[terminalID]
	rt.mu.Unlock()
	if !ok {
		s.publishTerminalListItem(wire.TerminalListStreamItem{
			Kind:       wire.TerminalListItemRemoved,
			TerminalID: terminalID,
		})
		return
	}
	summary := s.terminalListSummary(entry)
	s.publishTerminalListItem(wire.TerminalListStreamItem{
		Kind:     wire.TerminalListItemUpserted,
		Terminal: &summary,
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

// publishTerminalStreamItem fans one ordered run item to every attached
// connection. Each connection owns its own bounded queue; a slow listener is
// disconnected and recovers through a new snapshot without delaying healthy
// listeners or the PTY reader.
func (s *Server) publishTerminalStreamItem(terminalID string, item wire.TerminalStreamItem) {
	rt := s.terminals
	rt.mu.Lock()
	entry, ok := rt.entries[terminalID]
	rt.mu.Unlock()
	if !ok {
		return
	}
	subscribers := entry.views.clients()
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
// send is the user's: keys, pastes, and the mouse and focus reports the
// program asked for. Input doesn't take the size, since reports arrive
// without the user using the view (a Mac locking reports focus out); a view
// sends terminal.focus before what the user types. Stale-run and unattached
// input is dropped silently as a routine lifecycle race rather than surfaced
// as a repeating alert.
func (s *Server) writeTerminal(client *rpcClient, params wire.TerminalWriteParams) error {
	entry, ok := s.terminals.lockEntry(params.TerminalID)
	if !ok {
		return nil
	}
	defer entry.operations.Unlock()
	session, err := s.terminals.service.Get(params.TerminalID)
	if err != nil || session.RunID != params.RunID || !entry.views.attached(client) {
		return nil
	}
	if err := session.Write(params.Data); err != nil && !errors.Is(err, terminal.ErrNotRunning) {
		s.logger.Warn("terminal write failed", "terminal", params.TerminalID, "error", err)
	}
	return nil
}

// resizeTerminal records the grid and appearance that now fit the calling
// view; the PTY follows only the active view.
func (s *Server) resizeTerminal(client *rpcClient, params wire.TerminalResizeParams) error {
	appearance, err := parseTerminalAppearance(params.Appearance)
	if err == nil {
		err = terminal.ValidateSize(params.Columns, params.Rows)
	}
	if err != nil {
		s.logger.Warn("terminal resize rejected", "terminal", params.TerminalID, "client", client.id, "error", err)
		return nil
	}
	entry, ok := s.terminals.lockEntry(params.TerminalID)
	if !ok {
		return nil
	}
	defer entry.operations.Unlock()
	if _, active := entry.views.update(client, params.Columns, params.Rows, appearance); active {
		s.sizeToActiveView(entry)
	}
	return nil
}

// focusTerminal gives the size to the view the user focused or pressed.
func (s *Server) focusTerminal(client *rpcClient, terminalID string) {
	entry, ok := s.terminals.lockEntry(terminalID)
	if !ok {
		return
	}
	defer entry.operations.Unlock()
	if entry.views.activate(client) {
		s.sizeToActiveView(entry)
	}
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
	s.publishTerminalList(terminalID)
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
