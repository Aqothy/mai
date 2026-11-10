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
	"github.com/coder/websocket"

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
// identity, views and their streams, and SQLite metadata.
// A terminal's shell starts when a view first attaches, so an unused terminal
// costs nothing. Only identity metadata is durable: after a daemon restart a
// saved terminal has no shell until someone opens it.
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
	// command marks a terminal running a one-off program instead of a shell.
	// It is never saved: a restart couldn't run that program again.
	command bool
	// onExit runs once, off the event path, when the program ends by itself.
	// Only command terminals set it.
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
	if rt.meta == nil || entry.command {
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

// entry returns the current entry for terminalID, or nil.
func (rt *terminalRuntime) entry(terminalID string) *terminalEntry {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	return rt.entries[terminalID]
}

// closeStreams ends every view's stream, when the daemon shuts down.
func (rt *terminalRuntime) closeStreams() []*terminalStream {
	rt.mu.Lock()
	entries := slices.Collect(maps.Values(rt.entries))
	rt.mu.Unlock()
	var streams []*terminalStream
	for _, entry := range entries {
		streams = append(streams, entry.views.closeStreams(websocket.StatusGoingAway, "daemon shutting down")...)
	}
	return streams
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

func (s *Server) createTerminal(client *rpcClient, params wire.TerminalCreateParams) (wire.TerminalAttachResult, error) {
	rt := s.terminals
	cwd, err := terminal.ResolveCwd(params.Cwd)
	if err != nil {
		return wire.TerminalAttachResult{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, err)
	}
	if err := terminal.ValidateSize(params.Columns, params.Rows); err != nil {
		return wire.TerminalAttachResult{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, err)
	}
	appearance, err := parseTerminalAppearance(params.Appearance)
	if err != nil {
		return wire.TerminalAttachResult{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, err)
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
	// The view is attached once the entry is registered, where a closing
	// connection finds it.
	rt.mu.Lock()
	rt.entries[terminalID] = entry
	rt.mu.Unlock()
	view := terminalView{
		client: client, attachmentID: params.AttachmentID,
		columns: params.Columns, rows: params.Rows, appearance: appearance,
		ticket: newStreamTicket(),
	}
	if !entry.views.attach(view, true) {
		rt.mu.Lock()
		delete(rt.entries, terminalID)
		rt.mu.Unlock()
		entry.operations.Unlock()
		return wire.TerminalAttachResult{}, errTerminalClientClosed
	}

	if _, err := rt.service.Start(terminalID, terminal.SpawnSpec{
		Cwd:     cwd,
		Columns: params.Columns,
		Rows:    params.Rows,
	}, s.terminalEvents()); err != nil {
		rt.mu.Lock()
		delete(rt.entries, terminalID)
		rt.mu.Unlock()
		entry.operations.Unlock()
		// A subscribe that ran meanwhile may have listed it.
		s.publishTerminalList(terminalID)
		return wire.TerminalAttachResult{}, fmt.Errorf("terminal spawn failed: %w", err)
	}

	rt.persist(entry, s.logger)
	s.sizeToActiveView(entry)
	result := s.terminalAttachResult(entry, view.ticket)
	entry.operations.Unlock()
	s.publishTerminalList(terminalID)
	s.logger.Info("terminal created", "terminal", terminalID, "client", client.id,
		"columns", params.Columns, "rows", params.Rows)
	return result, nil
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
	entry := &terminalEntry{terminalID: terminalID, title: title, cwd: cwd, createdAt: now, updatedAt: now, command: true, onExit: onExit}
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
	entry.operations.Unlock()
	s.publishTerminalList(terminalID)
	return terminalID, nil
}

// attachTerminal adds the calling client's view and returns the ticket for
// its stream, which starts from a snapshot. A view the user opens takes the
// size; one reattaching keeps its place, so it never takes the size from the
// device in use.
func (s *Server) attachTerminal(client *rpcClient, params wire.TerminalAttachParams) (wire.TerminalAttachResult, error) {
	rt := s.terminals
	if err := terminal.ValidateSize(params.Columns, params.Rows); err != nil {
		return wire.TerminalAttachResult{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, err)
	}
	appearance, err := parseTerminalAppearance(params.Appearance)
	if err != nil {
		return wire.TerminalAttachResult{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, err)
	}
	entry, ok := rt.lockEntry(params.TerminalID)
	if !ok {
		return wire.TerminalAttachResult{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, terminal.ErrNotFound)
	}
	defer entry.operations.Unlock()
	session, err := s.terminalShell(entry, params.Columns, params.Rows)
	if err != nil {
		return wire.TerminalAttachResult{}, fmt.Errorf("terminal spawn failed: %w", err)
	}
	view := terminalView{
		client: client, attachmentID: params.AttachmentID,
		columns: params.Columns, rows: params.Rows, appearance: appearance,
		ticket: newStreamTicket(),
	}
	if !entry.views.attach(view, params.Focus) {
		return wire.TerminalAttachResult{}, errTerminalClientClosed
	}
	s.sizeToActiveView(entry)
	// Attaching is seeing: finished and failed statuses go away.
	seen := session.Seen()
	result := s.terminalAttachResult(entry, view.ticket)
	if seen {
		s.publishTerminalList(entry.terminalID)
	}
	s.logger.Info("terminal attached", "terminal", entry.terminalID, "client", view.client.id,
		"columns", view.columns, "rows", view.rows, "focus", params.Focus)
	return result, nil
}

// terminalShell returns the terminal's shell, starting it at the given grid if
// it has none. Callers hold entry.operations, so views attaching together share
// one shell.
func (s *Server) terminalShell(entry *terminalEntry, columns, rows uint16) (*terminal.Session, error) {
	rt := s.terminals
	if session, err := rt.service.Get(entry.terminalID); err == nil {
		return session, nil
	}
	// A terminal whose folder is gone still opens, from the home directory.
	cwd, err := terminal.ResolveCwd(entry.cwd)
	if err != nil {
		if cwd, err = terminal.ResolveCwd(""); err != nil {
			return nil, err
		}
	}
	session, err := rt.service.Start(entry.terminalID, terminal.SpawnSpec{Cwd: cwd, Columns: columns, Rows: rows}, s.terminalEvents())
	if err != nil {
		return nil, err
	}
	if cwd != entry.cwd {
		rt.mu.Lock()
		entry.cwd = cwd
		rt.mu.Unlock()
		rt.persist(entry, s.logger)
		s.publishTerminalList(entry.terminalID)
	}
	return session, nil
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

func (s *Server) terminalAttachResult(entry *terminalEntry, ticket streamTicket) wire.TerminalAttachResult {
	return wire.TerminalAttachResult{Terminal: s.terminalListSummary(entry), StreamTicket: ticket.String()}
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
	return s.dropTerminal(entry)
}

// dropTerminal ends any live run and removes the terminal's identity, for
// every client. Callers hold entry.operations.
func (s *Server) dropTerminal(entry *terminalEntry) error {
	rt := s.terminals
	terminalID := entry.terminalID
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
	s.logger.Info("terminal removed", "terminal", terminalID)
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

// terminalListSummary overlays what the program reports on the persisted
// identity for list rows.
func (s *Server) terminalListSummary(entry *terminalEntry) wire.TerminalSummary {
	rt := s.terminals
	rt.mu.Lock()
	summary := wire.TerminalSummary{
		TerminalID: entry.terminalID,
		Title:      entry.title,
		Cwd:        entry.cwd,
		CreatedAt:  entry.createdAt,
		UpdatedAt:  entry.updatedAt,
	}
	rt.mu.Unlock()
	if session, err := rt.service.Get(entry.terminalID); err == nil {
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

// writeTerminal accepts input from any view attached to the terminal. Clients
// never answer the program (the daemon's terminal does), so everything they
// send is the user's: keys, pastes, and the mouse and focus reports the
// program asked for. Input doesn't take the size, since reports arrive
// without the user using the view (a Mac locking reports focus out); a view
// sends terminal.focus before what the user types. Unattached input is dropped
// silently as a routine lifecycle race rather than surfaced as a repeating
// alert.
func (s *Server) writeTerminal(client *rpcClient, params wire.TerminalWriteParams) error {
	entry, ok := s.terminals.lockEntry(params.TerminalID)
	if !ok {
		return nil
	}
	defer entry.operations.Unlock()
	session, err := s.terminals.service.Get(params.TerminalID)
	if err != nil || !entry.views.attached(client) {
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
		Output:  s.publishTerminalOutput,
		Resized: s.publishTerminalResized,
		Exit: func(session *terminal.Session, exitCode *int) {
			go s.finishTerminal(session.TerminalID, exitCode)
		},
		ProgramChanged: s.publishTerminalProgram,
	}
}

// finishTerminal removes a terminal whose program ended by itself, for every
// client. It runs off the event path: it takes the terminal's operations, whose
// holders resize through emit.
func (s *Server) finishTerminal(terminalID string, exitCode *int) {
	s.logger.Info("terminal program exited", "terminal", terminalID)
	entry, ok := s.terminals.lockEntry(terminalID)
	if !ok {
		return
	}
	onExit := entry.onExit
	if err := s.dropTerminal(entry); err != nil {
		s.logger.Warn("remove exited terminal", "terminal", terminalID, "error", err)
	}
	entry.operations.Unlock()
	if onExit != nil {
		onExit(exitCode)
	}
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
