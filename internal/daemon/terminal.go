package daemon

import (
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/Aqothy/jsonrpc2"
	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/terminal"
)

// terminalRuntime composes the PTY service with RPC concerns: terminal
// identity, the controlling client, and notification fanout. Identity lives in
// memory for now; SQLite persistence arrives with the terminal-threads product
// increment.
type terminalRuntime struct {
	service *terminal.Service

	mu      sync.Mutex
	entries map[string]*terminalEntry
}

type terminalEntry struct {
	terminalID string
	title      string
	cwd        string
	createdAt  time.Time
	updatedAt  time.Time

	// controller is the one client whose input, resize, and output stream are
	// honored. nil after that client disconnects; the shell keeps running.
	controller *rpcClient
}

func newTerminalRuntime() *terminalRuntime {
	return &terminalRuntime{
		service: terminal.NewService(),
		entries: make(map[string]*terminalEntry),
	}
}

// close terminates every live shell and waits for process-group cleanup.
func (rt *terminalRuntime) close() {
	rt.service.Close()
}

// clearControllerFor detaches every terminal controlled by a disconnected
// client without terminating the shells.
func (rt *terminalRuntime) clearControllerFor(client *rpcClient) {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	for _, entry := range rt.entries {
		if entry.controller == client {
			entry.controller = nil
		}
	}
}

func (rt *terminalRuntime) controllerOf(terminalID string) *rpcClient {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	entry, ok := rt.entries[terminalID]
	if !ok {
		return nil
	}
	return entry.controller
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
		controller: client,
	}
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
	})
	if err != nil {
		rt.mu.Lock()
		delete(rt.entries, terminalID)
		rt.mu.Unlock()
		if errors.Is(err, terminal.ErrInvalidDimensions) {
			return wire.TerminalAttachSnapshot{}, fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, err)
		}
		return wire.TerminalAttachSnapshot{}, fmt.Errorf("terminal spawn failed: %w", err)
	}

	columns, rows := session.Size()
	s.logger.Info("terminal created", "terminal", terminalID, "run", session.RunID, "client", client.id)
	return wire.TerminalAttachSnapshot{
		Terminal: wire.TerminalSummary{
			TerminalID: terminalID,
			Title:      entry.title,
			Cwd:        entry.cwd,
			Status:     session.Status(),
			Columns:    columns,
			Rows:       rows,
			CreatedAt:  entry.createdAt,
			UpdatedAt:  entry.updatedAt,
		},
		RunID:    session.RunID,
		Sequence: 0,
	}, nil
}

func (s *Server) terminateTerminal(terminalID string) error {
	if s.terminals == nil {
		return fmt.Errorf("terminal service is unavailable")
	}
	if err := s.terminals.service.Terminate(terminalID); err != nil {
		if errors.Is(err, terminal.ErrNotFound) {
			return fmt.Errorf("%w: %v", jsonrpc2.ErrInvalidParams, err)
		}
		return err
	}
	s.logger.Info("terminal terminated", "terminal", terminalID)
	return nil
}

// writeTerminal applies client input. Stale-run and non-controller input is
// dropped silently: these are routine races around relaunch and takeover, not
// client errors worth a repeating alert.
func (s *Server) writeTerminal(client *rpcClient, params wire.TerminalWriteParams) error {
	session, ok := s.terminalSessionForController(client, params.TerminalID, params.RunID)
	if !ok {
		return nil
	}
	if err := session.Write(params.Data); err != nil && !errors.Is(err, terminal.ErrNotRunning) {
		s.logger.Warn("terminal write failed", "terminal", params.TerminalID, "error", err)
	}
	return nil
}

func (s *Server) resizeTerminal(client *rpcClient, params wire.TerminalResizeParams) error {
	session, ok := s.terminalSessionForController(client, params.TerminalID, params.RunID)
	if !ok {
		return nil
	}
	err := session.Resize(params.Columns, params.Rows)
	if err != nil && !errors.Is(err, terminal.ErrNotRunning) {
		s.logger.Warn("terminal resize failed", "terminal", params.TerminalID, "error", err)
	}
	return nil
}

// terminalSessionForController authorizes one input/resize operation: the
// terminal and live run must exist, the run id must match, and the sender must
// be the current controller.
func (s *Server) terminalSessionForController(client *rpcClient, terminalID, runID string) (*terminal.Session, bool) {
	rt := s.terminals
	if rt == nil {
		return nil, false
	}
	if rt.controllerOf(terminalID) != client {
		return nil, false
	}
	session, err := rt.service.Get(terminalID)
	if err != nil || session.RunID != runID {
		return nil, false
	}
	return session, true
}

// publishTerminalOutput runs on the session's read goroutine. A temporarily
// full client queue blocks this goroutine, allowing the PTY and child process
// to apply normal bounded backpressure without dropping terminal bytes.
func (s *Server) publishTerminalOutput(terminalID, runID string, seq uint64, data []byte) {
	controller := s.terminals.controllerOf(terminalID)
	if controller == nil {
		return
	}
	controller.notifyTerminal(RPCMethodTerminalSubscribe, wire.TerminalStreamItem{
		Kind:       terminal.StreamItemOutput,
		TerminalID: terminalID,
		RunID:      runID,
		Sequence:   seq,
		Data:       data,
	})
}

func (s *Server) publishTerminalExit(terminalID, runID string, seq uint64, status terminal.Status, exitCode *int) {
	s.logger.Info("terminal run ended", "terminal", terminalID, "run", runID, "status", status)
	controller := s.terminals.controllerOf(terminalID)
	if controller == nil {
		return
	}
	controller.notifyTerminal(RPCMethodTerminalSubscribe, wire.TerminalStreamItem{
		Kind:       terminal.StreamItemStatus,
		TerminalID: terminalID,
		RunID:      runID,
		Sequence:   seq,
		Status:     status,
		ExitCode:   exitCode,
	})
}
