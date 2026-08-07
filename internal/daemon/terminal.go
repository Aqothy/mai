package daemon

import (
	"cmp"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"sync"
	"time"

	"github.com/Aqothy/jsonrpc2"
	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/store"
	"github.com/Aqothy/maiD/internal/terminal"
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

// close terminates every live shell and waits for process-group cleanup.
func (rt *terminalRuntime) close() {
	rt.service.Close()
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
	if rt == nil {
		return wire.TerminalAttachSnapshot{}, fmt.Errorf("terminal service is unavailable")
	}
	cwd, err := terminal.ResolveCwd(params.Cwd)
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
	client.subscribeTerminal(terminalID)
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
	}, terminal.Events{
		Output: s.publishTerminalOutput,
		Exit:   s.publishTerminalExit,
		Agent:  s.publishTerminalAgentReport,
	})
	if err != nil {
		if errors.Is(err, terminal.ErrInvalidDimensions) {
			// Nothing useful was created; a dimension bug should not leave a
			// ghost row.
			rt.mu.Lock()
			delete(rt.entries, terminalID)
			rt.mu.Unlock()
			client.unsubscribeTerminal(terminalID)
			entry.operations.Unlock()
			return wire.TerminalAttachSnapshot{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, err)
		}
		// Spawn failures keep the stopped metadata row so the user can retry
		// or delete it.
		client.unsubscribeTerminal(terminalID)
		rt.persist(entry, s.logger)
		entry.operations.Unlock()
		s.publishTerminalListUpsert(s.terminalMetaSummary(entry))
		return wire.TerminalAttachSnapshot{}, fmt.Errorf("terminal spawn failed: %w", err)
	}

	rt.persist(entry, s.logger)
	session.SetAttached(true)
	snapshot := s.terminalAttachSnapshot(entry, session)
	entry.operations.Unlock()
	s.publishTerminalListUpsert(snapshot.Terminal)
	s.logger.Info("terminal created", "terminal", terminalID, "run", session.RunID, "client", client.id,
		"columns", params.Columns, "rows", params.Rows)
	return snapshot, nil
}

// attachTerminal registers the calling client as another stream listener and
// returns the authoritative snapshot. Subscription happens before snapshot
// capture, so live output above the snapshot sequence can be buffered by the
// client without loss. The latest resize wins, matching ordinary PTY behavior.
func (s *Server) attachTerminal(client *rpcClient, params wire.TerminalAttachParams) (wire.TerminalAttachSnapshot, error) {
	rt := s.terminals
	if rt == nil {
		return wire.TerminalAttachSnapshot{}, fmt.Errorf("terminal service is unavailable")
	}
	if err := terminal.ValidateSize(params.Columns, params.Rows); err != nil {
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

	client.subscribeTerminal(params.TerminalID)
	// Attaching acknowledges a pending done state so the row returns to its
	// current live activity once someone has looked at the result.
	session.SetAttached(true)
	snapshot := s.terminalAttachSnapshot(entry, session)
	if err := session.Resize(params.Columns, params.Rows); err != nil {
		if !errors.Is(err, terminal.ErrNotRunning) {
			s.logger.Warn("terminal attach resize failed", "terminal", params.TerminalID, "error", err)
		}
	} else {
		// Replay and sequence intentionally describe the pre-resize attach
		// point, while the returned metadata describes the grid now installed
		// on the PTY. This prevents the client from sending the same resize a
		// second time immediately after applying the snapshot.
		snapshot.Terminal.Columns = params.Columns
		snapshot.Terminal.Rows = params.Rows
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
	if rt == nil {
		return wire.TerminalAttachSnapshot{}, fmt.Errorf("terminal service is unavailable")
	}
	if err := terminal.ValidateSize(params.Columns, params.Rows); err != nil {
		return wire.TerminalAttachSnapshot{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, err)
	}
	entry, ok := rt.lockEntry(params.TerminalID)
	if !ok {
		return wire.TerminalAttachSnapshot{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, terminal.ErrNotFound)
	}
	addedSubscription := client.subscribeTerminal(params.TerminalID)
	session, err := rt.service.Relaunch(params.TerminalID, terminal.SpawnSpec{
		Cwd:     entry.cwd,
		Columns: params.Columns,
		Rows:    params.Rows,
	}, terminal.Events{
		Output: s.publishTerminalOutput,
		Exit:   s.publishTerminalExit,
		Agent:  s.publishTerminalAgentReport,
	})
	if err != nil {
		if addedSubscription {
			client.unsubscribeTerminal(params.TerminalID)
		}
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

	session.SetAttached(true)
	snapshot := s.terminalAttachSnapshot(entry, session)
	entry.operations.Unlock()
	// Existing listeners need one explicit new-run signal even when the fresh
	// shell has not produced output yet. Their clients reattach for a snapshot;
	// the caller already awaiting this response simply buffers and deduplicates
	// the signal by sequence.
	s.publishTerminalStreamItem(params.TerminalID, wire.TerminalStreamItem{
		Kind:       terminal.StreamItemStatus,
		TerminalID: params.TerminalID,
		RunID:      session.RunID,
		Status:     terminal.StatusRunning,
	})
	s.publishTerminalListUpsert(snapshot.Terminal)
	s.logger.Info("terminal relaunched", "terminal", params.TerminalID, "run", session.RunID, "client", client.id,
		"columns", params.Columns, "rows", params.Rows)
	return snapshot, nil
}

// detachTerminal removes only the caller's listener without touching the
// shell or any other attached client. A stale detach from an old run is a
// no-op so it cannot remove a newer attachment on the same connection.
func (s *Server) detachTerminal(client *rpcClient, params wire.TerminalDetachParams) {
	rt := s.terminals
	if rt == nil {
		return
	}
	entry, ok := rt.lockEntry(params.TerminalID)
	if !ok {
		return
	}
	defer entry.operations.Unlock()
	session, err := rt.service.Get(params.TerminalID)
	if err != nil || session.RunID != params.RunID {
		return
	}
	client.unsubscribeTerminal(params.TerminalID)
	session.SetAttached(len(s.terminalSubscribers(params.TerminalID)) > 0)
}

func (s *Server) terminalAttachSnapshot(entry *terminalEntry, session *terminal.Session) wire.TerminalAttachSnapshot {
	snapshot := session.Snapshot()
	summary := s.terminalMetaSummary(entry)
	summary.Status = snapshot.Status
	summary.Columns = snapshot.Columns
	summary.Rows = snapshot.Rows
	summary.ExitCode = snapshot.ExitCode
	applyAgentReport(&summary, session.AgentReport())
	return wire.TerminalAttachSnapshot{
		Terminal:        summary,
		RunID:           snapshot.RunID,
		Sequence:        snapshot.Sequence,
		Replay:          snapshot.Replay,
		ReplayTruncated: snapshot.ReplayTruncated,
	}
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
	if rt == nil {
		return fmt.Errorf("terminal service is unavailable")
	}
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
	if rt == nil {
		return wire.TerminalSummary{}, fmt.Errorf("terminal service is unavailable")
	}
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

	summary := s.terminalListSummary(params.TerminalID, entry)
	s.publishTerminalListUpsert(summary)
	return summary, nil
}

// deleteTerminal terminates any live run and removes the terminal's identity.
func (s *Server) deleteTerminal(terminalID string) error {
	rt := s.terminals
	if rt == nil {
		return fmt.Errorf("terminal service is unavailable")
	}
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
	if rt == nil {
		return wire.TerminalListStreamItem{Kind: wire.TerminalListItemSnapshot, Terminals: []wire.TerminalSummary{}}
	}
	rt.mu.Lock()
	entries := make([]*terminalEntry, 0, len(rt.entries))
	for _, entry := range rt.entries {
		entries = append(entries, entry)
	}
	rt.mu.Unlock()

	summaries := make([]wire.TerminalSummary, 0, len(entries))
	for _, entry := range entries {
		summaries = append(summaries, s.terminalListSummary(entry.terminalID, entry))
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
func (s *Server) terminalListSummary(terminalID string, entry *terminalEntry) wire.TerminalSummary {
	summary := s.terminalMetaSummary(entry)
	if session, err := s.terminals.service.Get(terminalID); err == nil {
		summary.Status = session.Status()
		summary.Columns, summary.Rows = session.Size()
		if code, ok := session.ExitCode(); ok {
			summary.ExitCode = &code
		}
		applyAgentReport(&summary, session.AgentReport())
	}
	return summary
}

// applyAgentReport copies the detector's semantic result onto a summary. The
// report carries only the normalized title and semantic fields; nothing else
// crosses the wire.
func applyAgentReport(summary *wire.TerminalSummary, report terminal.AgentReport) {
	summary.ObservedTitle = report.Title
	summary.AgentKind = report.Kind
	summary.AgentActivity = report.Activity
	if !report.UpdatedAt.IsZero() {
		at := report.UpdatedAt
		summary.AgentActivityUpdatedAt = &at
	}
}

// publishTerminalAgentReport fans one changed semantic agent state out as a
// terminal-list upsert. The detector already deduplicated the report; a stale
// run's report is dropped by the run check.
func (s *Server) publishTerminalAgentReport(terminalID, runID string, report terminal.AgentReport) {
	rt := s.terminals
	if rt == nil {
		return
	}
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
	s.logger.Debug("terminal agent activity", "terminal", terminalID, "run", runID,
		"agent", report.Kind, "activity", report.Activity)
	s.publishTerminalListUpsert(s.terminalListSummary(terminalID, entry))
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
	params, ok := s.marshalNotification(item, RPCMethodTerminalSubscribeList)
	if !ok {
		return
	}
	for _, client := range subscribers {
		client.notify(RPCMethodTerminalSubscribeList, params)
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
	params, ok := s.marshalNotification(item, RPCMethodTerminalSubscribe)
	if !ok {
		return
	}
	for _, client := range subscribers {
		client.notify(RPCMethodTerminalSubscribe, params)
	}
}

// writeTerminal accepts input from any client currently attached to this run.
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
	err := session.Resize(params.Columns, params.Rows)
	if err != nil && !errors.Is(err, terminal.ErrNotRunning) {
		s.logger.Warn("terminal resize failed", "terminal", params.TerminalID, "error", err)
	} else if err == nil {
		s.logger.Info("terminal resized", "terminal", params.TerminalID, "client", client.id,
			"columns", params.Columns, "rows", params.Rows)
	}
	return nil
}

// terminalSessionForSubscriber authorizes one input/resize operation: the
// terminal and live run must exist, the run id must match, and the sender must
// have attached to the terminal on this connection.
func (s *Server) terminalSessionForSubscriber(client *rpcClient, terminalID, runID string) (*terminal.Session, *terminalEntry, bool) {
	rt := s.terminals
	if rt == nil {
		return nil, nil, false
	}
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
	summary := s.terminalListSummary(terminalID, entry)
	// Enqueue the run's final list state before releasing the terminal fence,
	// so a later relaunch/delete update cannot be overtaken by this exit.
	s.publishTerminalListUpsert(summary)
	entry.operations.Unlock()

	s.publishTerminalStreamItem(terminalID, wire.TerminalStreamItem{
		Kind:       terminal.StreamItemStatus,
		TerminalID: terminalID,
		RunID:      runID,
		Sequence:   seq,
		Status:     status,
		ExitCode:   exitCode,
	})
}
