package daemon

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"maps"
	"net/http"
	"slices"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/terminal"
)

const (
	streamHelloTimeout = 5 * time.Second
	// streamMessageBytes caps a record's payload, so one message never holds
	// the writer long and a client never buffers much to parse a record.
	streamMessageBytes = 64 * 1024
	// streamResyncBytes is how much output a stream may have queued before
	// it is replaced by a snapshot. It is about twice the largest snapshot
	// (about 2.3 MB at the scrollback budget), so a snapshot and the output
	// after it fit.
	streamResyncBytes = 4 * 1024 * 1024
)

// Reasons a stream's handshake is refused. They are close reasons on the
// wire, so they stay short and never name another client's terminal.
var (
	errStreamTicketUnknown = errors.New("unknown or used ticket")
	errStreamTicketExpired = errors.New("expired ticket")
	errStreamNotRunning    = errors.New("terminal is not running")
)

// streamTicket lets one view open its stream once, soon after attaching.
type streamTicket struct {
	value   [16]byte
	expires time.Time
}

func newStreamTicket() streamTicket {
	ticket := streamTicket{expires: time.Now().Add(wire.TerminalStreamTicketLifetime)}
	_, _ = rand.Read(ticket.value[:])
	return ticket
}

func (t streamTicket) String() string {
	return base64.RawURLEncoding.EncodeToString(t.value[:])
}

// serveTerminalStream opens one view's terminal stream: the subprotocol, a
// ticket within streamHelloTimeout, then records from the daemon until the
// view ends or the client goes away.
func (s *Server) serveTerminalStream(w http.ResponseWriter, r *http.Request) {
	ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		Subprotocols:    []string{wire.TerminalStreamSubprotocol},
		CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		s.logger.Warn("terminal stream accept failed", "error", err)
		return
	}
	if ws.Subprotocol() != wire.TerminalStreamSubprotocol {
		_ = ws.Close(websocket.StatusProtocolError, "subprotocol "+wire.TerminalStreamSubprotocol+" required")
		return
	}
	ws.SetReadLimit(int64(len(streamTicket{}.value)))
	// A context deadline on Read would drop the connection without a close
	// code (coder/websocket closes on an expired read context).
	timeout := time.AfterFunc(streamHelloTimeout, func() {
		_ = ws.Close(websocket.StatusPolicyViolation, "no ticket within 5 seconds")
	})
	kind, hello, err := ws.Read(context.Background())
	if !timeout.Stop() || err != nil {
		_ = ws.CloseNow()
		return
	}
	var ticket [16]byte
	if kind != websocket.MessageBinary || len(hello) != len(ticket) {
		_ = ws.Close(websocket.StatusPolicyViolation, "malformed ticket")
		return
	}
	copy(ticket[:], hello)
	// The client never sends data again; reading on keeps control frames
	// answered and notices the client closing.
	stream := newTerminalStream(ws, ws.CloseRead(context.Background()))
	if err := s.openTerminalStream(ticket, stream); err != nil {
		_ = ws.Close(websocket.StatusPolicyViolation, err.Error())
		return
	}
	stream.run()
}

// openTerminalStream redeems a ticket and makes stream its view's stream,
// starting from a snapshot of the current run. The ticket is used up even
// when the stream can't open. Holding the terminal's operations keeps the
// view and run from changing until the stream follows them.
func (s *Server) openTerminalStream(ticket [16]byte, stream *terminalStream) error {
	rt := s.terminals
	rt.mu.Lock()
	entries := slices.Collect(maps.Values(rt.entries))
	rt.mu.Unlock()
	i := slices.IndexFunc(entries, func(entry *terminalEntry) bool { return entry.views.holdsTicket(ticket) })
	if i < 0 {
		return errStreamTicketUnknown
	}
	entry, ok := rt.lockEntry(entries[i].terminalID)
	if !ok {
		return errStreamTicketUnknown
	}
	defer entry.operations.Unlock()
	client, err := entry.views.redeem(ticket, time.Now())
	if err != nil {
		return err
	}
	session, err := rt.service.Get(entry.terminalID)
	if err != nil {
		return errStreamNotRunning
	}
	err = session.Observe(func(snapshot terminal.Snapshot) {
		entry.views.setStream(client, stream)
		stream.resync(snapshot)
	})
	if err != nil {
		return errStreamNotRunning
	}
	return nil
}

// terminalStream is one view's stream. Publishers queue records under mu
// and never block; the stream's handler goroutine is its only writer, and
// takes the whole queue at once, so an idle stream sends each echo at once
// and a busy one sends large messages.
type terminalStream struct {
	ws *websocket.Conn
	// connected ends when the connection closes, from either side.
	connected context.Context
	wake      chan struct{}
	// finished closes once the connection has closed and the writer is done.
	finished chan struct{}

	mu sync.Mutex
	// runID is the run the stream follows; events of other runs skip it.
	runID string
	queue []streamRecord
	// queuedOutput counts output bytes in queue.
	queuedOutput int
	// closed stops queueing: the stream is closing or its client has gone.
	closed bool
}

// streamRecord is one queued record. A snapshot record's data is sent
// after it as snapshot data records.
type streamRecord struct {
	kind    wire.TerminalStreamRecordKind
	payload []byte
	data    []byte
}

func newTerminalStream(ws *websocket.Conn, connected context.Context) *terminalStream {
	return &terminalStream{ws: ws, connected: connected, wake: make(chan struct{}, 1), finished: make(chan struct{})}
}

// resync replaces whatever the stream had queued with a snapshot of run, and
// follows that run from here on. The snapshot holds everything the queue
// did.
func (s *terminalStream) resync(snapshot terminal.Snapshot) {
	header, err := json.Marshal(wire.TerminalStreamSnapshot{
		RunID:          snapshot.RunID,
		Status:         snapshot.Status,
		ExitCode:       snapshot.ExitCode,
		SnapshotFormat: snapshot.SnapshotFormat,
		Size:           len(snapshot.Data),
	})
	if err != nil {
		s.close(websocket.StatusInternalError, "snapshot encoding failed")
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	s.runID = snapshot.RunID
	clear(s.queue)
	s.queue = append(s.queue[:0], streamRecord{kind: wire.TerminalRecordSnapshot, payload: header, data: snapshot.Data})
	s.queuedOutput = 0
	s.signal()
}

// output queues run's output, shared read-only with other streams. It
// reports false when the stream has fallen too far behind and needs resync
// instead.
func (s *terminalStream) output(runID string, data []byte) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || s.runID != runID {
		return true
	}
	if s.queuedOutput+len(data) > streamResyncBytes {
		return false
	}
	s.queuedOutput += len(data)
	s.queue = append(s.queue, streamRecord{kind: wire.TerminalRecordOutput, payload: data})
	s.signal()
	return true
}

// record queues a lifecycle record of run.
func (s *terminalStream) record(runID string, kind wire.TerminalStreamRecordKind, payload []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || s.runID != runID {
		return
	}
	s.queue = append(s.queue, streamRecord{kind: kind, payload: payload})
	s.signal()
}

func (s *terminalStream) signal() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

// close ends the stream with code; the first close wins. The connection's
// Close lets a write in progress finish, then tells the client why; a client
// that stopped reading is cut off by coder/websocket's close timeouts (5 s to
// send the close, 5 s for the reply). It runs on its own goroutine, since
// callers hold locks on the terminal's event path.
func (s *terminalStream) close(code websocket.StatusCode, reason string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	s.closed = true
	clear(s.queue)
	s.queue = nil
	go func() { _ = s.ws.Close(code, reason) }()
}

// run writes queued records until the connection closes.
func (s *terminalStream) run() {
	defer close(s.finished)
	var batch []streamRecord
	message := make([]byte, 0, 1+streamMessageBytes)
	for {
		select {
		case <-s.connected.Done():
			// Closed by close, or the client went away: nothing more queues.
			s.mu.Lock()
			s.closed = true
			clear(s.queue)
			s.queue = nil
			s.mu.Unlock()
			return
		case <-s.wake:
		}
		s.mu.Lock()
		batch, s.queue = s.queue, batch[:0]
		s.queuedOutput = 0
		s.mu.Unlock()
		if err := s.write(batch, message); err != nil {
			s.close(websocket.StatusInternalError, "write failed")
		}
		clear(batch)
	}
}

// write sends one batch, merging consecutive output into messages of up to
// streamMessageBytes. Each message is a single write from message.
func (s *terminalStream) write(batch []streamRecord, message []byte) error {
	send := func(kind wire.TerminalStreamRecordKind, payload []byte) error {
		return s.ws.Write(s.connected, websocket.MessageBinary, append(append(message[:0], byte(kind)), payload...))
	}
	pending := message[:0]
	flush := func() error {
		if len(pending) == 0 {
			return nil
		}
		err := s.ws.Write(s.connected, websocket.MessageBinary, pending)
		pending = message[:0]
		return err
	}
	for _, record := range batch {
		if record.kind == wire.TerminalRecordOutput {
			for data := record.payload; len(data) > 0; {
				if len(pending) == 0 {
					pending = append(pending, byte(wire.TerminalRecordOutput))
				}
				n := min(len(data), 1+streamMessageBytes-len(pending))
				pending = append(pending, data[:n]...)
				data = data[n:]
				if len(pending) == 1+streamMessageBytes {
					if err := flush(); err != nil {
						return err
					}
				}
			}
			continue
		}
		if err := flush(); err != nil {
			return err
		}
		if err := send(record.kind, record.payload); err != nil {
			return err
		}
		for data := record.data; len(data) > 0; {
			n := min(len(data), streamMessageBytes)
			if err := send(wire.TerminalRecordSnapshotData, data[:n]); err != nil {
				return err
			}
			data = data[n:]
		}
	}
	return flush()
}

// publishTerminalStreams gives every view's stream that follows the
// session's run a record. Runs under the session's emit.
func (s *Server) publishTerminalStreams(session *terminal.Session, kind wire.TerminalStreamRecordKind, payload any) {
	entry := s.terminals.entry(session.TerminalID)
	if entry == nil {
		return
	}
	data, err := json.Marshal(payload)
	if err != nil {
		s.logger.Error("terminal stream record encoding failed", "terminal", session.TerminalID, "error", err)
		return
	}
	entry.views.eachStream(func(stream *terminalStream) {
		stream.record(session.RunID, kind, data)
	})
}

func (s *Server) publishTerminalOutput(session *terminal.Session, data []byte) {
	entry := s.terminals.entry(session.TerminalID)
	if entry == nil {
		return
	}
	var resync *terminal.Snapshot
	entry.views.eachStream(func(stream *terminalStream) {
		if stream.output(session.RunID, data) {
			return
		}
		// Too far behind to be sent what it missed: the client jumps to
		// the current screen instead, without slowing the program or other
		// views. The snapshot already holds data.
		if resync == nil {
			snapshot, err := session.Snapshot()
			if err != nil {
				stream.close(websocket.StatusInternalError, "snapshot failed")
				return
			}
			resync = &snapshot
		}
		stream.resync(*resync)
	})
}

func (s *Server) publishTerminalResized(session *terminal.Session, columns, rows uint16) {
	s.publishTerminalStreams(session, wire.TerminalRecordResized, wire.TerminalStreamResized{Columns: columns, Rows: rows})
}
